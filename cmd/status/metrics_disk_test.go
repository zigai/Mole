package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/shirou/gopsutil/v4/disk"
)

func TestShouldSkipDiskPartition(t *testing.T) {
	tests := []struct {
		name string
		part disk.PartitionStat
		want bool
	}{
		{
			name: "keep local apfs root volume",
			part: disk.PartitionStat{
				Device:     "/dev/disk3s1s1",
				Mountpoint: "/",
				Fstype:     "apfs",
			},
			want: false,
		},
		{
			name: "skip macfuse mirror mount",
			part: disk.PartitionStat{
				Device:     "kaku-local:/",
				Mountpoint: "/Users/tw93/Library/Caches/dev.kaku/sshfs/kaku-local",
				Fstype:     "macfuse",
			},
			want: true,
		},
		{
			name: "skip smb share",
			part: disk.PartitionStat{
				Device:     "//server/share",
				Mountpoint: "/Volumes/share",
				Fstype:     "smbfs",
			},
			want: true,
		},
		{
			name: "skip system volume",
			part: disk.PartitionStat{
				Device:     "/dev/disk3s5",
				Mountpoint: "/System/Volumes/Data",
				Fstype:     "apfs",
			},
			want: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := shouldSkipDiskPartition(tt.part); got != tt.want {
				t.Fatalf("shouldSkipDiskPartition(%+v) = %v, want %v", tt.part, got, tt.want)
			}
		})
	}
}

func TestDiskStatusJSONAndNDJSONAlwaysIncludeSMARTStatus(t *testing.T) {
	snapshot := MetricsSnapshot{
		Disks: []DiskStatus{{Mount: "/", SmartStatus: smartStatusUnsupported}},
	}

	oneShot, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}
	if !strings.Contains(string(oneShot), `"smart_status":"unsupported"`) {
		t.Fatalf("JSON missing smart_status: %s", oneShot)
	}

	var stream bytes.Buffer
	encoder := json.NewEncoder(&stream)
	if err := encoder.Encode(snapshot); err != nil {
		t.Fatalf("first NDJSON encode error = %v", err)
	}
	snapshot.Disks[0].SmartStatus = smartStatusUnknown
	if err := encoder.Encode(snapshot); err != nil {
		t.Fatalf("second NDJSON encode error = %v", err)
	}
	lines := strings.Split(strings.TrimSpace(stream.String()), "\n")
	if len(lines) != 2 || !strings.Contains(lines[0], `"smart_status":"unsupported"`) ||
		!strings.Contains(lines[1], `"smart_status":"unknown"`) {
		t.Fatalf("NDJSON smart_status lines = %q", lines)
	}
}

func TestCollectDisksFastSkipsSlowCorrections(t *testing.T) {
	origPartitions := diskPartitionsFunc
	origUsage := diskUsageFunc
	origRunCmd := runCmd
	origCommandExists := commandExists
	t.Cleanup(func() {
		diskPartitionsFunc = origPartitions
		diskUsageFunc = origUsage
		runCmd = origRunCmd
		commandExists = origCommandExists
	})

	const rawTotal = uint64(2 * 1024 * 1024 * 1024)
	const rawUsed = uint64(1024 * 1024 * 1024)
	diskPartitionsFunc = func(all bool) ([]disk.PartitionStat, error) {
		if all {
			t.Fatalf("collectDisks() should request physical partitions only")
		}
		return []disk.PartitionStat{
			{Device: "/dev/disk3s1s1", Mountpoint: "/", Fstype: "apfs"},
		}, nil
	}
	diskUsageFunc = func(path string) (*disk.UsageStat, error) {
		if path != "/" {
			t.Fatalf("unexpected disk usage path %q", path)
		}
		return &disk.UsageStat{
			Path:        path,
			Fstype:      "apfs",
			Total:       rawTotal,
			Used:        rawUsed,
			UsedPercent: 50,
		}, nil
	}
	commandExists = func(name string) bool {
		t.Fatalf("collectDisks() should not check external command %q", name)
		return false
	}
	runCmd = func(ctx context.Context, name string, args ...string) (string, error) {
		t.Fatalf("collectDisks() should not run external command %q", name)
		return "", errors.New("unexpected command")
	}

	got, err := collectDisks()
	if err != nil {
		t.Fatalf("collectDisks() error = %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("collectDisks() returned %d disks, want 1: %#v", len(got), got)
	}
	if got[0].Total != rawTotal || got[0].Used != rawUsed || got[0].UsedPercent != 50 {
		t.Fatalf("collectDisks() should keep raw usage, got %#v", got[0])
	}
	if got[0].SmartStatus != smartStatusUnknown {
		t.Fatalf("collectDisks() smart status = %q, want unknown", got[0].SmartStatus)
	}
}

func TestCounterDeltaClampsCounterReset(t *testing.T) {
	if got := counterDelta(150, 100); got != 50 {
		t.Fatalf("counterDelta increasing = %d, want 50", got)
	}
	if got := counterDelta(10, 100); got != 0 {
		t.Fatalf("counterDelta reset = %d, want 0", got)
	}
}
