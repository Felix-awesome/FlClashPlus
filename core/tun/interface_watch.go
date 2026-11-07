//go:build android || ios

package tun

import (
	"net"
	"net/netip"
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

// How long the last published name is kept after the file goes empty.
//
// A network switch empties the file for a poll or two: the monitor reports
// "no path" before it reports the new one. Releasing the bind in that window
// hands the outbound sockets back to the default route -- which, inside the
// tunnel, is the tunnel itself -- so a two-second gap turns into connections
// that time out for no visible reason.
const interfaceHoldGrace = 10 * time.Second

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
func watchPhysicalInterface() {
	if runtime.GOOS != "ios" {
		return
	}
	startInterfaceWatch.Do(func() {
		go func() {
			var (
				bound    string
				lastName string
				lastSeen time.Time
			)
			for {
				name, source := outboundInterface(lastName, lastSeen)
				if name != "" && source == interfaceSourceFile {
					lastName, lastSeen = name, time.Now()
				}
				if name != bound {
					bound = name
					dialer.DefaultInterface.Store(name)
					if name == "" {
						log.Infoln("[TUN] outbound interface: no usable NIC found; " +
							"leaving the choice to mihomo's finder")
					} else {
						log.Infoln("[TUN] outbound interface=%s (source: %s)", name, source)
					}
				}
				time.Sleep(interfacePollInterval)
			}
		}()
	})
}

const (
	interfaceSourceFile = "NWPathMonitor"
	interfaceSourceHeld = "held"
	interfaceSourceScan = "interface scan"
)

// outboundInterface names the interface outbound sockets should bind to,
// together with where that answer came from -- the source is what makes a
// "no traffic" report readable.
//
// Three sources, ordered by how much they can be trusted:
//
//  1. the file NWPathMonitor keeps current. It is the same information the
//     system routes with, so nothing beats it.
//  2. the name it published last, held for a short grace period. See
//     interfaceHoldGrace.
//  3. a scan of our own. mihomo's finder answers "<invalid>" when its
//     heuristic finds nothing (listener/sing_tun/server.go:658), and binding
//     to that name fails *every* dial -- one wrong guess then looks like every
//     node being down. A name the kernel actually knows is always better, even
//     when it has to be guessed here.
func outboundInterface(previous string, previousAt time.Time) (string, string) {
	if name := readActiveInterface(); name != "" {
		return name, interfaceSourceFile
	}
	if previous != "" && time.Since(previousAt) < interfaceHoldGrace {
		return previous, interfaceSourceHeld
	}
	if name := discoverPhysicalInterface(); name != "" {
		return name, interfaceSourceScan
	}
	return "", "none"
}

// readActiveInterface returns the published name when it still names an
// interface this kernel has.
//
// The file outlives a restart, so it can point at an interface that is gone
// (Wi-Fi switched off, cellular down, a pdp_ip index that changed). Binding to
// a name the kernel does not know fails with EADDRNOTAVAIL on every dial,
// which is worse than falling through to the next source.
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
	if _, err := net.InterfaceByName(name); err != nil {
		return ""
	}
	return name
}

// discoverPhysicalInterface picks a carrier the same way mihomo's iOS helper
// does -- Wi-Fi first, then any other en*, then cellular -- and only from
// interfaces that are up and own a unicast IPv4 address.
func discoverPhysicalInterface() string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	best, bestScore := "", 0
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		score := interfaceScore(iface.Name)
		if score <= bestScore || !hasUnicastIPv4(iface) {
			continue
		}
		best, bestScore = iface.Name, score
	}
	return best
}

func interfaceScore(name string) int {
	switch {
	case name == "en0":
		return 100
	case strings.HasPrefix(name, "en"):
		return 90
	case strings.HasPrefix(name, "pdp_ip"):
		return 60
	default:
		// utun*, lo0, awdl*, llw*, anpi*, bridge* and ipsec* carry no
		// outbound traffic of their own.
		return 0
	}
}

func hasUnicastIPv4(iface net.Interface) bool {
	addrs, err := iface.Addrs()
	if err != nil {
		return false
	}
	for _, addr := range addrs {
		prefix, err := netip.ParsePrefix(addr.String())
		if err != nil || !prefix.Addr().Is4() {
			continue
		}
		if prefix.Addr().IsLoopback() || prefix.Addr().IsLinkLocalUnicast() {
			continue
		}
		return true
	}
	return false
}
