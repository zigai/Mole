package main

import (
	"fmt"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v4/net"
)

var ioCountersFunc = net.IOCounters

const (
	minNetworkSampleInterval = 100 * time.Millisecond
	networkIPCacheTTL        = 10 * time.Second
)

var noiseInterfacePrefixes = [...]string{"lo", "awdl", "utun", "llw", "bridge", "gif", "stf", "xhc", "anpi", "ap"}

func collectIOCountersSafely() (stats []net.IOCountersStat, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("panic collecting network counters: %v", r)
		}
	}()
	return ioCountersFunc(true)
}

func (c *Collector) primeNetworkCounters(now time.Time) {
	stats, err := collectIOCountersSafely()
	if err != nil {
		return
	}
	c.lastNetAt = now
	for _, s := range stats {
		c.prevNet[s.Name] = s
	}
}

func (c *Collector) collectNetwork(now time.Time) []NetworkStatus {
	if c.prevNet == nil {
		c.prevNet = make(map[string]net.IOCountersStat)
	}
	if c.rxHistoryBuf == nil {
		c.rxHistoryBuf = NewRingBuffer(NetworkHistorySize)
	}
	if c.txHistoryBuf == nil {
		c.txHistoryBuf = NewRingBuffer(NetworkHistorySize)
	}

	stats, err := collectIOCountersSafely()
	if err != nil {
		// Some restricted environments can break netstat-backed collectors.
		// Degrade gracefully to keep status output available.
		c.rxHistoryBuf.Add(0)
		c.txHistoryBuf.Add(0)
		return nil
	}

	// Map interface IPs.
	ifAddrs := c.getInterfaceIPsCached(now)

	if c.lastNetAt.IsZero() {
		c.lastNetAt = now
		for _, s := range stats {
			c.prevNet[s.Name] = s
		}
	}

	elapsed := now.Sub(c.lastNetAt).Seconds()
	if elapsed < minNetworkSampleInterval.Seconds() {
		elapsed = minNetworkSampleInterval.Seconds()
	}

	var result []NetworkStatus
	for _, cur := range stats {
		if isNoiseInterface(cur.Name) {
			continue
		}
		prev, ok := c.prevNet[cur.Name]
		if !ok {
			continue
		}
		rx := float64(counterDelta(cur.BytesRecv, prev.BytesRecv)) / 1024.0 / 1024.0 / elapsed
		tx := float64(counterDelta(cur.BytesSent, prev.BytesSent)) / 1024.0 / 1024.0 / elapsed
		result = append(result, NetworkStatus{
			Name:      cur.Name,
			RxRateMBs: rx,
			TxRateMBs: tx,
			IP:        ifAddrs[cur.Name],
		})
	}

	c.lastNetAt = now
	for _, s := range stats {
		c.prevNet[s.Name] = s
	}

	sort.Slice(result, func(i, j int) bool {
		return result[i].RxRateMBs+result[i].TxRateMBs > result[j].RxRateMBs+result[j].TxRateMBs
	})
	if len(result) > 3 {
		result = result[:3]
	}

	var totalRx, totalTx float64
	for _, r := range result {
		totalRx += r.RxRateMBs
		totalTx += r.TxRateMBs
	}

	// Update history using the global/aggregated stats
	c.rxHistoryBuf.Add(totalRx)
	c.txHistoryBuf.Add(totalTx)

	return result
}

func (c *Collector) getInterfaceIPsCached(now time.Time) map[string]string {
	if c.cachedNetIPs != nil && now.Sub(c.lastNetIPAt) < networkIPCacheTTL {
		return c.cachedNetIPs
	}
	c.cachedNetIPs = getInterfaceIPs()
	c.lastNetIPAt = now
	return c.cachedNetIPs
}

func getInterfaceIPs() map[string]string {
	result := make(map[string]string)
	ifaces, err := net.Interfaces()
	if err != nil {
		return result
	}
	for _, iface := range ifaces {
		for _, addr := range iface.Addrs {
			// IPv4 only.
			if strings.Contains(addr.Addr, ".") && !strings.HasPrefix(addr.Addr, "127.") {
				ip, _, _ := strings.Cut(addr.Addr, "/")
				result[iface.Name] = ip
				break
			}
		}
	}
	return result
}

func isNoiseInterface(name string) bool {
	lower := strings.ToLower(name)
	for _, prefix := range noiseInterfacePrefixes {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	return false
}

func collectProxy() ProxyStatus {
	if proxy := collectProxyFromEnv(os.Getenv); proxy.Enabled {
		return proxy
	}

	return ProxyStatus{Enabled: false}
}

func collectProxyFromEnv(getenv func(string) string) ProxyStatus {
	// Include ALL_PROXY for users running proxy tools that only export a single variable.
	envKeys := []string{
		"https_proxy", "HTTPS_PROXY",
		"http_proxy", "HTTP_PROXY",
		"all_proxy", "ALL_PROXY",
	}
	for _, key := range envKeys {
		val := strings.TrimSpace(getenv(key))
		if val == "" {
			continue
		}

		proxyType := "HTTP"
		lower := strings.ToLower(val)
		if strings.HasPrefix(lower, "socks") {
			proxyType = "SOCKS"
		}

		host := parseProxyHost(val)
		if host == "" {
			host = val
		}
		return ProxyStatus{Enabled: true, Type: proxyType, Host: host}
	}

	return ProxyStatus{Enabled: false}
}

func parseProxyHost(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}

	target := raw
	if !strings.Contains(target, "://") {
		target = "http://" + target
	}
	parsed, err := url.Parse(target)
	if err != nil {
		return ""
	}
	host := parsed.Host
	if host == "" {
		return ""
	}
	return strings.TrimPrefix(host, "@")
}
