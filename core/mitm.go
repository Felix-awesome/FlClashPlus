package core

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"sync"
	"time"

	"github.com/metacubex/mihomo/component/mitm"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
)

// The MITM CA and rule set live for the process lifetime and survive config
// reloads, mirroring how the listener itself is recreated around them.
var (
	mitmMu      sync.Mutex
	mitmCA      *mitm.CA
	mitmRuleSet *mitm.Set
	mitmEnabled bool
	mitmInited  bool

	mitmWatchdogOnce sync.Once
)

// How often the footprint is reported while rewriting is on.
//
// Two minutes was too coarse to see anything: the extension dies within seconds
// of installing a rule set, so the window has to be shorter than the failure,
// not longer. Two seconds for the first minute -- the window every kill has
// happened in -- then every half minute, because a session that runs for hours
// would otherwise fill the log with nothing but footprint lines and push out
// the lines that say what happened.
const (
	mitmWatchdogFastInterval = 2 * time.Second
	mitmWatchdogSlowInterval = 30 * time.Second
	mitmWatchdogFastSamples  = 30
)

// startMitmWatchdog reports the core's footprint while interception is on.
//
// A tunnel extension that outgrows the memory budget iOS allows it is killed by
// the system, and such a kill leaves nothing in the app's log -- the tunnel
// simply stops and the VPN badge disappears. These numbers are what tells that
// apart from a crash: a heap that climbs towards the budget is a leak, a heap
// that stays flat and a tunnel that still stops is a fault.
//
// The line is written with bootLogMemory rather than the log package: mihomo's
// log is filtered to warnings on its way into the startup log, so an Infoln
// here produced no output at all (see bootLogMemory).
func startMitmWatchdog() {
	mitmWatchdogOnce.Do(func() {
		go func() {
			ticker := time.NewTicker(mitmWatchdogFastInterval)
			defer ticker.Stop()
			samples := 0
			for range ticker.C {
				mitmMu.Lock()
				enabled := mitmEnabled
				mitmMu.Unlock()
				if enabled {
					bootLogMemory("mitm watchdog")
				}
				samples++
				if samples == mitmWatchdogFastSamples {
					ticker.Reset(mitmWatchdogSlowInterval)
				}
			}
		}()
	})
}

// mitmHome returns the directory under mihomo's home dir where the MITM CA is
// persisted, so a device only has to trust one root across app restarts.
func mitmHome() string {
	return filepath.Join(constant.Path.HomeDir(), "mitm")
}

// loadMitmCA restores or creates the MITM root CA. The first run generates a
// fresh CA and persists it; later runs load it back.
func loadMitmCA() (*mitm.CA, error) {
	dir := mitmHome()
	certPath := filepath.Join(dir, "ca.crt")
	keyPath := filepath.Join(dir, "ca.key")

	certPEM, certErr := os.ReadFile(certPath)
	keyPEM, keyErr := os.ReadFile(keyPath)
	if certErr == nil && keyErr == nil {
		ca, err := mitm.LoadCA(certPEM, keyPEM)
		if err == nil {
			return ca, nil
		}
		log.Warnln("[MITM] failed to load persisted CA, regenerating: %v", err)
	}

	ca, err := mitm.NewCA()
	if err != nil {
		return nil, err
	}

	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(certPath, ca.CertificatePEM(), 0o600); err != nil {
		return nil, err
	}

	// Persist the private key as well, so the installed root stays valid
	// across core restarts instead of silently changing underneath it.
	keyPEMOut, err := ca.PrivateKeyPEM()
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(keyPath, keyPEMOut, 0o600); err != nil {
		return nil, err
	}
	return ca, nil
}

// handleSetMitm enables or disables interception and installs the CA.
func handleSetMitm(params *SetMitmParams) error {
	mitmMu.Lock()
	defer mitmMu.Unlock()

	if params == nil {
		return fmt.Errorf("missing set-mitm params")
	}

	bootLogMemory("setMitm begin (enable=" + fmt.Sprint(params.Enable) + ")")
	defer func() {
		// The CA generation, the rule set and the TLS machinery are all
		// allocated here, and this is one of the two steps the extension has
		// been seen to die in. Give the pages back before returning rather than
		// leaving them for a GC that may not run inside the budget.
		debug.FreeOSMemory()
		bootLogMemory("setMitm done (enable=" + fmt.Sprint(params.Enable) + ")")
	}()

	var ca *mitm.CA
	if params.Enable {
		loaded, err := loadMitmCA()
		if err != nil {
			return err
		}
		ca = loaded
		mitmCA = ca
	} else {
		ca = mitmCA
	}

	mitmEnabled = params.Enable
	mitmInited = true
	if mitmRuleSet == nil {
		mitmRuleSet = mitm.NewSet()
	}
	mitm.Enable(params.Enable, ca, mitmRuleSet)
	log.Infoln("[MITM] interception %s", map[bool]string{true: "enabled", false: "disabled"}[params.Enable])
	if params.Enable {
		startMitmWatchdog()
	}
	return nil
}

// handleGetMitmCertificate returns the root CA to install on the device.
func handleGetMitmCertificate() (*MitmCertificate, error) {
	mitmMu.Lock()
	defer mitmMu.Unlock()

	ca, err := loadMitmCA()
	if err != nil {
		return nil, err
	}
	if mitmCA == nil {
		mitmCA = ca
	}
	return &MitmCertificate{Certificate: string(ca.CertificatePEM())}, nil
}

// handleUpdateMitmRules compiles and installs a new rewrite rule set.
func handleUpdateMitmRules(params *UpdateMitmRulesParams) error {
	mitmMu.Lock()
	defer mitmMu.Unlock()

	if params == nil {
		return fmt.Errorf("missing update-mitm-rules params")
	}

	// This is the step the extension has died in three times: the app sends the
	// rule set over the file bridge, this compiles it, and the process either
	// comes back with an answer or never does. The two lines bracket the work
	// so a kill inside it leaves the "begin" without a matching "done", and the
	// numbers say whether the heap moved.
	bootLogMemory(fmt.Sprintf("mitm rules begin (%d bytes, %d scripts)",
		len(params.Rules), len(params.Scripts)))
	defer func() {
		debug.FreeOSMemory()
		bootLogMemory("mitm rules done")
	}()

	parsed, errs := mitm.Parse(params.Rules)
	if len(errs) > 0 {
		for _, e := range errs {
			log.Warnln("[MITM] %v", e)
		}
	}
	set := mitm.NewSet()
	set.Replace(parsed.Rules)
	// A pasted Quantumult X configuration carries its interception allow-list
	// in a "[mitm]" section; honouring it keeps such a file working unchanged.
	set.SetHostnames(parsed.Hostnames)

	// A script rule whose source was never downloaded cannot run. Saying so at
	// install time is the only way a user finds out, because the request itself
	// just passes through untouched.
	missing := 0
	for _, r := range parsed.Rules {
		if r.Script != "" ||
			(r.Action != mitm.ActionScriptRequest && r.Action != mitm.ActionScriptResponse) {
			continue
		}
		if _, ok := params.Scripts[r.Arg]; !ok {
			missing++
		}
	}
	if missing > 0 {
		log.Warnln("[MITM] %d script rule(s) reference a script that was not downloaded", missing)
	}

	// Wire the Quantumult X script engine, resolving script references (URL or
	// local name) against the scripts bundled with this update. Without any
	// scripts the engine is left unset and only fixed rewrite actions run.
	var engine *mitm.ScriptEngine
	var loader mitm.ScriptLoader
	if len(params.Scripts) > 0 {
		engine = &mitm.ScriptEngine{}
		loader = func(ref string) string {
			return params.Scripts[ref]
		}
	}
	mitm.SetScriptEngine(engine, loader)

	mitmRuleSet = set
	mitmInited = true
	if mitmCA == nil && mitmEnabled {
		if ca, err := loadMitmCA(); err == nil {
			mitmCA = ca
		}
	}
	mitm.Enable(mitmEnabled, mitmCA, set)
	log.Infoln(
		"[MITM] installed %d rewrite rules (%d scripts, %d intercepted hosts)",
		len(parsed.Rules), len(params.Scripts), len(parsed.Hostnames),
	)
	return nil
}
