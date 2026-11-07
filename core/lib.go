//go:build android || ios

package core

import (
	"core/platform"
	t "core/tun"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
)

type TunCallbacks interface {
	Protect(fd int) bool
	ResolveUid(protocol int, source, target string) int
	ResolvePackage(uid int) string
}

var (
	eventListenerLock sync.RWMutex
	eventListener     func([]byte)
	listening         atomic.Bool
)

type TunHandler struct {
	listener  *sing_tun.Listener
	callbacks TunCallbacks

	mu sync.RWMutex
}

func (th *TunHandler) start(fd int, stack, address, dns, options string) bool {
	configMu.Lock()
	defer configMu.Unlock()

	th.mu.Lock()
	th.initHook()
	th.mu.Unlock()

	// t.Start runs outside th.mu on purpose. The hook is live from initHook
	// onwards, and a socket opened anywhere inside Start reaches handleProtect
	// on this very goroutine — an RLock taken while this one holds the write
	// lock deadlocks the start outright. Nothing is lost by dropping it: both
	// hooks return early until th.listener is set, which is below.
	tunListener := t.Start(fd, stack, address, dns, options)

	th.mu.Lock()
	defer th.mu.Unlock()
	if tunListener != nil {
		log.Infoln("TUN address: %v", tunListener.Address())
		th.listener = tunListener
		return true
	}
	th.clear()
	return false
}

func (th *TunHandler) close() {
	th.mu.Lock()
	defer th.mu.Unlock()
	th.clear()
}

func (th *TunHandler) clear() {
	th.removeHook()
	if th.listener != nil {
		_ = th.listener.Close()
	}
	th.callbacks = nil
	th.listener = nil
}

// A refused protect never fails the dial: mihomo's tunnel retries a failed
// dial ten times, and Android refuses only after the VPN was revoked, when the
// routes are gone and an unprotected socket takes the default network.
func (th *TunHandler) handleProtect(fd int) {
	th.mu.RLock()
	defer th.mu.RUnlock()

	if th.listener == nil || th.callbacks == nil {
		return
	}
	th.callbacks.Protect(fd)
}

func (th *TunHandler) handleResolveProcess(source, target net.Addr) (int, string) {
	th.mu.RLock()
	defer th.mu.RUnlock()

	if th.listener == nil || th.callbacks == nil {
		return -1, ""
	}
	var protocol int
	switch source.Network() {
	case "udp", "udp4", "udp6":
		protocol = syscall.IPPROTO_UDP
	case "tcp", "tcp4", "tcp6":
		protocol = syscall.IPPROTO_TCP
	}
	var uid int
	if sdkVersion.Load() < 29 {
		uid = platform.QuerySocketUidFromProcFs(source, target)
	} else {
		uid = th.callbacks.ResolveUid(protocol, source.String(), target.String())
	}
	if uid < 0 {
		return -1, ""
	}
	return uid, th.callbacks.ResolvePackage(uid)
}

var (
	installHooksOnce sync.Once
	activeTunHandler atomic.Pointer[TunHandler]
)

func installHooks() {
	installHooksOnce.Do(func() {
		// Android protects each socket through this hook: VpnService.protect
		// exempts it from the VPN routes, which is the only way off the tunnel
		// there. iOS has no such call -- Protect is a no-op in mobile_ios.go --
		// and the hook is actively harmful on it: mihomo short-circuits on a
		// non-nil DefaultSocketHook and skips the physical-interface bind it
		// would otherwise do (see dialContext). Binding is the only way off the
		// tunnel on iOS, so the hook must not be installed there.
		if runtime.GOOS != "ios" {
			dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
				if platform.ShouldBlockConnection() {
					return errBlocked
				}
				th := activeTunHandler.Load()
				if th == nil {
					return nil
				}
				return conn.Control(func(fd uintptr) {
					th.handleProtect(int(fd))
				})
			}
		}
		process.DefaultPackageNameResolver = func(metadata *constant.Metadata) (string, error) {
			th := activeTunHandler.Load()
			if th == nil {
				return "", process.ErrInvalidNetwork
			}
			src, dst := metadata.RawSrcAddr, metadata.RawDstAddr
			if src == nil || dst == nil {
				return "", process.ErrInvalidNetwork
			}
			// Everywhere else mihomo fills Uid from its own procfs lookup, the one Android took away.
			uid, packageName := th.handleResolveProcess(src, dst)
			if uid >= 0 {
				metadata.Uid = uint32(uid)
			}
			return packageName, nil
		}
	})
}

func (th *TunHandler) initHook() {
	installHooks()
	activeTunHandler.Store(th)
}

// Swap the handler, never the hook: mihomo nil-checks DefaultSocketHook once and
// dereferences it again when the socket is created, so clearing it mid-dial
// calls a nil func value.
func (th *TunHandler) removeHook() {
	activeTunHandler.CompareAndSwap(th, nil)
}

var (
	tunLock    sync.Mutex
	errBlocked = errors.New("blocked: the process is out of file descriptors")
	tunHandler *TunHandler
)

func handleStopTun() {
	tunLock.Lock()
	defer tunLock.Unlock()
	stopTunLocked()
}

func stopTunLocked() {
	if tunHandler == nil {
		return
	}
	tunHandler.close()
	tunHandler = nil
}

func handleStartTun(callbacks TunCallbacks, fd int, stack, address, dns, options string) bool {
	tunLock.Lock()
	defer tunLock.Unlock()
	stopTunLocked()
	if fd == 0 {
		logError("startTun was handed no tun descriptor")
		return false
	}
	tunHandler = &TunHandler{
		callbacks: callbacks,
	}
	if tunHandler.start(fd, stack, address, dns, options) {
		bootLog("tun live (stack=%s address=%s dns=%s)", stack, address, dns)
		logOutboundInterface()
		return true
	}
	// start() already cleared the handler, so nothing protects sockets from
	// here on. Android has the routes up regardless, so the caller has to tear
	// the VPN down rather than leave the device pointed at a black hole.
	tunHandler = nil
	return false
}

// logOutboundInterface records where the core's own sockets will leave from.
//
// This is the whole game on iOS: the tunnel owns the route table, so an
// outbound socket that is not bound to the physical NIC goes straight back
// into the tunnel, and the app reports it as having no network at all with the
// tunnel up. Recording the outcome turns that into one line in the exported
// log instead of another round of guesswork.
func logOutboundInterface() {
	if name := dialer.DefaultInterface.Load(); name != "" {
		bootLog("outbound interface: %s (set by the config)", name)
		return
	}
	finder := dialer.DefaultInterfaceFinder.Load()
	if finder == nil {
		bootLog("outbound interface: unbound, no finder registered (sockets take the default route)")
		return
	}
	name := finder.FindInterfaceName(netip.MustParseAddr("1.1.1.1"))
	bootLog("outbound interface: %q", name)
	// An interface can be up, have an IPv4 address and still carry no internet
	// (a captive Wi-Fi while the device uses cellular, for instance). The name
	// alone cannot tell that from a broken bind, so record what the chosen NIC
	// actually owns: the exported log then shows whether the core dialled from
	// a real address or from a network that only looks usable.
	if iface, err := net.InterfaceByName(name); err == nil {
		if addrs, err := iface.Addrs(); err == nil {
			for _, addr := range addrs {
				if prefix, err := netip.ParsePrefix(addr.String()); err == nil && prefix.Addr().Is4() {
					bootLog("outbound interface address: %s", prefix.Addr())
				}
			}
		}
	} else {
		bootLog("outbound interface lookup failed: %v", err)
	}
}

var (
	dnsUpdateMu  sync.Mutex
	dnsUpdateSeq atomic.Uint64
)

func handleUpdateDns(value string) {
	// mihomo turns the [""] that Split returns for no servers into a "udp://:"
	// nameserver, which keeps the system resolver off its default fallback.
	var addr []string
	if value != "" {
		addr = strings.Split(value, ",")
	}
	seq := dnsUpdateSeq.Add(1)
	safeGo("updateDns", func() {
		dnsUpdateMu.Lock()
		defer dnsUpdateMu.Unlock()
		if seq != dnsUpdateSeq.Load() {
			return
		}
		log.Infoln("[DNS] updateDns %s", value)
		dns.UpdateSystemDNS(addr)
		dns.FlushCacheWithDefaultResolver()
	})
}

func init() {
	registerMethod(updateDnsMethod, withArguments(func(value string) bool {
		handleUpdateDns(value)
		return true
	}))
}

// gobind runs an export on the caller's thread and turns no panic into a Java
// exception, so a panic that leaves one ends the whole application.
func recoverExport(name string) {
	if r := recover(); r != nil {
		logError("panic in %s: %v\n%s", name, r, stackTrace())
	}
}

func InvokeMethod(data string, reply func([]byte)) {
	defer recoverExport("invokeMethod")
	call := &MethodCall{}
	if err := json.Unmarshal([]byte(data), call); err != nil {
		reply(encodeResponse(MethodResponse{Error: &MethodError{
			Code:    "invalid_method_call",
			Message: err.Error(),
		}}))
		return
	}
	dispatchMethodCall(call, reply)
}

func StartTun(callbacks TunCallbacks, fd int, stack, address, dns, options string) bool {
	defer recoverExport("startTun")
	started := handleStartTun(callbacks, fd, stack, address, dns, options)
	if !started {
		return false
	}
	if !isRunning.Load() {
		handleStartListener()
	} else {
		handleResetConnections()
		bumpRouteEpoch()
	}
	return true
}

func QuickSetup(initParamsString, setupParamsString string, answer func(string)) {
	go func() {
		defer func() {
			if r := recover(); r != nil {
				logError("panic in quickSetup: %v\n%s", r, stackTrace())
				answer(fmt.Sprintf("internal panic: %v", r))
			}
		}()
		initParams := InitParams{}
		if err := json.Unmarshal([]byte(initParamsString), &initParams); err != nil {
			answer("init failed")
			return
		}
		handleInitClash(&initParams)
		setupParams := &SetupParams{}
		if err := json.Unmarshal([]byte(setupParamsString), setupParams); err != nil {
			answer(err.Error())
			return
		}
		isRunning.Store(true)
		if err := handleSetupConfig(setupParams); err != nil {
			answer(err.Error())
			return
		}
		answer("")
	}()
}

// The listener goes away with the Flutter engine, which never gets to release
// the route watch it held, while the service and this core run on.
func SetEventListener(listener func([]byte)) {
	defer recoverExport("setEventListener")
	eventListenerLock.Lock()
	eventListener = listener
	listening.Store(listener != nil)
	eventListenerLock.Unlock()
	if listener == nil {
		stopRouteWatch()
	}
}

func hasEventListener() bool {
	return listening.Load()
}

func GetTotalTraffic(onlyStatisticsProxy bool) string {
	defer recoverExport("getTotalTraffic")
	return marshalResult(handleGetTotalTraffic(onlyStatisticsProxy))
}

func GetTraffic(onlyStatisticsProxy bool) string {
	defer recoverExport("getTraffic")
	return marshalResult(handleGetTraffic(onlyStatisticsProxy))
}

func marshalResult(value any) string {
	data, err := json.Marshal(value)
	if err != nil {
		logError("Result marshal error: %v", err)
		return ""
	}
	return string(data)
}

func deliverEvent(data []byte) {
	eventListenerLock.RLock()
	defer eventListenerLock.RUnlock()
	if eventListener == nil {
		return
	}
	eventListener(data)
}

func StopTun() {
	defer recoverExport("stopTun")
	handleStopTun()
	if isRunning.Load() {
		handleStopListener()
	}
}

func StartListener() {
	defer recoverExport("startListener")
	if !isRunning.Load() {
		handleStartListener()
	}
}

func StopListener() {
	defer recoverExport("stopListener")
	if isRunning.Load() {
		handleStopListener()
	}
}

var forceGCPending atomic.Bool

// Android calls this from onLowMemory and onTrimMemory on the main thread, which
// the Flutter UI shares, and a full collection of a large profile spans frames.
func ForceGC() {
	defer recoverExport("forceGC")
	if !forceGCPending.CompareAndSwap(false, true) {
		return
	}
	safeGo("forceGC", func() {
		defer forceGCPending.Store(false)
		handleForceGC()
	})
}

func UpdateDns(value string) {
	defer recoverExport("updateDns")
	handleUpdateDns(value)
}

func ResetNetwork() {
	defer recoverExport("resetNetwork")
	safeGo("resetNetwork", handleResetNetwork)
}
