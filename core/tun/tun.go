//go:build android || ios

package tun

import (
	"encoding/json"
	"net"
	"net/netip"
	"runtime"
	"strings"
	"syscall"

	"github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

type startOptions struct {
	MTU                  uint32 `json:"mtu"`
	CongestionController string `json:"congestion-controller"`
}

// Start takes ownership of fd. dupFd is handed to sing_tun.New, which only
// takes ownership of it once tunNew succeeds inside New; from that point
// Listener.Close (run by New's own deferred cleanup on error) closes dupFd,
// so this must never close dupFd itself. New's error alone can't say
// whether tunNew was reached; the options built below never enable the
// tun features whose validation runs before tunNew, so New cannot fail
// before taking ownership of dupFd.
func Start(fd int, stack, address, dns, rawOptions string) *sing_tun.Listener {
	var settings startOptions
	if err := json.Unmarshal([]byte(rawOptions), &settings); err != nil {
		log.Errorln("TUN: %v", err)
		_ = syscall.Close(fd)
		return nil
	}
	var prefix4 []netip.Prefix
	var prefix6 []netip.Prefix
	tunStack, ok := constant.StackTypeMapping[strings.ToLower(stack)]
	if !ok {
		tunStack = constant.TunMips
	}
	for _, a := range strings.Split(address, ",") {
		a = strings.TrimSpace(a)
		if len(a) == 0 {
			continue
		}
		prefix, err := netip.ParsePrefix(a)
		if err != nil {
			log.Errorln("TUN: %v", err)
			_ = syscall.Close(fd)
			return nil
		}
		if prefix.Addr().Is4() {
			prefix4 = append(prefix4, prefix)
		} else {
			prefix6 = append(prefix6, prefix)
		}
	}

	var dnsHijack []string
	for _, d := range strings.Split(dns, ",") {
		d = strings.TrimSpace(d)
		if len(d) == 0 {
			continue
		}
		hijack := net.JoinHostPort(d, "53")
		if _, err := netip.ParseAddrPort(hijack); err != nil {
			log.Errorln("TUN: %v", err)
			_ = syscall.Close(fd)
			return nil
		}
		dnsHijack = append(dnsHijack, hijack)
	}

	dupFd, err := syscall.Dup(fd)
	if err != nil {
		log.Errorln("TUN: %v", err)
		_ = syscall.Close(fd)
		return nil
	}
	defer func() { _ = syscall.Close(fd) }()

	// AutoDetectInterface is on for iOS only. iOS has no protect(fd) to exempt
	// a socket from the tunnel, so every outbound socket has to be bound to the
	// physical NIC instead, or the tunnel's /1 routes send it straight back
	// into it. That bind only happens when a default-interface finder is
	// registered, and the finder is only created for auto-detect-interface.
	// Android keeps it off: its socket hook protects the socket, and a hook
	// makes mihomo skip the bind anyway.
	options := LC.Tun{
		Enable:               true,
		Device:               "FlClash",
		Stack:                tunStack,
		DNSHijack:            dnsHijack,
		AutoRoute:            false,
		AutoDetectInterface:  runtime.GOOS == "ios",
		Inet4Address:         prefix4,
		Inet6Address:         prefix6,
		MTU:                  settings.MTU,
		CongestionController: settings.CongestionController,
		FileDescriptor:       dupFd,
	}

	listener, err := sing_tun.New(options, tunnel.Tunnel)

	if err != nil {
		log.Errorln("TUN: %v", err)
		return nil
	}

	return listener
}
