//go:build !ios

package core

// bootLog is the iOS-only startup log (see bootlog_ios.go). Everywhere else
// the core runs where someone can read its stderr, so it stays a no-op and the
// call sites need no build tags.
func bootLog(string, ...any) {}

// bootLogMemory shares bootLog's fate: the footprint numbers only exist for the
// extension, which has no console (see bootlog_ios.go).
func bootLogMemory(string) {}
