package core

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/metacubex/mihomo/component/mitm"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
)

// The MITM CA and rule set live for the process lifetime and survive config
// reloads, mirroring how the listener itself is recreated around them.
var (
	mitmMu       sync.Mutex
	mitmCA       *mitm.CA
	mitmRuleSet  *mitm.Set
	mitmEnabled  bool
	mitmInited   bool
)

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

	rules, errs := mitm.ParseRules(params.Rules)
	if len(errs) > 0 {
		for _, e := range errs {
			log.Warnln("[MITM] %v", e)
		}
	}
	set := mitm.NewSet()
	set.Replace(rules)

	mitmRuleSet = set
	mitmInited = true
	if mitmCA == nil && mitmEnabled {
		if ca, err := loadMitmCA(); err == nil {
			mitmCA = ca
		}
	}
	mitm.Enable(mitmEnabled, mitmCA, set)
	log.Infoln("[MITM] installed %d rewrite rules", len(rules))
	return nil
}
