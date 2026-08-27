package main

import (
	"bytes"
	"container/heap"
	"context"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// scanPublication gives cancellation a linearizable boundary with externally
// visible scan side effects. A publication either completes before cancel
// returns, or observes the canceled scan and is rejected.
type scanPublication struct {
	ctx           context.Context
	cancelContext context.CancelFunc

	mu        sync.Mutex
	canceling atomic.Bool
	canceled  bool
}

func newScanPublication(ctx context.Context, cancel context.CancelFunc) *scanPublication {
	return &scanPublication{ctx: ctx, cancelContext: cancel}
}

func (p *scanPublication) cancel() {
	p.canceling.Store(true)
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.canceled {
		return
	}
	p.canceled = true
	if p.cancelContext != nil {
		p.cancelContext()
	}
}

func (p *scanPublication) commit(action func() error) error {
	if p.canceling.Load() {
		return context.Canceled
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.canceling.Load() || p.canceled {
		return context.Canceled
	}
	if err := p.ctx.Err(); err != nil {
		return err
	}
	return action()
}

func (p *scanPublication) finish(action func()) {
	p.canceling.Store(true)
	p.mu.Lock()
	defer p.mu.Unlock()
	p.canceled = true
	if p.cancelContext != nil {
		p.cancelContext()
	}
	action()
}

// scanLimiter bundles the concurrency budgets used by a single scan pass.
//
// There are five separate semaphores on purpose: each protects a different
// scarce resource. Collapsing two of them changes scaling behavior in ways
// that are easy to get wrong; see the per-field notes before adjusting.
type scanLimiter struct {
	// entrySem caps the number of in-flight top-level entry workers (one per
	// child of the root being scanned). Acquired with tryAcquireEntry so the
	// caller can fall back to inline scanning when the budget is saturated.
	entrySem chan struct{}

	// dirSem caps the number of concurrent recursive directory walkers
	// inside calculateDirSizeConcurrent. Independent of entrySem because a
	// single entry can fan out into many directory walkers.
	dirSem chan struct{}

	// duSem caps how many `du` subprocesses execute concurrently. Tuned
	// low (NumCPU capped at 4) because each du process is itself heavily
	// I/O parallel and saturating the disk hurts wall-clock latency.
	duSem chan struct{}

	// duQueueSem caps how many goroutines are *queued* to run du.
	// Distinct from duSem so we don't spawn one goroutine per pending
	// directory and grow memory linearly with the input set; without
	// this bound, large home dirs allocate thousands of stacks waiting
	// on duSem. Sized at 2x duSem to keep the worker side warm without
	// unbounded queueing.
	duQueueSem chan struct{}

	// fastSem caps the workers used by the fallback fast-sizing path
	// when du is unavailable or rejected. Same scale as entrySem because
	// the fast path replaces a single du subprocess with one walker.
	fastSem chan struct{}

	// seen tracks (dev, ino) of hardlinked files counted so far in this
	// scan so a file with multiple links is counted once, matching `du`.
	seen sync.Map
}

func newScanLimiter(childCount int) *scanLimiter {
	if childCount <= 0 {
		childCount = maxWorkers
	}
	numWorkers := max(min(max(runtime.NumCPU()*cpuMultiplier, minWorkers), maxWorkers, childCount), 1)
	return &scanLimiter{
		entrySem:   make(chan struct{}, numWorkers),
		dirSem:     make(chan struct{}, min(runtime.NumCPU()*2, maxDirWorkers)),
		duSem:      make(chan struct{}, min(4, runtime.NumCPU())),
		duQueueSem: make(chan struct{}, min(4, runtime.NumCPU())*2),
		fastSem:    make(chan struct{}, min(runtime.NumCPU()*cpuMultiplier, maxWorkers)),
	}
}

func (l *scanLimiter) tryAcquireEntry() bool {
	if l == nil || l.entrySem == nil {
		return false
	}
	select {
	case l.entrySem <- struct{}{}:
		return true
	default:
		return false
	}
}

func (l *scanLimiter) releaseEntry() {
	if l != nil && l.entrySem != nil {
		<-l.entrySem
	}
}

// trySend attempts to send an item to a channel with a timeout.
// Returns true if the item was sent, false if the timeout was reached.
func trySend[T any](ctx context.Context, ch chan<- T, item T, timeout time.Duration) bool {
	if ctx.Err() != nil {
		return false
	}
	if timeout <= 0 {
		select {
		case <-ctx.Done():
			return false
		case ch <- item:
			return true
		default:
			return false
		}
	}

	select {
	case <-ctx.Done():
		return false
	case ch <- item:
		return true
	default:
	}

	timer := time.NewTimer(timeout)
	defer func() {
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
	}()

	select {
	case <-ctx.Done():
		return false
	case ch <- item:
		return true
	case <-timer.C:
		return false
	}
}

func acquireScanPermit(ctx context.Context, sem chan struct{}) error {
	select {
	case sem <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func scanPathConcurrent(ctx context.Context, root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) (scanResult, error) {
	return scanPathConcurrentWithOptions(ctx, root, filesScanned, dirsScanned, bytesScanned, currentPath, maxEntries)
}

func scanPathConcurrentAllEntries(ctx context.Context, root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) (scanResult, error) {
	return scanPathConcurrentWithOptions(ctx, root, filesScanned, dirsScanned, bytesScanned, currentPath, 0)
}

func scanPathConcurrentWithOptions(ctx context.Context, root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value, entryLimit int) (scanResult, error) {
	return scanPathConcurrentWithLimiter(ctx, root, filesScanned, dirsScanned, bytesScanned, currentPath, entryLimit, nil, scanCacheReuse, newScanPublication(ctx, nil))
}

type scanCachePolicy uint8

const (
	scanCacheReuse scanCachePolicy = iota
	scanCacheBypass
)

func scanPathConcurrentWithLimiter(ctx context.Context, root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value, entryLimit int, limiter *scanLimiter, cachePolicy scanCachePolicy, publication *scanPublication) (scanResult, error) {
	if err := ctx.Err(); err != nil {
		return scanResult{}, err
	}
	children, err := os.ReadDir(root)
	if err != nil {
		return scanResult{}, err
	}
	if err := ctx.Err(); err != nil {
		return scanResult{}, err
	}
	if limiter == nil {
		limiter = newScanLimiter(len(children))
	}

	var total int64
	var localFilesScanned int64
	var localBytesScanned int64
	var subtreeFilesScanned atomic.Int64
	var dedupedHardlink atomic.Bool

	collectAllEntries := entryLimit <= 0
	var collectedEntries []dirEntry

	// Keep Top N heaps when a limit is requested.
	entriesHeap := &entryHeap{}
	if !collectAllEntries {
		heap.Init(entriesHeap)
	}

	largeFilesHeap := &largeFileHeap{}
	heap.Init(largeFilesHeap)
	largeFileMinSize := int64(largeFileWarmupMinSize)

	dirSem := limiter.dirSem
	duSem := limiter.duSem
	duQueueSem := limiter.duQueueSem
	var wg sync.WaitGroup

	// Collect results via channels.
	// Cap buffer size to prevent memory spikes with huge directories.
	entryBufSize := max(min(len(children), 4096), 1)
	entryChan := make(chan dirEntry, entryBufSize)
	largeFileChan := make(chan fileEntry, maxLargeFiles*2)

	var collectorWg sync.WaitGroup
	collectorWg.Go(func() {
		for entry := range entryChan {
			if collectAllEntries {
				collectedEntries = append(collectedEntries, entry)
				continue
			}

			if entriesHeap.Len() < entryLimit {
				heap.Push(entriesHeap, entry)
			} else if entry.Size > (*entriesHeap)[0].Size {
				heap.Pop(entriesHeap)
				heap.Push(entriesHeap, entry)
			}
		}
	})
	collectorWg.Go(func() {
		for file := range largeFileChan {
			if largeFilesHeap.Len() < maxLargeFiles {
				heap.Push(largeFilesHeap, file)
				if largeFilesHeap.Len() == maxLargeFiles {
					atomic.StoreInt64(&largeFileMinSize, (*largeFilesHeap)[0].Size)
				}
			} else if file.Size > (*largeFilesHeap)[0].Size {
				heap.Pop(largeFilesHeap)
				heap.Push(largeFilesHeap, file)
				atomic.StoreInt64(&largeFileMinSize, (*largeFilesHeap)[0].Size)
			}
		}
	})

	isRootDir := root == "/"
scanChildren:
	for _, child := range children {
		if ctx.Err() != nil {
			break
		}
		fullPath := filepath.Join(root, child.Name())

		// Skip symlinks to avoid following unexpected targets.
		if child.Type()&fs.ModeSymlink != 0 {
			targetInfo, err := os.Stat(fullPath)
			isDir := false
			if err == nil && targetInfo.IsDir() {
				isDir = true
			}

			// Count link size only to avoid double-counting targets.
			info, err := child.Info()
			if err != nil {
				continue
			}
			size := getActualFileSize(fullPath, info)
			atomic.AddInt64(&total, size)

			trySend(ctx, entryChan, dirEntry{
				Name:       child.Name() + " →",
				Path:       fullPath,
				Size:       size,
				IsDir:      isDir,
				LastAccess: getLastAccessTimeFromInfo(info),
			}, scanSendTimeout)
			continue

		}

		if child.IsDir() {
			if defaultSkipDirs[child.Name()] {
				continue
			}

			// Skip system dirs at root.
			if isRootDir && skipSystemDirs[child.Name()] {
				continue
			}

			// Folded dirs: fast size without expanding.
			if shouldFoldDirWithPath(child.Name(), fullPath) {
				if acquireScanPermit(ctx, duQueueSem) != nil {
					break scanChildren
				}
				wg.Go(func() {
					defer func() { <-duQueueSem }()
					if ctx.Err() != nil {
						return
					}

					size, err := func() (int64, error) {
						if err := acquireScanPermit(ctx, duSem); err != nil {
							return 0, err
						}
						defer func() { <-duSem }()
						return getDirectorySizeFromDu(ctx, fullPath)
					}()
					if ctx.Err() != nil {
						return
					}
					if err != nil || size <= 0 {
						size = calculateDirSizeFastWithLimiter(ctx, fullPath, limiter, filesScanned, dirsScanned, bytesScanned, currentPath)
					}
					if ctx.Err() != nil {
						return
					}
					atomic.AddInt64(&total, size)
					atomic.AddInt64(dirsScanned, 1)

					trySend(ctx, entryChan, dirEntry{
						Name:       child.Name(),
						Path:       fullPath,
						Size:       size,
						IsDir:      true,
						LastAccess: time.Time{},
					}, scanSendTimeout)
				})
				continue
			}

			processDir := func(name, path string) {
				if ctx.Err() != nil {
					return
				}
				result := scanSubdirWithCache(ctx, path, largeFileChan, &largeFileMinSize, limiter, dirSem, duSem, duQueueSem, filesScanned, dirsScanned, bytesScanned, currentPath, cachePolicy, publication)
				if ctx.Err() != nil {
					return
				}
				atomic.AddInt64(&total, result.TotalSize)
				if result.TotalFiles > 0 {
					subtreeFilesScanned.Add(result.TotalFiles)
				}
				if result.dedupedHardlink {
					dedupedHardlink.Store(true)
				}
				atomic.AddInt64(dirsScanned, 1)

				trySend(ctx, entryChan, dirEntry{
					Name:       name,
					Path:       path,
					Size:       result.TotalSize,
					IsDir:      true,
					LastAccess: time.Time{},
				}, scanSendTimeout)
			}
			if limiter.tryAcquireEntry() {
				wg.Go(func() {
					defer limiter.releaseEntry()
					processDir(child.Name(), fullPath)
				})
			} else {
				processDir(child.Name(), fullPath)
			}
			continue
		}

		info, err := child.Info()
		if err != nil {
			continue
		}
		// Actual disk usage for sparse/cloud files, deduping hardlinks.
		size, deduped := countableFileSize(info, &limiter.seen)
		if deduped {
			dedupedHardlink.Store(true)
		}
		atomic.AddInt64(&total, size)
		localFilesScanned++
		localBytesScanned += size

		trySend(ctx, entryChan, dirEntry{
			Name:       child.Name(),
			Path:       fullPath,
			Size:       size,
			IsDir:      false,
			LastAccess: getLastAccessTimeFromInfo(info),
		}, scanSendTimeout)

		// Track large files only.
		if !shouldSkipFileForLargeTracking(fullPath) {
			minSize := atomic.LoadInt64(&largeFileMinSize)
			if size >= minSize {
				trySend(ctx, largeFileChan, fileEntry{Name: child.Name(), Path: fullPath, Size: size}, scanSendTimeout)
			}
		}
	}

	if localFilesScanned > 0 {
		atomic.AddInt64(filesScanned, localFilesScanned)
	}
	if localBytesScanned > 0 {
		atomic.AddInt64(bytesScanned, localBytesScanned)
	}

	wg.Wait()

	// Close channels and wait for collectors.
	close(entryChan)
	close(largeFileChan)
	collectorWg.Wait()
	if err := ctx.Err(); err != nil {
		return scanResult{}, err
	}

	// Convert heaps to sorted slices (descending).
	var entries []dirEntry
	if collectAllEntries {
		entries = append(entries, collectedEntries...)
		sort.SliceStable(entries, func(i, j int) bool {
			return entries[i].Size > entries[j].Size
		})
	} else {
		entries = make([]dirEntry, entriesHeap.Len())
		for i := range slices.Backward(entries) {
			entries[i] = heap.Pop(entriesHeap).(dirEntry)
		}
	}

	largeFiles := make([]fileEntry, largeFilesHeap.Len())
	for i := range slices.Backward(largeFiles) {
		largeFiles[i] = heap.Pop(largeFilesHeap).(fileEntry)
	}

	return scanResult{
		Entries:         entries,
		LargeFiles:      largeFiles,
		TotalSize:       total,
		TotalFiles:      localFilesScanned + subtreeFilesScanned.Load(),
		dedupedHardlink: dedupedHardlink.Load(),
	}, nil
}

func publishLargeFiles(ctx context.Context, files []fileEntry, largeFileChan chan<- fileEntry) {
	for _, file := range files {
		if !trySend(ctx, largeFileChan, file, scanSendTimeout) && ctx.Err() != nil {
			return
		}
	}
}

func loadCachedSubdirResult(ctx context.Context, path string, largeFileChan chan<- fileEntry) (scanResult, bool) {
	if ctx.Err() != nil {
		return scanResult{}, false
	}
	cached, err := loadCacheFromDisk(path)
	if err != nil {
		return scanResult{}, false
	}

	result := scanResult{
		Entries:    cached.Entries,
		LargeFiles: cached.LargeFiles,
		TotalSize:  cached.TotalSize,
		TotalFiles: cached.TotalFiles,
	}
	publishLargeFiles(ctx, result.LargeFiles, largeFileChan)
	return result, true
}

func scanSubdirWithCache(ctx context.Context, root string, largeFileChan chan<- fileEntry, largeFileMinSize *int64, limiter *scanLimiter, dirSem, duSem, duQueueSem chan struct{}, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value, cachePolicy scanCachePolicy, publication *scanPublication) scanResult {
	if ctx.Err() != nil {
		return scanResult{}
	}
	if cachePolicy == scanCacheReuse {
		if cached, ok := loadCachedSubdirResult(ctx, root, largeFileChan); ok {
			if ctx.Err() != nil {
				return scanResult{}
			}
			if cached.TotalFiles > 0 {
				atomic.AddInt64(filesScanned, cached.TotalFiles)
			}
			if cached.TotalSize > 0 {
				atomic.AddInt64(bytesScanned, cached.TotalSize)
			}
			return cached
		}
	}

	result, err := scanPathConcurrentWithLimiter(ctx, root, filesScanned, dirsScanned, bytesScanned, currentPath, maxEntries, limiter, cachePolicy, publication)
	if err == nil {
		if ctx.Err() != nil {
			return scanResult{}
		}
		publishLargeFiles(ctx, result.LargeFiles, largeFileChan)
		if ctx.Err() != nil {
			return scanResult{}
		}
		// A subtree whose size depended on hardlink dedup is scan-order
		// dependent; caching it would poison standalone re-scans. Cheap
		// subtrees are not persisted at all: see shouldPersistSubdirCache.
		if !result.dedupedHardlink && shouldPersistSubdirCache(result) {
			_ = saveCacheToDiskWithOptions(publication, root, result, true)
		} else if cachePolicy == scanCacheBypass {
			_ = removeCacheEntryForScan(publication, root)
		}
		return result
	}
	if ctx.Err() != nil {
		return scanResult{}
	}

	return scanResult{TotalSize: calculateDirSizeConcurrent(ctx, root, largeFileChan, largeFileMinSize, limiter, dirSem, duSem, duQueueSem, filesScanned, dirsScanned, bytesScanned, currentPath)}
}

func shouldFoldDirWithPath(name, path string) bool {
	if foldDirs[name] {
		return true
	}

	// Handle npm cache structure.
	if strings.Contains(path, "/.npm/") || strings.Contains(path, "/.tnpm/") {
		parent := filepath.Base(filepath.Dir(path))
		if parent == ".npm" || parent == ".tnpm" || strings.HasPrefix(parent, "_") {
			return true
		}
		if len(name) == 1 {
			return true
		}
	}

	return false
}

func shouldSkipFileForLargeTracking(path string) bool {
	ext := strings.ToLower(filepath.Ext(path))
	return skipExtensions[ext]
}

// calculateDirSizeFast performs concurrent dir sizing using os.ReadDir.
func calculateDirSizeFast(ctx context.Context, root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) int64 {
	return calculateDirSizeFastWithLimiter(ctx, root, newScanLimiter(0), filesScanned, dirsScanned, bytesScanned, currentPath)
}

func calculateDirSizeFastWithLimiter(ctx context.Context, root string, limiter *scanLimiter, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) int64 {
	var total atomic.Int64
	var wg sync.WaitGroup

	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()

	concurrency := min(runtime.NumCPU()*cpuMultiplier, maxWorkers)
	sem := make(chan struct{}, concurrency)
	if limiter != nil && limiter.fastSem != nil {
		sem = limiter.fastSem
	}

	var walk func(string)
	walk = func(dirPath string) {
		select {
		case <-ctx.Done():
			return
		default:
		}

		if currentPath != nil && atomic.LoadInt64(filesScanned)%int64(batchUpdateSize) == 0 {
			currentPath.Store(dirPath)
		}

		entries, err := os.ReadDir(dirPath)
		if err != nil {
			return
		}

		var localBytes, localFiles int64

		for _, entry := range entries {
			if ctx.Err() != nil {
				return
			}
			if entry.IsDir() {
				subDir := filepath.Join(dirPath, entry.Name())
				atomic.AddInt64(dirsScanned, 1)

				select {
				case sem <- struct{}{}:
					wg.Go(func() {
						defer func() { <-sem }()
						walk(subDir)
					})
				default:
					// Fallback to synchronous traversal to avoid semaphore deadlock under high fan-out.
					walk(subDir)
				}
			} else {
				info, err := entry.Info()
				if err == nil {
					size := getActualFileSize(filepath.Join(dirPath, entry.Name()), info)
					localBytes += size
					localFiles++
				}
			}
		}

		if localBytes > 0 {
			total.Add(localBytes)
			atomic.AddInt64(bytesScanned, localBytes)
		}
		if localFiles > 0 {
			atomic.AddInt64(filesScanned, localFiles)
		}
	}

	walk(root)
	wg.Wait()

	return total.Load()
}

// isInFoldedDir checks if a path is inside a folded directory.
func isInFoldedDir(path string) bool {
	parts := strings.SplitSeq(path, string(os.PathSeparator))
	for part := range parts {
		if foldDirs[part] {
			return true
		}
	}
	return false
}

func calculateDirSizeConcurrent(ctx context.Context, root string, largeFileChan chan<- fileEntry, largeFileMinSize *int64, limiter *scanLimiter, dirSem, duSem, duQueueSem chan struct{}, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) int64 {
	if ctx.Err() != nil {
		return 0
	}
	children, err := os.ReadDir(root)
	if err != nil {
		return 0
	}

	var total atomic.Int64
	var localTotal int64
	var localFilesScanned int64
	var localDirsScanned int64
	var localBytesScanned int64
	var wg sync.WaitGroup

scanChildren:
	for _, child := range children {
		if ctx.Err() != nil {
			break
		}
		fullPath := filepath.Join(root, child.Name())

		if child.Type()&fs.ModeSymlink != 0 {
			info, err := child.Info()
			if err != nil {
				continue
			}
			size := getActualFileSize(fullPath, info)
			localTotal += size
			localFilesScanned++
			localBytesScanned += size
			continue
		}

		if child.IsDir() {
			localDirsScanned++

			if shouldFoldDirWithPath(child.Name(), fullPath) {
				if acquireScanPermit(ctx, duQueueSem) != nil {
					break scanChildren
				}
				wg.Go(func() {
					defer func() { <-duQueueSem }()
					if ctx.Err() != nil {
						return
					}

					size, err := func() (int64, error) {
						if err := acquireScanPermit(ctx, duSem); err != nil {
							return 0, err
						}
						defer func() { <-duSem }()
						return getDirectorySizeFromDu(ctx, fullPath)
					}()
					if ctx.Err() != nil {
						return
					}
					if err != nil || size <= 0 {
						size = calculateDirSizeFastWithLimiter(ctx, fullPath, limiter, filesScanned, dirsScanned, bytesScanned, currentPath)
					} else {
						atomic.AddInt64(bytesScanned, size)
					}
					if ctx.Err() != nil {
						return
					}
					total.Add(size)
				})
				continue
			}

			select {
			case dirSem <- struct{}{}:
				wg.Go(func() {
					defer func() { <-dirSem }()

					size := calculateDirSizeConcurrent(ctx, fullPath, largeFileChan, largeFileMinSize, limiter, dirSem, duSem, duQueueSem, filesScanned, dirsScanned, bytesScanned, currentPath)
					total.Add(size)
				})
			case <-ctx.Done():
				break scanChildren
			default:
				size := calculateDirSizeConcurrent(ctx, fullPath, largeFileChan, largeFileMinSize, limiter, dirSem, duSem, duQueueSem, filesScanned, dirsScanned, bytesScanned, currentPath)
				localTotal += size
			}
			continue
		}

		info, err := child.Info()
		if err != nil {
			continue
		}

		size := getActualFileSize(fullPath, info)
		localTotal += size
		localFilesScanned++
		localBytesScanned += size

		if !shouldSkipFileForLargeTracking(fullPath) && largeFileMinSize != nil {
			minSize := atomic.LoadInt64(largeFileMinSize)
			if size >= minSize {
				trySend(ctx, largeFileChan, fileEntry{Name: child.Name(), Path: fullPath, Size: size}, scanSendTimeout)
			}
		}

		// Update current path occasionally to prevent UI jitter.
		if currentPath != nil && localFilesScanned%int64(batchUpdateSize) == 0 {
			currentPath.Store(fullPath)
		}
	}

	if localTotal > 0 {
		total.Add(localTotal)
	}

	wg.Wait()

	if localFilesScanned > 0 {
		atomic.AddInt64(filesScanned, localFilesScanned)
	}
	if localBytesScanned > 0 {
		atomic.AddInt64(bytesScanned, localBytesScanned)
	}
	if localDirsScanned > 0 {
		atomic.AddInt64(dirsScanned, localDirsScanned)
	}

	return total.Load()
}

// measureOverviewSize calculates the size of a directory using multiple strategies.
func measureOverviewSize(path string) (int64, error) {
	if path == "" {
		return 0, fmt.Errorf("empty path")
	}

	path = filepath.Clean(path)
	if !filepath.IsAbs(path) {
		return 0, fmt.Errorf("path must be absolute: %s", path)
	}

	if _, err := os.Stat(path); err != nil {
		return 0, fmt.Errorf("cannot access path: %v", err)
	}

	if duSize, err := getDirectorySizeFromDuWithIgnoreNames(context.Background(), path, overviewIgnoreNamesForPath(path)); err == nil {
		_ = storeOverviewSize(path, duSize)
		return duSize, nil
	}

	if logicalSize, err := getDirectoryLogicalSize(path); err == nil {
		_ = storeOverviewSize(path, logicalSize)
		return logicalSize, nil
	}

	if cached, err := loadCacheFromDisk(path); err == nil {
		_ = storeOverviewSize(path, cached.TotalSize)
		return cached.TotalSize, nil
	}

	return 0, fmt.Errorf("unable to measure directory size with fast methods")
}

func getDirectorySizeFromDu(ctx context.Context, path string) (int64, error) {
	return getDirectorySizeFromDuWithIgnoreNames(ctx, path, nil)
}

func getDirectorySizeFromDuWithIgnoreNames(ctx context.Context, path string, ignoreNames []string) (int64, error) {
	// Validate paths.
	if err := validatePath(path); err != nil {
		return 0, err
	}
	for _, ignoreName := range ignoreNames {
		if err := validateDuIgnoreName(ignoreName); err != nil {
			return 0, err
		}
	}

	runDuSize := func(target string) (int64, error) {
		if _, err := os.Stat(target); err != nil {
			return 0, err
		}

		ctx, cancel := context.WithTimeout(ctx, duTimeout)
		defer cancel()

		args := append([]string{"-skPx"}, duIgnoreArgs(ignoreNames)...)
		args = append(args, target)
		cmd := exec.CommandContext(ctx, "du", args...)
		var stdout, stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr

		runErr := cmd.Run()
		fields := strings.Fields(stdout.String())
		if runErr != nil {
			if ctx.Err() == context.DeadlineExceeded {
				return 0, fmt.Errorf("du timeout after %v", duTimeout)
			}
			// BSD du may return non-zero for unreadable descendants while still
			// printing a useful aggregate for the requested root. Use that best
			// effort total instead of falling back to a much slower recursive walk.
			if len(fields) == 0 {
				if stderr.Len() > 0 {
					return 0, fmt.Errorf("du failed: %v, %s", runErr, stderr.String())
				}
				return 0, fmt.Errorf("du failed: %v", runErr)
			}
		}
		if len(fields) == 0 {
			return 0, fmt.Errorf("du output empty")
		}
		kb, parseErr := strconv.ParseInt(fields[0], 10, 64)
		if parseErr != nil {
			return 0, fmt.Errorf("failed to parse du output: %v", parseErr)
		}
		if kb <= 0 {
			if runErr != nil {
				return 0, fmt.Errorf("du failed: %v", runErr)
			}
			return 0, fmt.Errorf("du size invalid: %d", kb)
		}
		return kb * 1024, nil
	}

	return runDuSize(path)
}

func validateDuIgnoreName(name string) error {
	if name == "" {
		return fmt.Errorf("empty du ignore name")
	}
	if strings.Contains(name, "\x00") {
		return fmt.Errorf("du ignore name contains null bytes")
	}
	if strings.ContainsAny(name, `/\`) {
		return fmt.Errorf("du ignore name must be a basename: %s", name)
	}
	return nil
}

func overviewIgnoreNamesForPath(path string) []string {
	entries, err := os.ReadDir(path)
	if err != nil {
		return nil
	}

	ignoreNames := make([]string, 0, len(overviewDuIgnoreNames))
	for _, entry := range entries {
		name := entry.Name()
		if overviewDuIgnoreNames[name] && entry.IsDir() {
			ignoreNames = append(ignoreNames, name)
		}
	}
	return ignoreNames
}

func getDirectoryLogicalSize(path string) (int64, error) {
	var total int64
	err := filepath.WalkDir(path, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if os.IsPermission(err) {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		total += getActualFileSize(p, info)
		return nil
	})
	if err != nil && err != filepath.SkipDir {
		return 0, err
	}
	return total, nil
}

// countableFileSize returns the on-disk size to attribute to a regular file.
// Hardlinked files are deduplicated the way `du` does: the first link counts
// its full size and subsequent links seen in the same scan count zero. The
// bool reports whether this call was a deduplicated (zero-counted) hardlink.
// A nil seen map disables deduplication.
func countableFileSize(info fs.FileInfo, seen *sync.Map) (int64, bool) {
	size := getActualFileSize("", info)
	if seen == nil {
		return size, false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Nlink <= 1 {
		return size, false
	}
	key := [2]uint64{uint64(uint32(stat.Dev)), stat.Ino}
	if _, loaded := seen.LoadOrStore(key, struct{}{}); loaded {
		return 0, true
	}
	return size, false
}

func getActualFileSize(_ string, info fs.FileInfo) int64 {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return info.Size()
	}

	actualSize := stat.Blocks * 512
	if actualSize < info.Size() {
		return actualSize
	}
	return info.Size()
}

func getLastAccessTimeFromInfo(info fs.FileInfo) time.Time {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return time.Time{}
	}
	return lastAccessTimeFromStat(stat)
}
