//go:build ios

package core

import (
	"fmt"
	"runtime/debug"

	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/log"
)

// The packet-tunnel extension runs under a hard jetsam ceiling: iOS 15 raised
// the per-process limit to 50 MiB (it was 15 MiB through iOS 14), and the
// kernel kills the process the instant it crosses the line, with no warning and
// no stopTunnel callback -- the extension simply disappears and the tunnel
// reports "disconnected". This is exactly the failure that shows up as the
// tunnel dying a few seconds after setupConfig: applying a config recompiles
// the rule set and (re)loads the geo databases, a spike the default Go GC
// policy does not catch in time under a 50 MiB budget.
//
// Setting GOMEMLIMIT well below the ceiling makes the runtime treat that line
// as "full" and collect before the spike can reach the hard limit. The number
// is deliberately conservative: resident memory also includes the runtime
// itself, the gVisor buffer pools and every linked library, so the Go heap is
// only ever a fraction of the 50 MiB the kernel counts. Pairing it with a
// tighter GOGC keeps the heap near the soft limit instead of letting it balloon
// toward a ceiling it can no longer pull back from.
//
// Android and the desktop get no limit here: they have a real budget and the
// app already drives ForceGC on low-memory callbacks.
func init() {
	const (
		// The jetsam ceiling the kernel enforces (MiB). Not contractual -- Apple
		// says to test rather than hard-code it -- but stable across iOS 15-18
		// for packet-tunnel providers.
		hardLimitMiB = 50

		// How much of the ceiling the Go heap may occupy. The remainder is left
		// to the runtime, the tun stack and the libraries, which the heap limit
		// does not count against but the kernel's per-process limit does.
		//
		// This was 32 and the extension still died at the ceiling: the measured
		// kills all land within seconds of a large allocation, and the kernel
		// counts more than the Go heap -- the tun stack's buffers, the TLS
		// session caches and every linked library page are in the same budget.
		//
		// It is deliberately not lower. Below the live set the runtime does not
		// fail, it collects continuously, which would turn "the tunnel dies" into
		// "the tunnel is up and unusable". The geo verify this build turns off
		// (below) removes the largest resident block, so the cut lands on the
		// part that was transient anyway.
		heapBudgetMiB = 24

		// A tighter GC target: the heap may grow this much above its live set
		// before a collection is forced. The default 100 lets a profile load
		// spike far past the budget before the runtime reacts, and the soft
		// limit alone only reacts once the heap is already at the line.
		gcPercent = 20
	)

	limit := int64(heapBudgetMiB) << 20
	debug.SetMemoryLimit(limit)
	debug.SetGCPercent(gcPercent)

	// The geo databases are ours: every one of them is downloaded by
	// installDatabase, verified there and only then renamed into place (see
	// geo.go). The eager re-check geodata runs on first use buys nothing and
	// costs the whole file parsed into memory plus a process-lifetime matcher
	// -- for the "CN" list specifically, which most profiles never ask for.
	geodata.SetVerifyOnInit(false)

	memGuardSummary = fmt.Sprintf(
		"GOMEMLIMIT=%d MiB (jetsam ceiling ~%d MiB), GOGC=%d, geo verify-on-init off",
		heapBudgetMiB, hardLimitMiB, gcPercent,
	)
	log.Infoln("[APP] iOS memory guard: %s", memGuardSummary)
}

// memGuardSummary is written into the startup log once the home directory is
// known: this init runs before the core has one, so the line cannot be written
// here. A reader of the log needs the limit next to the footprint numbers to
// tell "close to the budget" from "no budget at all".
var memGuardSummary string
