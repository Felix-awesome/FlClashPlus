//go:build ios

package platform

import "net"

// ShouldBlockConnection reports whether new connections should be refused due
// to file-descriptor pressure. iOS has no such pressure probe (the fd table is
// not exposed via /proc), so it is always false.
func ShouldBlockConnection() bool {
	return false
}

// QuerySocketUidFromProcFs is unsupported on iOS (no /proc); it always returns
// -1 so process attribution falls back to the no-op resolver.
func QuerySocketUidFromProcFs(source, _ net.Addr) int {
	return -1
}
