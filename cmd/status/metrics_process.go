package main

import (
	"container/heap"
	"context"
	"fmt"
	"slices"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/mem"
	"github.com/shirou/gopsutil/v4/process"
)

var collectProcessesFunc = collectProcesses

func collectProcesses() ([]ProcessInfo, error) {
	return collectProcessesLinux()
}

// collectProcessesLinux gathers per-process CPU/memory via gopsutil and keeps
// the same ProcessInfo shape as the legacy ps output so top-N ranking is shared.
// CPU percent mirrors ps: cputime relative to process lifetime on first sample.
func collectProcessesLinux() ([]ProcessInfo, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	pids, err := process.ProcessesWithContext(ctx)
	if err != nil {
		return nil, err
	}

	var totalMem uint64
	if vmStats, err := mem.VirtualMemory(); err == nil {
		totalMem = vmStats.Total
	}

	now := time.Now()
	procs := make([]ProcessInfo, 0, len(pids))
	for _, p := range pids {
		if ctx.Err() != nil {
			break
		}
		name, err := p.NameWithContext(ctx)
		if err != nil || name == "" {
			continue
		}
		memInfo, err := p.MemoryInfoWithContext(ctx)
		if err != nil || memInfo == nil {
			continue
		}

		ppid, _ := p.PpidWithContext(ctx)
		command, _ := p.CmdlineWithContext(ctx)
		if command == "" {
			command = name
		}

		cpuPercent := 0.0
		if times, err := p.TimesWithContext(ctx); err == nil && times != nil {
			cpuPercent = linuxProcessCPUPercent(p, *times, now)
		}

		rssBytes := memInfo.RSS
		memPercent := 0.0
		if totalMem > 0 {
			memPercent = float64(rssBytes) / float64(totalMem) * 100
		}

		procs = append(procs, ProcessInfo{
			PID:         int(p.Pid),
			PPID:        int(ppid),
			Name:        name,
			Command:     command,
			CPU:         cpuPercent,
			Memory:      memPercent,
			MemoryBytes: rssBytes,
		})
	}
	return procs, nil
}

// linuxProcessCPUPercent approximates `ps aux` %CPU: total CPU time divided by
// process elapsed time. Falls back to gopsutil's own estimate when the start
// time cannot be read.
func linuxProcessCPUPercent(p *process.Process, times cpu.TimesStat, now time.Time) float64 {
	cpuSeconds := times.User + times.System
	if cpuSeconds <= 0 {
		return 0
	}
	createTimeMs, err := p.CreateTimeWithContext(context.Background())
	if err != nil || createTimeMs <= 0 {
		if est, estErr := p.CPUPercent(); estErr == nil {
			return est
		}
		return 0
	}
	elapsed := now.Sub(time.UnixMilli(createTimeMs)).Seconds()
	if elapsed <= 0 {
		if est, estErr := p.CPUPercent(); estErr == nil {
			return est
		}
		return 0
	}
	return cpuSeconds / elapsed * 100
}

func topProcesses(processes []ProcessInfo, limit int) []ProcessInfo {
	if limit <= 0 || len(processes) == 0 {
		return nil
	}

	h := &processHeap{}
	heap.Init(h)
	for _, proc := range processes {
		if h.Len() < limit {
			heap.Push(h, proc)
			continue
		}
		if processRanksBefore(proc, (*h)[0]) {
			heap.Pop(h)
			heap.Push(h, proc)
		}
	}

	top := make([]ProcessInfo, h.Len())
	for i := range slices.Backward(top) {
		top[i] = heap.Pop(h).(ProcessInfo)
	}
	return top
}

func formatProcessLabel(proc ProcessInfo) string {
	if proc.Name != "" {
		return fmt.Sprintf("%s (%d)", proc.Name, proc.PID)
	}
	return fmt.Sprintf("pid %d", proc.PID)
}

func processRanksBefore(a, b ProcessInfo) bool {
	if a.CPU != b.CPU {
		return a.CPU > b.CPU
	}
	if a.Memory != b.Memory {
		return a.Memory > b.Memory
	}
	return a.PID < b.PID
}

type processHeap []ProcessInfo

func (h processHeap) Len() int { return len(h) }

func (h processHeap) Less(i, j int) bool {
	return processRanksBefore(h[j], h[i])
}

func (h processHeap) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
}

func (h *processHeap) Push(x any) {
	*h = append(*h, x.(ProcessInfo))
}

func (h *processHeap) Pop() any {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[:n-1]
	return x
}
