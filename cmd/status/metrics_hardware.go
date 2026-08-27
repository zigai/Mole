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
	return collectHardwareLinux(totalRAM, disks)
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
