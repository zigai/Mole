package main

import (
	"github.com/shirou/gopsutil/v4/mem"
)

func collectMemory() (MemoryStatus, error) {
	vm, err := mem.VirtualMemory()
	if err != nil {
		return MemoryStatus{}, err
	}

	swap, _ := mem.SwapMemory()
	if swap == nil {
		swap = &mem.SwapMemoryStat{}
	}

	return MemoryStatus{
		Used:        vm.Used,
		Total:       vm.Total,
		Available:   vm.Available,
		UsedPercent: vm.UsedPercent,
		SwapUsed:    swap.Used,
		SwapTotal:   swap.Total,
		Cached:      vm.Cached,
	}, nil
}
