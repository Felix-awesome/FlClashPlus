//go:build ios

package core

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"github.com/metacubex/mihomo/constant"
)

// bootLog appends one line to the extension's startup log.
//
// The provider writes that file from Swift and the app exports it, because a
// sideloaded build has no console. Core-side facts -- which interface outbound
// sockets bind to, why a probe failed -- were invisible until now, so every
// failure surfaced in the app as the same generic "no network" and this port
// took several rounds to narrow down. Appending here puts them in the log the
// user already knows how to send.
//
// The writes are small and O_APPEND, so a line cannot be torn by a concurrent
// writer; at worst two processes' lines interleave.
func bootLog(format string, args ...any) {
	home := constant.Path.HomeDir()
	if home == "" {
		return
	}
	line := time.Now().Format("15:04:05.000") + " core: " +
		fmt.Sprintf(format, args...) + "\n"
	bootLogMu.Lock()
	defer bootLogMu.Unlock()
	file, err := os.OpenFile(
		filepath.Join(home, "boot.log"),
		os.O_APPEND|os.O_CREATE|os.O_WRONLY,
		0o644,
	)
	if err != nil {
		return
	}
	defer func() { _ = file.Close() }()
	_, _ = file.WriteString(line)
}

var bootLogMu sync.Mutex

// bootLogMemory records the Go side of the process footprint at one named step.
//
// It goes through bootLog rather than the log package on purpose. The mihomo
// log is filtered down to warnings and above on the way into this file
// (forwardCoreLogs), so the first version of this instrument -- a log.Infoln
// from a watchdog -- never reached the log at all, and two rounds of
// investigating "the tunnel just stops" were run with no memory numbers in
// hand. bootLog writes the line itself, so nothing can filter it out.
//
// The numbers are the Go heap only. The kernel's limit counts the whole
// process, which is why the provider logs its own phys_footprint beside these
// lines: a heap that looks fine next to a footprint at the ceiling is a
// non-Go allocation, and the two together say which one is growing.
func bootLogMemory(step string) {
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	const mib = 1 << 20
	bootLog(
		"[mem] %s: heap %.1f MiB, idle %.1f MiB, sys %.1f MiB, goroutines %d",
		step,
		float64(stats.HeapAlloc)/mib,
		float64(stats.HeapIdle-stats.HeapReleased)/mib,
		float64(stats.Sys)/mib,
		runtime.NumGoroutine(),
	)
}
