//go:build !ios

package core

// memGuardSummary describes the memory limits the core set for itself, and is
// written into the startup log once the home directory is known (see
// memory_ios.go, which is the only platform that sets any). Elsewhere there is
// nothing to report, so it stays empty and the log line is skipped.
var memGuardSummary string
