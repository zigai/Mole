package main

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/shirou/gopsutil/v4/disk"
)

var skipDiskMounts = map[string]bool{
	"/System/Volumes/VM":       true,
	"/System/Volumes/Preboot":  true,
	"/System/Volumes/Update":   true,
	"/System/Volumes/xarts":    true,
	"/System/Volumes/Hardware": true,
	"/System/Volumes/Data":     true,
	"/dev":                     true,
	"/boot/efi":                true,
}

var skipDiskFSTypes = map[string]bool{
	"afpfs":    true,
	"autofs":   true,
	"cifs":     true,
	"devfs":    true,
	"erofs":    true,
	"fuse":     true,
	"fuseblk":  true,
	"fusefs":   true,
	"iso9660":  true,
	"macfuse":  true,
	"nfs":      true,
	"osxfuse":  true,
	"overlay":  true,
	"procfs":   true,
	"smbfs":    true,
	"squashfs": true,
	"tmpfs":    true,
	"webdav":   true,
}

var (
	diskPartitionsFunc = disk.Partitions
	diskUsageFunc      = disk.Usage
)

const (
	smartStatusVerified    = "verified"
	smartStatusFailing     = "failing"
	smartStatusUnsupported = "unsupported"
	smartStatusUnknown     = "unknown"
)

func collectDisks() ([]DiskStatus, error) {
	return collectDisksWithCorrections(true)
}

func collectDisksFast() ([]DiskStatus, error) {
	return collectDisksWithCorrections(false)
}

func collectDisksWithCorrections(useCorrections bool) ([]DiskStatus, error) {
	partitions, err := diskPartitionsFunc(false)
	if err != nil {
		return nil, err
	}

	var (
		disks      []DiskStatus
		seenDevice = make(map[string]bool)
		seenVolume = make(map[string]bool)
	)
	for _, part := range partitions {
		if shouldSkipDiskPartition(part) {
			continue
		}
		baseDevice := baseDeviceName(part.Device)
		if baseDevice == "" {
			baseDevice = part.Device
		}
		if seenDevice[baseDevice] {
			continue
		}
		usage, err := diskUsageFunc(part.Mountpoint)
		if err != nil || usage.Total == 0 {
			continue
		}
		total := usage.Total
		// Skip <1GB volumes.
		if total < 1<<30 {
			continue
		}
		// Use size-based dedupe key for shared pools.
		volKey := fmt.Sprintf("%s:%d", part.Fstype, total)
		if seenVolume[volKey] {
			continue
		}
		used := usage.Used
		usedPercent := usage.UsedPercent
		disks = append(disks, DiskStatus{
			Mount:       part.Mountpoint,
			Device:      part.Device,
			Used:        used,
			Total:       total,
			UsedPercent: usedPercent,
			Fstype:      part.Fstype,
			External:    !useCorrections && strings.HasPrefix(part.Mountpoint, "/Volumes/"),
			SmartStatus: smartStatusUnknown,
		})
		seenDevice[baseDevice] = true
		seenVolume[volKey] = true
	}

	sort.Slice(disks, func(i, j int) bool {
		// First, prefer internal disks over external
		if disks[i].External != disks[j].External {
			return !disks[i].External
		}
		// Then sort by size (largest first)
		return disks[i].Total > disks[j].Total
	})

	if len(disks) > 3 {
		disks = disks[:3]
	}

	return disks, nil
}

func shouldSkipDiskPartition(part disk.PartitionStat) bool {
	if strings.HasPrefix(part.Device, "/dev/loop") {
		return true
	}
	if skipDiskMounts[part.Mountpoint] {
		return true
	}
	if strings.HasPrefix(part.Mountpoint, "/System/Volumes/") {
		return true
	}
	if strings.HasPrefix(part.Mountpoint, "/private/") {
		return true
	}

	fstype := strings.ToLower(part.Fstype)
	if skipDiskFSTypes[fstype] || strings.Contains(fstype, "fuse") {
		return true
	}

	return false
}

// Trash size cache. The trash directory can contain deep trees, and status
// refreshes every second; a short cache prevents repeated WalkDir work without
// hiding changes for long.
var (
	trashSizeCacheMu      sync.Mutex
	trashSizeCachedAt     time.Time
	trashSizeCachedValue  uint64
	trashSizeCachedApprox bool
	trashSizeCacheTTL     = 5 * time.Second
)

func baseDeviceName(device string) string {
	device = strings.TrimPrefix(device, "/dev/")
	if !strings.HasPrefix(device, "disk") {
		return device
	}
	for i := 4; i < len(device); i++ {
		if device[i] == 's' {
			return device[:i]
		}
	}
	return device
}

func (c *Collector) collectDiskIO(now time.Time) DiskIOStatus {
	counters, err := disk.IOCounters()
	if err != nil || len(counters) == 0 {
		return DiskIOStatus{}
	}

	var total disk.IOCountersStat
	for _, v := range counters {
		total.ReadBytes += v.ReadBytes
		total.WriteBytes += v.WriteBytes
	}

	if c.lastDiskAt.IsZero() {
		c.prevDiskIO = total
		c.lastDiskAt = now
		return DiskIOStatus{}
	}

	elapsed := now.Sub(c.lastDiskAt).Seconds()
	if elapsed <= 0 {
		elapsed = 1
	}

	readRate := float64(counterDelta(total.ReadBytes, c.prevDiskIO.ReadBytes)) / 1024 / 1024 / elapsed
	writeRate := float64(counterDelta(total.WriteBytes, c.prevDiskIO.WriteBytes)) / 1024 / 1024 / elapsed

	c.prevDiskIO = total
	c.lastDiskAt = now

	if readRate < 0 {
		readRate = 0
	}
	if writeRate < 0 {
		writeRate = 0
	}

	return DiskIOStatus{ReadRate: readRate, WriteRate: writeRate}
}

func counterDelta(current, previous uint64) uint64 {
	if current < previous {
		return 0
	}
	return current - previous
}

// collectTrashSize returns the total size in bytes of ~/.Trash and whether
// the result is approximate (true when the 2s timeout was reached).
func collectTrashSize() (uint64, bool) {
	trashSizeCacheMu.Lock()
	if !trashSizeCachedAt.IsZero() && time.Since(trashSizeCachedAt) < trashSizeCacheTTL {
		value := trashSizeCachedValue
		approx := trashSizeCachedApprox
		trashSizeCacheMu.Unlock()
		return value, approx
	}
	trashSizeCacheMu.Unlock()

	total, approx := scanTrashSize()

	trashSizeCacheMu.Lock()
	trashSizeCachedValue = total
	trashSizeCachedApprox = approx
	trashSizeCachedAt = time.Now()
	trashSizeCacheMu.Unlock()

	return total, approx
}

func scanTrashSize() (uint64, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var total uint64
	trashPath := userTrashDir()
	_ = filepath.WalkDir(trashPath, func(_ string, d fs.DirEntry, err error) error {
		if ctx.Err() != nil {
			return fs.SkipAll
		}
		if err != nil {
			return nil
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		if !d.IsDir() {
			if info, err := d.Info(); err == nil {
				total += uint64(info.Size())
			}
		}
		return nil
	})
	return total, ctx.Err() != nil
}

// userTrashDir returns the user's trash directory:
// $XDG_DATA_HOME/Trash/files (freedesktop.org Trash spec).
func userTrashDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	dataHome := os.Getenv("XDG_DATA_HOME")
	if dataHome == "" {
		dataHome = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(dataHome, "Trash", "files")
}
