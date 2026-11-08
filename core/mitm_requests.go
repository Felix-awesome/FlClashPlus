package core

import (
	"net/url"
	"strconv"
	"strings"

	"github.com/metacubex/mihomo/common/atomic"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/mitm"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const (
	// mitmRuleName fills the rule column of an intercepted request. It was not
	// routed by a rule but rewritten by the MITM ones, and naming that keeps
	// the row distinguishable from an ordinary connection.
	mitmRuleName = "Mitm"
	// mitmChainName labels the outbound of an intercepted request: nothing was
	// dialed through a proxy on its behalf.
	mitmChainName = "MITM"
)

// recordMitmHit adds an exchange a rewrite rule acted on to the request log.
//
// An intercepted request is decrypted and re-originated by the interceptor, so
// it never reaches the tunnel and no connection is tracked for it: without
// this, the request list stays empty exactly while rules do their work.
func recordMitmHit(hit mitm.Hit) {
	log.Debugln(
		"[MITM] %s %s -> %d %s",
		hit.Method,
		hit.URL,
		hit.Status,
		strings.Join(hit.Rules, " ; "),
	)
	tracker := newMitmTracker(hit)
	// The request list learns the row from the join itself, and there is no
	// connection to keep afterwards, so the entry is dropped right away.
	statistic.DefaultManager.Join(tracker)
	statistic.DefaultManager.Leave(tracker)
}

// newMitmTracker builds the request log entry for one intercepted exchange.
func newMitmTracker(hit mitm.Hit) *mitmTracker {
	return &mitmTracker{
		manager: statistic.DefaultManager,
		TrackerInfo: &statistic.TrackerInfo{
			UUID:          utils.NewUUIDV4(),
			Start:         hit.Start,
			Metadata:      mitmMetadata(hit.URL),
			Chain:         constant.Chain{mitmChainName},
			Rule:          mitmRuleName,
			RulePayload:   strings.Join(hit.Rules, " ; "),
			UploadTotal:   atomic.NewInt64(hit.Upload),
			DownloadTotal: atomic.NewInt64(hit.Download),
		},
	}
}

// mitmMetadata describes the request a client made. An intercepted request is
// decrypted before the tunnel picks a route for it, so it has no destination
// address to report; the host and port it asked for are what identify it.
func mitmMetadata(address string) *constant.Metadata {
	metadata := &constant.Metadata{NetWork: constant.TCP}
	parsed, err := url.Parse(address)
	if err != nil || parsed.Host == "" {
		metadata.Host = address
		return metadata
	}
	metadata.Host = parsed.Hostname()
	port := parsed.Port()
	if port == "" {
		port = "443"
	}
	if value, err := strconv.ParseUint(port, 10, 16); err == nil {
		metadata.DstPort = uint16(value)
	}
	return metadata
}

// mitmTracker is a request log entry with no connection behind it. It carries
// what the request list shows, and closing it only drops it from the live
// list, because there is nothing to shut down.
type mitmTracker struct {
	*statistic.TrackerInfo
	manager *statistic.Manager
}

func (t *mitmTracker) ID() string {
	return t.UUID.String()
}

func (t *mitmTracker) Close() error {
	t.manager.Leave(t)
	return nil
}

func (t *mitmTracker) Info() *statistic.TrackerInfo {
	return t.TrackerInfo
}

func (t *mitmTracker) Chains() constant.Chain {
	return t.Chain
}

func (t *mitmTracker) ProviderChains() constant.Chain {
	return t.ProviderChain
}

// AppendToChains implements constant.Connection. The chain of an intercepted
// request stays as it is: no proxy was involved in carrying it.
func (t *mitmTracker) AppendToChains(constant.ProxyAdapter) {}

func (t *mitmTracker) RemoteDestination() string {
	return ""
}
