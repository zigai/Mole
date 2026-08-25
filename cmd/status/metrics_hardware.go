package main

import (
	"context"
	"fmt"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/host"
)

func collectHardware(totalRAM uint64, disks []DiskStatus) HardwareInfo {
	if runtime.GOOS == "linux" {
		return collectHardwareLinux(totalRAM, disks)
	}
	if runtime.GOOS != "darwin" {
		return HardwareInfo{
			Model:       "Unknown",
			CPUModel:    runtime.GOARCH,
			TotalRAM:    humanBytes(totalRAM),
			DiskSize:    "Unknown",
			OSVersion:   runtime.GOOS,
			RefreshRate: "",
		}
	}

	// Model and CPU from system_profiler.
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	var model, cpuModel, osVersion, refreshRate string

	out, err := runCmd(ctx, "system_profiler", "SPHardwareDataType")
	if err == nil {
		for line := range strings.Lines(out) {
			lower := strings.ToLower(strings.TrimSpace(line))
			// Prefer "Model Name" over "Model Identifier".
			if strings.Contains(lower, "model name:") {
				parts := strings.Split(line, ":")
				if len(parts) == 2 {
					model = strings.TrimSpace(parts[1])
				}
			}
			if strings.Contains(lower, "chip:") {
				parts := strings.Split(line, ":")
				if len(parts) == 2 {
					cpuModel = strings.TrimSpace(parts[1])
				}
			}
			if strings.Contains(lower, "processor name:") && cpuModel == "" {
				parts := strings.Split(line, ":")
				if len(parts) == 2 {
					cpuModel = strings.TrimSpace(parts[1])
				}
			}
		}
	}

	ctx2, cancel2 := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel2()
	out2, err := runCmd(ctx2, "sw_vers", "-productVersion")
	if err == nil {
		osVersion = "macOS " + strings.TrimSpace(out2)
	}

	// Get refresh rate from display info (use mini detail to keep it fast).
	ctx3, cancel3 := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel3()
	out3, err := runCmd(ctx3, "system_profiler", "-detailLevel", "mini", "SPDisplaysDataType")
	if err == nil {
		refreshRate = parseRefreshRate(out3)
	}

	diskSize := "Unknown"
	if len(disks) > 0 {
		diskSize = humanBytes(disks[0].Total)
	}

	return HardwareInfo{
		Model:       model,
		CPUModel:    cpuModel,
		TotalRAM:    humanBytes(totalRAM),
		DiskSize:    diskSize,
		OSVersion:   osVersion,
		RefreshRate: refreshRate,
	}
}

// collectHardwareLinux fills the hardware card from DMI, /proc/cpuinfo and
// os-release. Every field degrades independently when its source is absent.
func collectHardwareLinux(totalRAM uint64, disks []DiskStatus) HardwareInfo {
	info := HardwareInfo{
		Model:       "Unknown",
		CPUModel:    runtime.GOARCH,
		TotalRAM:    humanBytes(totalRAM),
		DiskSize:    "Unknown",
		OSVersion:   "Linux",
		RefreshRate: "",
	}

	productName := strings.TrimSpace(readSysFile("/sys/class/dmi/id/product_name"))
	productVendor := strings.TrimSpace(readSysFile("/sys/class/dmi/id/product_vendor"))
	if isDmiPlaceholder(productName) {
		productName = ""
	}
	if isDmiPlaceholder(productVendor) {
		productVendor = ""
	}
	switch {
	case productName != "" && productVendor != "":
		info.Model = productVendor + " " + productName
	case productName != "":
		info.Model = productName
	}

	if cpuModel := linuxCPUModel(); cpuModel != "" {
		info.CPUModel = cpuModel
	}

	if osVersion := linuxOSVersion(); osVersion != "" {
		info.OSVersion = osVersion
	}

	if len(disks) > 0 {
		info.DiskSize = humanBytes(disks[0].Total)
	}

	return info
}

func readSysFile(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// isDmiPlaceholder reports common board-vendor filler strings so they never
// surface as the machine model.
func isDmiPlaceholder(v string) bool {
	if v == "" {
		return false
	}
	lower := strings.ToLower(v)
	for _, p := range []string{"to be filled", "default string", "system product", "system name", "none"} {
		if strings.Contains(lower, p) {
			return true
		}
	}
	return false
}

// linuxCPUModel prefers the human-readable 'model name' from /proc/cpuinfo
// (x86) and falls back to gopsutil, which also covers ARM model names.
func linuxCPUModel() string {
	for line := range strings.Lines(readSysFile("/proc/cpuinfo")) {
		if key, value, found := strings.Cut(line, ":"); found && strings.TrimSpace(key) == "model name" {
			return strings.TrimSpace(value)
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()
	infos, err := cpu.InfoWithContext(ctx)
	if err != nil || len(infos) == 0 {
		return ""
	}
	return strings.TrimSpace(infos[0].ModelName)
}

// linuxOSVersion returns PRETTY_NAME from os-release (e.g. "Fedora Linux 44"),
// falling back to gopsutil's host info.
func linuxOSVersion() string {
	osRelease := os.Getenv("MOLE_OS_RELEASE_FILE")
	if osRelease == "" {
		osRelease = "/etc/os-release"
		if _, err := os.Stat(osRelease); err != nil {
			// Ephemeral/immutable roots keep os-release under /usr/lib.
			osRelease = "/usr/lib/os-release"
		}
	}
	for line := range strings.Lines(readSysFile(osRelease)) {
		if key, value, found := strings.Cut(strings.TrimSpace(line), "="); found && key == "PRETTY_NAME" {
			return strings.Trim(strings.TrimSpace(value), `"`)
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()
	stat, err := host.InfoWithContext(ctx)
	if err != nil || stat == nil {
		return ""
	}
	version := stat.Platform
	if stat.PlatformVersion != "" {
		version = fmt.Sprintf("%s %s", stat.Platform, stat.PlatformVersion)
	}
	return version
}

// parseRefreshRate extracts the highest refresh rate from system_profiler display output.
func parseRefreshRate(output string) string {
	maxHz := 0

	for line := range strings.Lines(output) {
		lower := strings.ToLower(line)
		// Look for patterns like "@ 60Hz", "@ 60.00Hz", or "Refresh Rate: 120 Hz".
		if strings.Contains(lower, "hz") {
			fields := strings.Fields(lower)
			for i, field := range fields {
				if field == "hz" && i > 0 {
					if hz := parseInt(fields[i-1]); hz > maxHz && hz < 500 {
						maxHz = hz
					}
					continue
				}
				if numStr, ok := strings.CutSuffix(field, "hz"); ok {
					if numStr == "" && i > 0 {
						numStr = fields[i-1]
					}
					if hz := parseInt(numStr); hz > maxHz && hz < 500 {
						maxHz = hz
					}
				}
			}
		}
	}

	if maxHz > 0 {
		return fmt.Sprintf("%dHz", maxHz)
	}
	return ""
}

// parseInt safely parses an integer from a string.
func parseInt(s string) int {
	// Trim away non-numeric padding, keep digits and '.' for decimals.
	cleaned := strings.TrimSpace(s)
	cleaned = strings.TrimLeftFunc(cleaned, func(r rune) bool {
		return (r < '0' || r > '9') && r != '.'
	})
	cleaned = strings.TrimRightFunc(cleaned, func(r rune) bool {
		return (r < '0' || r > '9') && r != '.'
	})
	if cleaned == "" {
		return 0
	}
	var num int
	if _, err := fmt.Sscanf(cleaned, "%d", &num); err != nil {
		return 0
	}
	return num
}
