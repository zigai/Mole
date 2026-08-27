package main

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v4/sensors"
)

func collectBatteries() (batts []BatteryStatus, err error) {
	defer func() {
		if r := recover(); r != nil {
			// Swallow panics to keep UI alive.
			err = fmt.Errorf("battery collection failed: %v", r)
		}
	}()

	// Reads the standard power_supply sysfs interface. Health percentage comes
	// from energy_full/energy_full_design, falling back to the charge_*
	// equivalents; cycle_count degrades silently to zero when the kernel does
	// not expose it.
	var found []BatteryStatus
	dirs, _ := filepath.Glob("/sys/class/power_supply/BAT*")
	for _, dir := range dirs {
		capData, err := os.ReadFile(filepath.Join(dir, "capacity"))
		if err != nil {
			continue
		}
		statusData, _ := os.ReadFile(filepath.Join(dir, "status"))
		percent, _ := strconv.ParseFloat(strings.TrimSpace(string(capData)), 64)
		status := strings.TrimSpace(string(statusData))
		if status == "" {
			status = "Unknown"
		}

		batt := BatteryStatus{
			Percent: percent,
			Status:  status,
		}
		batt.CycleCount = readSysIntFile(filepath.Join(dir, "cycle_count"))
		batt.Capacity = batteryHealthPercent(dir)
		found = append(found, batt)
	}
	if len(found) > 0 {
		return found, nil
	}

	return nil, errors.New("no battery data found")
}

// readSysIntFile reads a single integer from a sysfs file, returning 0 when
// missing or malformed (some drivers report "(not supported)").
func readSysIntFile(path string) int {
	value := strings.TrimSpace(strings.TrimSuffix(readSysFile(path), "\x00"))
	n, err := strconv.Atoi(value)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

// batteryHealthPercent reports full-charge over design capacity as a rounded
// percentage, preferring energy_* and falling back to charge_*.
func batteryHealthPercent(dir string) int {
	full, design := readSysCapacityPair(dir, "energy")
	if full <= 0 || design <= 0 {
		full, design = readSysCapacityPair(dir, "charge")
	}
	if full <= 0 || design <= 0 {
		return 0
	}
	return int(math.Round(float64(full) / float64(design) * 100))
}

// readSysCapacityPair returns (full, design) µWh/µAh values for the given prefix.
func readSysCapacityPair(dir string, prefix string) (int64, int64) {
	full := readSysInt64File(filepath.Join(dir, prefix+"_full"))
	design := readSysInt64File(filepath.Join(dir, prefix+"_full_design"))
	return full, design
}

func readSysInt64File(path string) int64 {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

// collectThermal reads CPU temperature from hwmon via gopsutil, keeping only
// sensor families known to describe CPU package temperatures. Battery
// discharge watts come from the battery's own power/current meters. Missing
// readings leave the struct zeroed rather than synthesized.
func collectThermal() ThermalStatus {
	var thermal ThermalStatus

	thermal.CPUTemp = cpuTemperature()
	thermal.BatteryPower = batteryPowerWatts()

	return thermal
}

// cpuTemperature returns the hottest reading among coretemp (Intel),
// k10temp/zenpower (AMD), cpu_thermal (ARM SoCs) and acpitz entries, preferring
// the dedicated CPU sensors over the generic ACPI thermal zone.
func cpuTemperature() float64 {
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()
	temps, err := sensors.TemperaturesWithContext(ctx)
	if err != nil && len(temps) == 0 {
		return 0
	}

	cpuTemp := 0.0
	acpiTemp := 0.0
	for _, s := range temps {
		key := strings.ToLower(s.SensorKey)
		switch {
		case strings.HasPrefix(key, "coretemp"),
			strings.HasPrefix(key, "k10temp"),
			strings.HasPrefix(key, "zenpower"),
			strings.HasPrefix(key, "cpu_thermal"):
			cpuTemp = math.Max(cpuTemp, s.Temperature)
		case strings.HasPrefix(key, "acpitz"):
			acpiTemp = math.Max(acpiTemp, s.Temperature)
		}
	}
	if cpuTemp > 0 {
		return cpuTemp
	}
	return acpiTemp
}

// batteryPowerWatts converts the battery's power_now reading to watts,
// deriving it from voltage_now * current_now when power_now is absent.
func batteryPowerWatts() float64 {
	matches, _ := filepath.Glob("/sys/class/power_supply/BAT*")
	for _, dir := range matches {
		if watts := readSysMicroWatts(filepath.Join(dir, "power_now")); watts > 0 {
			return watts
		}
		volts := readSysInt64File(filepath.Join(dir, "voltage_now"))
		amps := readSysInt64File(filepath.Join(dir, "current_now"))
		if volts > 0 && amps > 0 {
			watts := float64(volts) * float64(amps) / 1e12 // µV·µA -> W
			if watts < 200 {
				return watts
			}
		}
	}
	return 0
}

// readSysMicroWatts reads a µW figure and converts it to watts.
func readSysMicroWatts(path string) float64 {
	uw := readSysInt64File(path)
	if uw <= 0 {
		return 0
	}
	watts := float64(uw) / 1e6
	if watts >= 200 {
		return 0
	}
	return watts
}
