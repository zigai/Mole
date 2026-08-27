package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTrashPathWithProgress(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", filepath.Join(t.TempDir(), "trash"))

	parent := t.TempDir()
	target := filepath.Join(parent, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	files := []string{
		filepath.Join(target, "one.txt"),
		filepath.Join(target, "two.txt"),
	}
	for _, f := range files {
		if err := os.WriteFile(f, []byte("content"), 0o644); err != nil {
			t.Fatalf("write %s: %v", f, err)
		}
	}

	var counter int64
	count, err := trashPathWithProgress(target, &counter)
	if err != nil {
		t.Fatalf("trashPathWithProgress returned error: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected one path-level Trash operation, got %d", count)
	}
	if counter != 1 {
		t.Fatalf("expected one completed Trash operation, got %d", counter)
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("expected target to be moved to Trash, stat err=%v", err)
	}
}

func TestDeleteMultiplePathsCmdHandlesParentChild(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", filepath.Join(t.TempDir(), "trash"))

	base := t.TempDir()
	parent := filepath.Join(base, "parent")
	child := filepath.Join(parent, "child")

	// Structure: parent/fileA, parent/child/fileC.
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(parent, "fileA"), []byte("a"), 0o644); err != nil {
		t.Fatalf("write fileA: %v", err)
	}
	if err := os.WriteFile(filepath.Join(child, "fileC"), []byte("c"), 0o644); err != nil {
		t.Fatalf("write fileC: %v", err)
	}

	var counter int64
	msg := deleteMultiplePathsCmd([]string{parent, child}, &counter)()
	progress, ok := msg.(deleteProgressMsg)
	if !ok {
		t.Fatalf("expected deleteProgressMsg, got %T", msg)
	}
	if progress.err != nil {
		t.Fatalf("unexpected error: %v", progress.err)
	}
	if progress.count != 2 {
		t.Fatalf("expected 2 paths trashed, got %d", progress.count)
	}
	if counter != 2 {
		t.Fatalf("expected two completed Trash operations, got %d", counter)
	}
	if _, err := os.Stat(parent); !os.IsNotExist(err) {
		t.Fatalf("expected parent to be moved to Trash, err=%v", err)
	}
}

func TestMoveToTrashNonExistent(t *testing.T) {
	err := moveToTrash("/nonexistent/path/that/does/not/exist")
	if err == nil {
		t.Fatal("expected error for non-existent path")
	}
}

func TestMoveToTrashRejectsTraversal(t *testing.T) {
	// Verify the full production path rejects ".." before filepath.Abs resolves it.
	err := moveToTrash("/tmp/fakedir/../../../etc/passwd")
	if err == nil {
		t.Fatal("expected error for path with traversal components")
	}
	if !strings.Contains(err.Error(), "traversal") {
		t.Fatalf("expected traversal error, got: %v", err)
	}
}

func TestValidateTrashTargetRejectsOrbStackLiveData(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	tests := []string{
		filepath.Join(home, ".orbstack"),
		filepath.Join(home, ".orbstack", "state.db"),
	}

	for _, path := range tests {
		t.Run(path, func(t *testing.T) {
			if err := validateTrashTarget(path); err == nil || !strings.Contains(err.Error(), "protected path") {
				t.Fatalf("validateTrashTarget(%q) error = %v, want protected path error", path, err)
			}
		})
	}
}

func TestValidateTrashTargetRejectsCriticalRoots(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	tests := []string{
		"/",
		"/boot",
		"/boot/efi",
		"/efi",
		"/dev",
		"/etc",
		"/proc",
		"/sys",
		"/run",
		"/srv",
		"/tmp",
		"/usr",
		"/bin",
		"/sbin",
		"/lib",
		"/lib64",
		"/var",
		"/root",
		home,
	}

	for _, path := range tests {
		t.Run(path, func(t *testing.T) {
			if err := validateTrashTarget(path); err == nil || !strings.Contains(err.Error(), "protected path") {
				t.Fatalf("validateTrashTarget(%q) error = %v, want protected path error", path, err)
			}
		})
	}
}

func TestValidateTrashTargetAllowsChildrenOfOtherUserHomes(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	path := "/Users/another-account/Library/Caches/old-cache"
	if err := validateTrashTarget(path); err != nil {
		t.Fatalf("validateTrashTarget(%q) error = %v, want nil", path, err)
	}
}

func TestValidateTrashTargetRejectsSymlinkToCriticalRoot(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	parent := t.TempDir()
	alias := filepath.Join(parent, "home-alias")
	if err := os.Symlink(home, alias); err != nil {
		t.Fatalf("create critical-root symlink: %v", err)
	}

	if err := validateTrashTarget(alias); err == nil || !strings.Contains(err.Error(), "protected path") {
		t.Fatalf("validateTrashTarget(%q) error = %v, want protected path error", alias, err)
	}
}

func TestValidateTrashTargetAllowsChildrenOfCriticalRoots(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	tests := []string{
		filepath.Join(home, "Downloads", "old.zip"),
		"/var/cache/example",
		"/var/tmp/mole-user-artifact",
		"/tmp/mole-user-artifact",
	}

	for _, path := range tests {
		t.Run(path, func(t *testing.T) {
			if err := validateTrashTarget(path); err != nil {
				t.Fatalf("validateTrashTarget(%q) error = %v, want nil", path, err)
			}
		})
	}
}

func TestValidateTrashTargetAllowsRegularUserPaths(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	tests := []string{
		filepath.Join(home, "Downloads", "old.zip"),
		filepath.Join(home, "Library", "Caches", "example.cache"),
		filepath.Join(home, "Library", "Containers", "com.docker.docker-helper", "Data"),
		filepath.Join(home, "Library", "Group Containers", "group.com.example.tool", "Library", "Caches", "item"),
	}

	for _, path := range tests {
		t.Run(path, func(t *testing.T) {
			if err := validateTrashTarget(path); err != nil {
				t.Fatalf("validateTrashTarget(%q) error = %v, want nil", path, err)
			}
		})
	}
}

func TestValidatePath(t *testing.T) {
	tests := []struct {
		name    string
		path    string
		wantErr bool
	}{
		// 基本合法路径
		{"absolute path", "/Users/test/file.txt", false},
		{"path with spaces", "/Users/test/My Documents/file.txt", false},
		{"root", "/", false},

		// 中文路径
		{"chinese path", "/Users/test/中文文件夹/文件.txt", false},
		{"chinese mixed", "/Users/test/Downloads/报告2024.pdf", false},

		// Emoji 路径
		{"emoji path", "/Users/test/📁文件夹/📝笔记.txt", false},
		{"emoji only", "/Users/test/🎉/🎊.txt", false},

		// 特殊字符路径 (之前被错误拒绝的)
		{"dollar sign", "/Users/test/$HOME/workspace", false},
		{"semicolon", "/Users/test/project;v2", false},
		{"colon", "/Users/test/project:2024", false},
		{"ampersand", "/Users/test/R&D/project", false},
		{"at sign", "/Users/test/user@domain", false},
		{"hash", "/Users/test/project#123", false},
		{"percent", "/Users/test/100% complete", false},
		{"exclamation", "/Users/test/important!.txt", false},
		{"single quote", "/Users/test/user's files", false},
		{"equals", "/Users/test/key=value", false},
		{"plus", "/Users/test/file+v2", false},
		{"brackets", "/Users/test/[2024] report", false},
		{"parentheses", "/Users/test/project (copy)", false},
		{"comma", "/Users/test/file, backup", false},

		// 非法路径
		{"empty", "", true},
		{"relative", "relative/path", true},
		{"relative dot", "./file.txt", true},
		{"null byte", "/Users/test\x00/file", true},
		{"path traversal", "/Users/test/../../../etc", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validatePath(tt.path)
			if (err != nil) != tt.wantErr {
				t.Errorf("validatePath(%q) error = %v, wantErr %v", tt.path, err, tt.wantErr)
			}
		})
	}
}

func TestValidatePathWithChineseAndSpecialChars(t *testing.T) {
	// 专门测试之前会导致兼容性回退的路径
	parent := t.TempDir()
	testCases := []struct {
		name string
		path string
	}{
		{"chinese", "中文文件夹"},
		{"emoji", "📁 文档"},
		{"mixed", "报告-2024_v2 (终稿) [已审核]"},
		{"special", "Project$2024; Q1: R&D"},
		{"complex", "用户@公司 100% 完成!"},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			fullPath := filepath.Join(parent, tc.path)
			if err := os.MkdirAll(fullPath, 0o755); err != nil {
				t.Fatalf("mkdir %q: %v", tc.path, err)
			}

			if err := validatePath(fullPath); err != nil {
				t.Errorf("validatePath rejected valid path %q: %v", tc.path, err)
			}
		})
	}
}

// Regression for discussion #474: deleting from analyze over SSH appeared to do
// nothing. The only Trash path was Finder AppleScript, which raises a dialog on
// the physical machine that a remote user cannot answer, so every delete sat for
// trashTimeout and then failed. trash(8) needs no Finder, so it must be tried
// first and must actually move the file.
