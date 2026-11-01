//go:build !ios

package core

// bootLog is the iOS-only startup log (see bootlog_ios.go). Everywhere else
// the core runs where someone can read its stderr, so it stays a no-op and the
// call sites need no build tags.
func bootLog(string, ...any) {}
