package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/shirou/gopsutil/v4/sensors"
)

var (
	// Cache for heavy system_profiler output.
	powerCacheMu    sync.Mutex
	lastPowerAt     time.Time
	lastPowerJSONAt time.Time
	cachedPower     string
	cachedPowerJSON string
	powerCacheTTL   = 30 * time.Second
)

func collectBatteries() (batts []BatteryStatus, err error) {
	defer func() {
		if r := recover(); r != nil {
			// Swallow panics to keep UI alive.
			err = fmt.Errorf("battery collection failed: %v", r)
		}
	}()

	// macOS: pmset for real-time percentage/status.
	if runtime.GOOS == "darwin" && commandExists("pmset") {
		if out, err := runCmd(context.Background(), "pmset", "-g", "batt"); err == nil {
			// Health/cycles/capacity from AppleSmartBattery and cached system_profiler.
			health, cycles, capacity := getCachedPowerData()
			if batts := parsePMSet(out, health, cycles, capacity); len(batts) > 0 {
				return batts, nil
			}
		}
	}

	// Linux: /sys/class/power_supply.
	return collectBatteriesLinux()
}

// collectBatteriesLinux reads the standard power_supply sysfs interface.
// Health percentage comes from energy_full/energy_full_design, falling back to
// the charge_* equivalents; cycle_count and watts degrade silently to zero
// when the kernel does not expose them.
func collectBatteriesLinux() ([]BatteryStatus, error) {
	var batts []BatteryStatus
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
		batt.Capacity = linuxBatteryHealthPercent(dir)
		batts = append(batts, batt)
	}
	if len(batts) > 0 {
		return batts, nil
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

// linuxBatteryHealthPercent reports full-charge over design capacity as a
// rounded percentage, preferring energy_* and falling back to charge_*.
func linuxBatteryHealthPercent(dir string) int {
	energyFull, energyDesign := linuxCapacityPair(dir, "energy")
	full, design := energyFull, energyDesign
	if full <= 0 || design <= 0 {
		full, design = linuxCapacityPair(dir, "charge")
	}
	if full <= 0 || design <= 0 {
		return 0
	}
	return int(math.Round(float64(full) / float64(design) * 100))
}

// linuxCapacityPair returns (full, design) µWh/µAh values for the given prefix.
func linuxCapacityPair(dir string, prefix string) (int64, int64) {
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

func parsePMSet(raw string, health string, cycles int, capacity int) []BatteryStatus {
	var out []BatteryStatus
	var timeLeft string

	for line := range strings.Lines(raw) {
		// Time remaining.
		if strings.Contains(line, "remaining") {
			parts := strings.Fields(line)
			for i, p := range parts {
				if p == "remaining" && i > 0 {
					timeLeft = parts[i-1]
				}
			}
		}

		if !strings.Contains(line, "%") {
			continue
		}
		fields := strings.Fields(line)
		var (
			percent float64
			found   bool
			status  = "Unknown"
		)
		for i, f := range fields {
			if strings.Contains(f, "%") {
				value := strings.TrimSuffix(strings.TrimSuffix(f, ";"), "%")
				if p, err := strconv.ParseFloat(value, 64); err == nil {
					percent = p
					found = true
					if i+1 < len(fields) {
						status = strings.TrimSuffix(fields[i+1], ";")
					}
				}
				break
			}
		}
		if !found {
			continue
		}

		out = append(out, BatteryStatus{
			Percent:    percent,
			Status:     status,
			TimeLeft:   timeLeft,
			Health:     health,
			CycleCount: cycles,
			Capacity:   capacity,
		})
	}
	return out
}

// getCachedPowerData returns condition, cycles, and capacity from macOS power sources.
func getCachedPowerData() (health string, cycles int, capacity int) {
	health, cycles, capacity = getCachedSystemPowerData()
	ioregCycles, ioregCapacity := getAppleSmartBatteryHealthData()
	return mergeBatteryHealthData(health, cycles, capacity, ioregCycles, ioregCapacity)
}

func getCachedSystemPowerData() (health string, cycles int, capacity int) {
	if out := getSystemPowerJSONOutput(); out != "" {
		if health, cycles, capacity, ok := parseSystemPowerJSON(out); ok {
			return health, cycles, capacity
		}
	}

	out := getSystemPowerOutput()
	if out == "" {
		return "", 0, 0
	}
	return parseSystemPowerText(out)
}

func mergeBatteryHealthData(health string, cycles int, capacity int, ioregCycles int, ioregCapacity int) (string, int, int) {
	if ioregCycles > 0 {
		cycles = ioregCycles
	}
	// system_profiler publishes the same Maximum Capacity value users see in
	// macOS. IORegistry ratios are estimates and only fill a missing value.
	if capacity <= 0 && ioregCapacity > 0 {
		capacity = ioregCapacity
	}
	return health, cycles, capacity
}

func parseSystemPowerText(out string) (health string, cycles int, capacity int) {
	for line := range strings.Lines(out) {
		lower := strings.ToLower(line)
		if strings.Contains(lower, "cycle count") {
			if _, after, found := strings.Cut(line, ":"); found {
				cycles, _ = strconv.Atoi(strings.TrimSpace(after))
			}
		}
		if strings.Contains(lower, "condition") {
			if _, after, found := strings.Cut(line, ":"); found {
				health = strings.TrimSpace(after)
			}
		}
		if strings.Contains(lower, "maximum capacity") {
			if _, after, found := strings.Cut(line, ":"); found {
				capacity = parsePercentInt(after)
			}
		}
	}
	return health, cycles, capacity
}

type systemPowerJSON struct {
	SPPowerDataType []struct {
		BatteryHealthInfo struct {
			CycleCount      int    `json:"sppower_battery_cycle_count"`
			Health          string `json:"sppower_battery_health"`
			MaximumCapacity string `json:"sppower_battery_health_maximum_capacity"`
		} `json:"sppower_battery_health_info"`
	} `json:"SPPowerDataType"`
}

func parseSystemPowerJSON(raw string) (health string, cycles int, capacity int, ok bool) {
	var payload systemPowerJSON
	if err := json.Unmarshal([]byte(raw), &payload); err != nil {
		return "", 0, 0, false
	}

	for _, item := range payload.SPPowerDataType {
		info := item.BatteryHealthInfo
		parsedCapacity := parsePercentInt(info.MaximumCapacity)
		if info.Health != "" || info.CycleCount > 0 || parsedCapacity > 0 {
			return info.Health, info.CycleCount, parsedCapacity, true
		}
	}
	return "", 0, 0, false
}

func parsePercentInt(raw string) int {
	raw = strings.TrimSpace(raw)
	raw = strings.TrimSuffix(raw, "%")
	raw = strings.TrimSpace(raw)
	value, err := strconv.Atoi(raw)
	if err != nil {
		return 0
	}
	return value
}

func getAppleSmartBatteryHealthData() (cycles int, capacity int) {
	if runtime.GOOS != "darwin" || !commandExists("ioreg") {
		return 0, 0
	}

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	out, err := runCmd(ctx, "ioreg", "-rn", "AppleSmartBattery")
	if err != nil {
		return 0, 0
	}
	return parseAppleSmartBatteryHealth(out)
}

func parseAppleSmartBatteryHealth(out string) (cycles int, capacity int) {
	var design, nominal, rawMax int
	for line := range strings.Lines(out) {
		line = strings.TrimSpace(line)
		if cycles == 0 {
			if raw, found := ioRegValueForKey(line, "CycleCount"); found {
				if value, err := strconv.Atoi(raw); err == nil && value > 0 && value < 100000 {
					cycles = value
				}
			}
		}
		if design == 0 {
			if raw, found := ioRegValueForKey(line, "DesignCapacity"); found {
				if value, err := strconv.Atoi(raw); err == nil && value > 0 {
					design = value
				}
			}
		}
		if nominal == 0 {
			if raw, found := ioRegValueForKey(line, "NominalChargeCapacity"); found {
				if value, err := strconv.Atoi(raw); err == nil && value > 0 {
					nominal = value
				}
			}
		}
		if rawMax == 0 {
			if raw, found := ioRegValueForKey(line, "AppleRawMaxCapacity"); found {
				if value, err := strconv.Atoi(raw); err == nil && value > 0 {
					rawMax = value
				}
			}
		}
	}
	return cycles, batteryHealthPercent(design, nominal, rawMax)
}

// batteryHealthPercent estimates health only when system_profiler does not
// publish Maximum Capacity. AppleRawMaxCapacity is preferred because
// NominalChargeCapacity includes a buffer and can read high. MaxCapacity is
// intentionally ignored: on Apple Silicon it is the denominator of the current
// charge percentage and is normally 100, not a battery-health measurement.
func batteryHealthPercent(design, nominal, rawMax int) int {
	if design <= 0 {
		return 0
	}
	capacity := rawMax
	if capacity == 0 {
		capacity = nominal
	}
	if capacity <= 0 {
		return 0
	}
	pct := math.Round(float64(capacity) * 100.0 / float64(design))
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	return int(pct)
}

func getSystemPowerJSONOutput() string {
	if runtime.GOOS != "darwin" {
		return ""
	}

	powerCacheMu.Lock()
	defer powerCacheMu.Unlock()

	now := time.Now()
	if cachedPowerJSON != "" && now.Sub(lastPowerJSONAt) < powerCacheTTL {
		return cachedPowerJSON
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	out, err := runCmd(ctx, "system_profiler", "SPPowerDataType", "-json")
	if err == nil {
		cachedPowerJSON = out
		lastPowerJSONAt = now
	}
	return cachedPowerJSON
}

func getSystemPowerOutput() string {
	if runtime.GOOS != "darwin" {
		return ""
	}

	powerCacheMu.Lock()
	defer powerCacheMu.Unlock()

	now := time.Now()
	if cachedPower != "" && now.Sub(lastPowerAt) < powerCacheTTL {
		return cachedPower
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	out, err := runCmd(ctx, "system_profiler", "SPPowerDataType")
	if err == nil {
		cachedPower = out
		lastPowerAt = now
	}
	return cachedPower
}

func collectThermal() ThermalStatus {
	if runtime.GOOS == "linux" {
		return collectThermalLinux()
	}
	if runtime.GOOS != "darwin" {
		return ThermalStatus{}
	}

	var thermal ThermalStatus

	// Fan info from cached system_profiler.
	out := getSystemPowerOutput()
	if out != "" {
		for line := range strings.Lines(out) {
			lower := strings.ToLower(line)
			if strings.Contains(lower, "fan") && strings.Contains(lower, "speed") {
				if _, after, found := strings.Cut(line, ":"); found {
					numStr := strings.TrimSpace(after)
					numStr, _, _ = strings.Cut(numStr, " ")
					thermal.FanSpeed, _ = strconv.Atoi(numStr)
				}
			}
		}
	}

	// Power metrics from ioreg (fast, real-time).
	ctxPower, cancelPower := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancelPower()
	if out, err := runCmd(ctxPower, "ioreg", "-rn", "AppleSmartBattery"); err == nil {
		powerThermal := parseAppleSmartBatteryThermal(out)
		thermal.BatteryTemp = powerThermal.BatteryTemp
		thermal.SystemPower = powerThermal.SystemPower
		thermal.AdapterPower = powerThermal.AdapterPower
		thermal.BatteryPower = powerThermal.BatteryPower
	}

	// Do not synthesize CPU temperature from battery sensors or cpu_thermal_level.
	// Those values are not CPU-package temperatures and produce false overheating data.
	return thermal
}

// collectThermalLinux reads CPU temperature from hwmon via gopsutil, keeping
// only sensor families known to describe CPU package temperatures. Battery
// discharge watts come from the battery's own power/current meters. Missing
// readings leave the struct zeroed rather than synthesized.
func collectThermalLinux() ThermalStatus {
	var thermal ThermalStatus

	thermal.CPUTemp = linuxCPUTemperature()
	thermal.BatteryPower = linuxBatteryPowerWatts()

	return thermal
}

// linuxCPUTemperature returns the hottest reading among coretemp (Intel),
// k10temp/zenpower (AMD), cpu_thermal (ARM SoCs) and acpitz entries, preferring the
// dedicated CPU sensors over the generic ACPI thermal zone.
func linuxCPUTemperature() float64 {
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

// linuxBatteryPowerWatts converts the battery's power_now reading to watts,
// deriving it from voltage_now * current_now when power_now is absent.
func linuxBatteryPowerWatts() float64 {
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

func parseAppleSmartBatteryThermal(out string) ThermalStatus {
	var thermal ThermalStatus
	var (
		voltageMV  float64
		amperageMA float64
	)

	for line := range strings.Lines(out) {
		line = strings.TrimSpace(line)

		// AppleSmartBattery reports battery temperature in centi-degrees Celsius.
		if tempRaw, found := parseIORegFloatValue(line, "Temperature"); found && tempRaw > 0 {
			if tempRaw < 1000 {
				// Some fixtures and non-Apple platforms report Celsius directly.
				thermal.BatteryTemp = tempRaw
			} else {
				thermal.BatteryTemp = float64(tempRaw) / 100.0
			}
		}

		// Adapter power (Watts) from current adapter. Ignore AppleRawAdapterDetails:
		// raw entries can appear before the normalized adapter details and should
		// not win the display value.
		if strings.Contains(line, `"AdapterDetails"`) && !strings.Contains(line, "AppleRaw") && thermal.AdapterPower == 0 {
			watts, found := parseIORegFloatValue(line, "Watts")
			if found && watts > 0 {
				thermal.AdapterPower = watts
			}
		}

		// System power consumption (mW -> W).
		if powerMW, found := parseIORegFloatValue(line, "SystemPowerIn"); found {
			setSystemPowerMW(&thermal, powerMW)
		}
		if thermal.SystemPower == 0 {
			if powerMW, found := parseIORegFloatValue(line, "SystemPower"); found {
				setSystemPowerMW(&thermal, powerMW)
			}
		}

		// Battery power (mW -> W, positive = discharging, negative = charging).
		if powerMW, found := parseIORegSignedNumber(line, "BatteryPower"); found {
			setBatteryPowerMW(&thermal, powerMW)
		}

		if voltage, found := parseIORegFloatValue(line, "Voltage"); found && voltage > 0 {
			voltageMV = voltage
		}
		if voltage, found := parseIORegFloatValue(line, "AppleRawBatteryVoltage"); found && voltage > 0 {
			voltageMV = voltage
		}
		if amperage, found := parseIORegSignedNumber(line, "InstantAmperage"); found && amperage != 0 {
			amperageMA = amperage
		}
		if amperage, found := parseIORegSignedNumber(line, "Amperage"); found && amperage != 0 && amperageMA == 0 {
			amperageMA = amperage
		}
	}

	if thermal.BatteryPower == 0 && voltageMV > 0 && amperageMA != 0 {
		// AppleSmartBattery amperage is signed mA. Negative current means the
		// battery is discharging, so keep BatteryPower positive for discharge.
		batteryPowerW := -(voltageMV * amperageMA) / 1000000.0
		if batteryPowerW > -200 && batteryPowerW < 200 {
			thermal.BatteryPower = batteryPowerW
		}
	}
	return thermal
}

func setSystemPowerMW(thermal *ThermalStatus, powerMW float64) {
	// SystemPower should always be positive; reject invalid values.
	if powerMW >= 0 && powerMW < 1000000 { // 0 to 1000W
		thermal.SystemPower = powerMW / 1000.0
	}
}

func setBatteryPowerMW(thermal *ThermalStatus, powerMW float64) {
	// Validate reasonable battery power range: -200W to 200W.
	if powerMW > -200000 && powerMW < 200000 {
		thermal.BatteryPower = powerMW / 1000.0
	}
}

func parseIORegFloatValue(line string, key string) (float64, bool) {
	raw, found := ioRegValueForKey(line, key)
	if !found {
		return 0, false
	}
	val, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return 0, false
	}
	return val, true
}

func parseIORegSignedNumber(line string, key string) (float64, bool) {
	raw, found := ioRegValueForKey(line, key)
	if !found {
		return 0, false
	}
	val, ok := parseIORegSignedInteger(raw)
	if !ok {
		return 0, false
	}
	return float64(val), true
}

func parseIORegSignedInteger(raw string) (int64, bool) {
	if valInt, err := strconv.ParseInt(raw, 10, 64); err == nil {
		return valInt, true
	}
	valUint, err := strconv.ParseUint(raw, 10, 64)
	if err != nil {
		return 0, false
	}
	if valUint <= math.MaxInt64 {
		return int64(valUint), true
	}
	// ioreg sometimes prints negative int64 values as uint64 two's complement.
	negMag := ^valUint + 1
	if negMag > math.MaxInt64 {
		return 0, false
	}
	return -int64(negMag), true
}

func ioRegValueForKey(line string, key string) (string, bool) {
	marker := `"` + key + `"`
	_, rest, found := strings.Cut(line, marker)
	if !found {
		return "", false
	}
	rest = strings.TrimLeft(rest, " \t")
	if !strings.HasPrefix(rest, "=") {
		return "", false
	}
	rest = strings.TrimLeft(rest[1:], " \t")
	if rest == "" || strings.HasPrefix(rest, ",") {
		return "", false
	}
	end := len(rest)
scan:
	for i, r := range rest {
		switch r {
		case ',', '}', ')', ' ', '\t', '\n', '\r':
			end = i
			break scan
		}
	}
	value := strings.Trim(rest[:end], `"`)
	if value == "" {
		return "", false
	}
	return value, true
}
