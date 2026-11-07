//go:build android || ios

package tun

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
)

// The Swift side publishes NWPathMonitor's active physical interface here.
// Hiddify passes the same information to its core through a platform
// interface callback; a file in the shared home dir keeps the gomobile
// boundary untouched and is rewritten on every network change.
const activeInterfaceFile = "default_interface"

const interfacePollInterval = 2 * time.Second

var startInterfaceWatch sync.Once

// watchPhysicalInterface binds the core's outbound sockets to the NIC the
// system is actually using.
//
// Inside a packet tunnel the BSD RIB reports the utun as the default route,
// so mihomo's auto-detect-interface finder can only guess from the interface
// list (and keeps preferring Wi-Fi after the device moved to cellular). An
// unbound outbound socket is swallowed by the tunnel's /1 + default routes:
// connections time out or end in EOF, which from the app looks exactly like
// every proxy being dead.
//
// dialer.DefaultInterface is read *before* that finder on every dial and ends
// up in the same IP_BOUND_IF setsockopt. Setting it avoids claiming the
// finder slot: sing_tun.New registers its finder with
// CompareAndSwap(nil, ...) and aborts TUN startup if the slot is occupied --
// replacing it would make every subsequent StartTun fail.
//
// An empty value deliberately restores mihomo's own heuristic, so a missing
// or stale file degrades instead of disabling the bind.
func watchPhysicalInterface() {
	if runtime.GOOS != "ios" {
		return
	}
	startInterfaceWatch.Do(func() {
		go func() {
			var last string
			for {
				name := readActiveInterface()
				if name != last {
					last = name
					dialer.DefaultInterface.Store(name)
					if name == "" {
						log.Infoln("[TUN] outbound interface: no monitor answer, using mihomo's finder")
					} else {
						log.Infoln("[TUN] outbound interface from NWPathMonitor: %s", name)
					}
				}
				time.Sleep(interfacePollInterval)
			}
		}()
	})
}

func readActiveInterface() string {
	path := filepath.Join(constant.Path.HomeDir(), activeInterfaceFile)
	content, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	name := strings.TrimSpace(string(content))
	// A stale utun value would bind outbound sockets back into this tunnel.
	if name == "" || strings.HasPrefix(name, "utun") || name == "lo0" {
		return ""
	}
	return name
}
