//go:build ios

// iOS binding for the FlClash core. On iOS the NetworkExtension tunnel owns
// the packet flow, and the Swift side hands over the utun socket file
// descriptor obtained from NEPacketTunnelFlow (via its private
// "socket.fileDescriptor" key). There is no per-socket "protect" call and no
// uid resolution on iOS, so the TunCallbacks are no-ops: every socket is
// reported protected and process lookup is left to the procfs fallback.
package mobile

import "core"

// ResultHandler receives a single result callback from the core. It mirrors
// the Android interface so the same API surface drives both platforms.
type ResultHandler interface {
	OnResult(data []byte) error
}

// tunCallbacks is the no-op implementation of core.TunCallbacks for iOS.
type tunCallbacks struct{}

func (tunCallbacks) Protect(fd int) bool { return true }

func (tunCallbacks) ResolveUid(protocol int, source, target string) int { return -1 }

func (tunCallbacks) ResolvePackage(uid int) string { return "" }

// InvokeMethod dispatches a JSON method call and delivers the result to the
// handler.
func InvokeMethod(data string, handler ResultHandler) {
	core.InvokeMethod(data, func(result []byte) {
		_ = handler.OnResult(result)
	})
}

// StartTun starts the tunnel on the given utun file descriptor. On iOS the fd
// comes from the packet flow; there is no protect/uid callback.
func StartTun(fd int32, stack, address, dns, options string) bool {
	return core.StartTun(tunCallbacks{}, int(fd), stack, address, dns, options)
}

// QuickSetup initializes and applies a configuration in one shot.
func QuickSetup(initParams, setupParams string, handler ResultHandler) {
	core.QuickSetup(initParams, setupParams, func(message string) {
		_ = handler.OnResult([]byte(message))
	})
}

// SetEventListener registers or clears the event listener.
func SetEventListener(handler ResultHandler) {
	if handler == nil {
		core.SetEventListener(nil)
		return
	}
	core.SetEventListener(func(data []byte) {
		_ = handler.OnResult(data)
	})
}

// StopTun tears down the tunnel.
func StopTun() {
	core.StopTun()
}

// StartListener starts the inbound listener (used by the desktop/Android core).
func StartListener() {
	core.StartListener()
}

// StopListener stops the inbound listener.
func StopListener() {
	core.StopListener()
}

// ForceGC triggers a garbage collection pass in the Go runtime.
func ForceGC() {
	core.ForceGC()
}

// UpdateDns updates the DNS servers used by the core.
func UpdateDns(value string) {
	core.UpdateDns(value)
}

// ResetNetwork resets the network state.
func ResetNetwork() {
	core.ResetNetwork()
}

// GetTraffic returns current traffic statistics.
func GetTraffic(onlyStatisticsProxy bool) string {
	return core.GetTraffic(onlyStatisticsProxy)
}

// GetTotalTraffic returns cumulative traffic statistics.
func GetTotalTraffic(onlyStatisticsProxy bool) string {
	return core.GetTotalTraffic(onlyStatisticsProxy)
}
