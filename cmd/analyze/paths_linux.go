//go:build linux

package main

import (
	"container/heap"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Linux counterpart of paths_darwin.go. Every platform-varying analyze hook is
// defined in both files with the same signature; the shared code in this
// package only calls through these symbols.

// lastAccessTimeFromStat reads st_atim (Linux stat layout).
func lastAccessTimeFromStat(stat *syscall.Stat_t) time.Time {
	return time.Unix(stat.Atim.Sec, stat.Atim.Nsec)
}
func systemOverviewRoots() []dirEntry {
	return []dirEntry{
		{Name: "System Data", Path: "/var", IsDir: true, Size: -1},
		{Name: "Optional Software", Path: "/opt", IsDir: true, Size: -1},
	}
}

// homeSplitEntries: Linux homes have no ~/Library-style app data split, so
// Home is scanned as one row.
func homeSplitEntries(home string) []dirEntry { return nil }

func homeLibraryDirName() string { return "" }

func homeLibraryPath(home string) string { return "" }

var moCleanHandledPathFragments = []string{
	"/.cache/",
	"/.local/share/Trash/",
	"/var/log/journal/",
}

// appendInsightEntries lists hidden-space insight candidates for the overview.
// System roots (/var/cache/pacman/pkg, /var/log/journal, docker overlay2) are
// permission-limited: du reports what the invoking user can read and the row
// simply shows a lower bound when running unprivileged.
func appendInsightEntries(entries []dirEntry, home string) []dirEntry {
	dataHome := os.Getenv("XDG_DATA_HOME")
	if dataHome == "" {
		dataHome = filepath.Join(home, ".local", "share")
	}

	cleanablePaths := []struct {
		name string
		path string
	}{
		{"User Cache", filepath.Join(home, ".cache")},
		{"npm Cache", filepath.Join(home, ".npm", "_cacache")},
		{"pip Cache", filepath.Join(home, ".cache", "pip")},
		{"uv Cache", filepath.Join(home, ".cache", "uv")},
		{"pipx Cache", filepath.Join(dataHome, "pipx")},
		{"Go Build Cache", filepath.Join(home, ".cache", "go-build")},
		{"Cargo Registry Cache", filepath.Join(home, ".cargo", "registry", "cache")},
		{"Old Downloads (90d+)", filepath.Join(home, "Downloads")},

		// Permission-limited system stores: sizes are lower bounds when run
		// without root.
		{"Package Cache", "/var/cache/pacman/pkg"},
		{"Systemd Journal", "/var/log/journal"},
		{"Flatpak Runtimes", filepath.Join(dataHome, "flatpak")},
		{"Docker Overlay2", "/var/lib/docker/overlay2"},
	}

	for _, c := range cleanablePaths {
		if info, err := os.Stat(c.path); err == nil && info.IsDir() {
			entries = append(entries, dirEntry{
				Name:  c.name,
				Path:  c.path,
				IsDir: true,
				Size:  -1,
			})
		}
	}

	return entries
}

// findLargeFilesExtra discovers large files by walking the tree directly;
// Linux has no Spotlight equivalent to lean on.
func findLargeFilesExtra(ctx context.Context, root string, minSize int64) ([]fileEntry, error) {
	if err := validatePath(root); err != nil {
		return nil, nil
	}
	if minSize < 0 || minSize > 1<<50 { // 1 PB max
		return nil, nil
	}

	h := &largeFileHeap{}
	walkCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if walkCtx.Err() != nil {
			return fs.SkipAll
		}
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if path != root && isInFoldedDir(path) {
				return fs.SkipDir
			}
			return nil
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		if shouldSkipFileForLargeTracking(path) || isInFoldedDir(path) {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		actualSize := getActualFileSize(path, info)
		if actualSize < minSize {
			return nil
		}
		candidate := fileEntry{
			Name: filepath.Base(path),
			Path: path,
			Size: actualSize,
		}
		if h.Len() < maxLargeFiles {
			heap.Push(h, candidate)
		} else if candidate.Size > (*h)[0].Size {
			heap.Pop(h)
			heap.Push(h, candidate)
		}
		return nil
	})

	files := make([]fileEntry, h.Len())
	for i := range slices.Backward(files) {
		files[i] = heap.Pop(h).(fileEntry)
	}

	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return files, nil
}

// duIgnoreArgs renders ignore names with GNU du's --exclude option, which
// matches basenames anywhere in the walked tree like BSD du's -I mask.
func duIgnoreArgs(ignoreNames []string) []string {
	var args []string
	for _, ignoreName := range ignoreNames {
		args = append(args, "--exclude="+ignoreName)
	}
	return args
}

// openWithDefault opens path with the default application via xdg-open. There
// is no separate reveal-in-manager verb, so reveal opens the containing view.
func openWithDefault(ctx context.Context, path string, reveal bool) error {
	target := path
	if reveal {
		target = filepath.Dir(path)
	}
	return exec.CommandContext(ctx, "xdg-open", target).Run()
}

// moveToTrashPlatform moves absPath into the freedesktop Trash: `gio trash`
// first when available, then an XDG-spec move into ~/.local/share/Trash with a
// .trashinfo sidecar. rename(2) EXDEV failures fall back to copy+delete so
// cross-filesystem targets still land in the home Trash.
func moveToTrashPlatform(absPath string) error {
	if err := moveToTrashViaGio(absPath); err == nil {
		return nil
	}
	return moveToTrashViaXDG(absPath)
}

// moveToTrashViaGio delegates to gio trash, which handles per-mount Trash
// selection and .trashinfo bookkeeping itself. Returns an error when gio is
// missing or refuses the path so callers fall back to the XDG move.
func moveToTrashViaGio(absPath string) error {
	gioPath, err := exec.LookPath("gio")
	if err != nil {
		return fmt.Errorf("gio unavailable")
	}

	ctx, cancel := context.WithTimeout(context.Background(), trashTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, gioPath, "trash", absPath)
	output, err := cmd.CombinedOutput()
	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return fmt.Errorf("timeout moving to Trash")
		}
		return fmt.Errorf("failed to move to Trash: %s", strings.TrimSpace(string(output)))
	}

	return nil
}

// moveToTrashViaXDG implements the freedesktop.org Trash specification by
// hand: an atomic no-overwrite rename into $XDG_DATA_HOME/Trash/files plus a
// .trashinfo entry recording the original path and deletion time.
func moveToTrashViaXDG(absPath string) error {
	trashRoot, err := xdgTrashRoot()
	if err != nil {
		return err
	}
	filesDir := filepath.Join(trashRoot, "files")
	infoDir := filepath.Join(trashRoot, "info")
	for _, dir := range []string{filesDir, infoDir} {
		if err := ensureOwnedTrashDirectory(dir, true); err != nil {
			return err
		}
	}
	base := filepath.Base(absPath)
	if base == "." || base == string(filepath.Separator) || base == "" {
		return fmt.Errorf("invalid Trash item name")
	}

	stamp := time.Now().UnixNano()
	for attempt := range 100 {
		name := base
		if attempt > 0 {
			name = fmt.Sprintf("%s.%d.%d.%d", base, stamp, os.Getpid(), attempt)
		}
		dest := filepath.Join(filesDir, name)
		// RENAME_NOREPLACE keeps the move atomic and collision-safe: a
		// concurrent trashing of the same name can never overwrite an
		// existing Trash item.
		err := unix.Renameat2(unix.AT_FDCWD, absPath, unix.AT_FDCWD, dest, unix.RENAME_NOREPLACE)
		switch {
		case err == nil:
			if infoErr := writeTrashInfo(infoDir, name, absPath, dest); infoErr != nil {
				_ = os.Rename(dest, absPath)
				return infoErr
			}
			return nil
		case errors.Is(err, unix.EEXIST):
			continue
		case errors.Is(err, os.ErrNotExist):
			return err
		case isEXDEV(err):
			return copyDeleteToTrash(absPath, dest)
		default:
			return fmt.Errorf("failed to move to Trash: %w", err)
		}
	}

	return fmt.Errorf("failed to choose unique Trash destination for %s", absPath)
}

func xdgTrashRoot() (string, error) {
	dataHome := os.Getenv("XDG_DATA_HOME")
	if dataHome == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("failed to resolve home directory: %w", err)
		}
		dataHome = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(dataHome, "Trash"), nil
}

// writeTrashInfo records origin and deletion date for a trashed item, as
// required by the XDG spec so restore tools can reconstruct the path.
func writeTrashInfo(infoDir, name, originalPath, dest string) error {
	infoPath := filepath.Join(infoDir, name+".trashinfo")
	content := fmt.Sprintf("[Trash Info]\nPath=%s\nDeletionDate=%s\n",
		uriEscapePath(originalPath), time.Now().Format("2006-01-02T15:04:05"))
	if err := os.WriteFile(infoPath, []byte(content), 0o600); err != nil {
		return fmt.Errorf("failed to write trashinfo: %w", err)
	}
	return nil
}

// uriEscapePath percent-encodes a path per RFC 2396 for use in .trashinfo.
func uriEscapePath(path string) string {
	safe := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_/."
	var b strings.Builder
	for _, r := range []byte(path) {
		if strings.IndexByte(safe, r) >= 0 {
			b.WriteByte(r)
			continue
		}
		fmt.Fprintf(&b, "%%%02X", r)
	}
	return b.String()
}

// isEXDEV reports whether err is the cross-device-link errno from rename.
func isEXDEV(err error) bool {
	var linkErr *os.LinkError
	if errors.As(err, &linkErr) {
		return errors.Is(linkErr.Err, syscall.EXDEV)
	}
	return false
}

func ensureOwnedTrashDirectory(path string, create bool) error {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) && create {
		if err := os.MkdirAll(path, 0o700); err != nil {
			return fmt.Errorf("failed to create Trash directory: %w", err)
		}
		info, err = os.Lstat(path)
	}
	if err != nil {
		return fmt.Errorf("failed to inspect Trash directory: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("trash path is not a normal directory")
	}

	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return fmt.Errorf("trash directory is not owned by the current user")
	}
	if info.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("trash directory is writable by another user")
	}
	return nil
}

// copyDeleteToTrash lands a cross-filesystem item in the home Trash by copying
// content first and removing the source only after the copy fully succeeded.
func copyDeleteToTrash(absPath, dest string) error {
	if err := copyTree(absPath, dest); err != nil {
		_ = os.RemoveAll(dest) // SAFE: removes the partial Trash copy this call created
		return err
	}
	if err := os.RemoveAll(absPath); err != nil { // SAFE: only reached after a verified full copy
		_ = os.RemoveAll(dest)
		return fmt.Errorf("copied to Trash but failed to remove source: %w", err)
	}
	return nil
}

// copyTree recursively copies a file or directory tree, preserving modes.
func copyTree(src, dst string) error {
	info, err := os.Lstat(src)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return copySymlink(src, dst)
	}
	if !info.IsDir() {
		return copyRegularFile(src, dst, info.Mode())
	}
	if err := os.MkdirAll(dst, info.Mode().Perm()); err != nil {
		return err
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if err := copyTree(filepath.Join(src, entry.Name()), filepath.Join(dst, entry.Name())); err != nil {
			return err
		}
	}
	return nil
}

func copySymlink(src, dst string) error {
	target, err := os.Readlink(src)
	if err != nil {
		return err
	}
	_ = os.Remove(dst)
	return os.Symlink(target, dst)
}

func copyRegularFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode.Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		return err
	}
	return out.Close()
}

// criticalAnalyzeDeletePathRoots lists absolute roots analyze must never trash,
// matched exactly or by same-file identity.
func criticalAnalyzeDeletePathRoots() []string {
	return []string{
		"/",
		"/boot",
		"/boot/efi",
		"/efi",
		"/etc",
		"/usr",
		"/bin",
		"/sbin",
		"/lib",
		"/lib64",
		"/proc",
		"/sys",
		"/dev",
		"/run",
		"/srv",
		"/home",
		"/root",
		"/var",
		"/tmp",
	}
}

// protectedAnalyzeDeleteTrees are system-owned trees that stay off-limits even
// when a caller starts inside one instead of selecting its top-level row.
func protectedAnalyzeDeleteTrees() []string {
	return []string{
		"/boot",
		"/etc",
		"/usr",
		"/bin",
		"/sbin",
		"/lib",
		"/lib64",
		"/proc",
		"/sys",
		"/dev",
		"/run",
		"/srv",
	}
}

// accountRootParent is the directory whose direct children are account homes;
// another account's home root must never be trashed by this user.
func accountRootParent() string { return "/home" }
