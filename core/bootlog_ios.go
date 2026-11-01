//go:build ios

package core

import (
	"fmt"
	"os"
	"path/filepath"
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
