//go:build darwin

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMoveToTrashViaFilesystemMovesWithoutOverwritingCollision(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home")
	trashDir := filepath.Join(home, ".Trash")
	sourceDir := filepath.Join(root, "source")
	if err := os.MkdirAll(trashDir, 0o700); err != nil {
		t.Fatalf("create fake Trash: %v", err)
	}
	if err := os.MkdirAll(sourceDir, 0o755); err != nil {
		t.Fatalf("create source directory: %v", err)
	}
	t.Setenv("HOME", home)

	target := filepath.Join(sourceDir, "report.txt")
	if err := os.WriteFile(target, []byte("new"), 0o644); err != nil {
		t.Fatalf("write target: %v", err)
	}
	existing := filepath.Join(trashDir, filepath.Base(target))
	if err := os.WriteFile(existing, []byte("keep"), 0o644); err != nil {
		t.Fatalf("write collision: %v", err)
	}

	if err := moveToTrashViaFilesystem(target); err != nil {
		t.Fatalf("filesystem Trash move failed: %v", err)
	}
	if _, err := os.Lstat(target); !os.IsNotExist(err) {
		t.Fatalf("expected source to be gone, Lstat returned %v", err)
	}
	if got, err := os.ReadFile(existing); err != nil || string(got) != "keep" {
		t.Fatalf("existing Trash item was changed: data=%q err=%v", got, err)
	}
	matches, err := filepath.Glob(filepath.Join(trashDir, "report.txt.*"))
	if err != nil || len(matches) != 1 {
		t.Fatalf("expected one collision-safe Trash item, matches=%v err=%v", matches, err)
	}
	if got, err := os.ReadFile(matches[0]); err != nil || string(got) != "new" {
		t.Fatalf("moved Trash item mismatch: data=%q err=%v", got, err)
	}
}

func TestMoveToTrashViaFilesystemRejectsSymlinkedTrash(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home")
	realTrash := filepath.Join(root, "real-trash")
	sourceDir := filepath.Join(root, "source")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatalf("create fake home: %v", err)
	}
	if err := os.MkdirAll(realTrash, 0o700); err != nil {
		t.Fatalf("create real Trash: %v", err)
	}
	if err := os.MkdirAll(sourceDir, 0o755); err != nil {
		t.Fatalf("create source directory: %v", err)
	}
	if err := os.Symlink(realTrash, filepath.Join(home, ".Trash")); err != nil {
		t.Fatalf("create Trash symlink: %v", err)
	}
	t.Setenv("HOME", home)

	target := filepath.Join(sourceDir, "report.txt")
	if err := os.WriteFile(target, []byte("keep"), 0o644); err != nil {
		t.Fatalf("write target: %v", err)
	}

	if err := moveToTrashViaFilesystem(target); err == nil {
		t.Fatal("expected symlinked Trash to be rejected")
	}
	if _, err := os.Lstat(target); err != nil {
		t.Fatalf("target changed after rejected Trash move: %v", err)
	}
}

// trash(8) takes no "--" separator. Passing one makes it report a missing file
// named "--" and exit non-zero while still trashing the real target, which would
// make moveToTrash fall through to Finder and delete a second time. Absolute
// paths cannot be mistaken for options, so no separator is used.
func TestMoveToTrashViaBinaryUsesAbsolutePathWithoutSeparator(t *testing.T) {
	data, err := os.ReadFile("delete.go")
	if err != nil {
		t.Fatalf("failed to read delete.go: %v", err)
	}
	if strings.Contains(string(data), `trashBinary, "--"`) {
		t.Error(`moveToTrashViaBinary must not pass "--" to trash(8); it trashes the target but exits non-zero`)
	}
}
