package core

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/mitm"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// captureRequests replaces the notification the request log listens to, so a
// test can see what would have been sent to the app.
func captureRequests(t *testing.T) *[]statistic.Tracker {
	t.Helper()
	previous := statistic.DefaultRequestNotify
	captured := make([]statistic.Tracker, 0, 4)
	statistic.DefaultRequestNotify = func(c statistic.Tracker) {
		captured = append(captured, c)
	}
	t.Cleanup(func() { statistic.DefaultRequestNotify = previous })
	return &captured
}

func testHit() mitm.Hit {
	return mitm.Hit{
		Start:    time.Now().Add(-time.Second),
		Method:   "GET",
		URL:      "https://api.example.com/2/statuses/home_timeline?id=1",
		Rules:    []string{`^https://api\.example\.com/2/statuses url script-response-body ad.js`},
		Status:   200,
		Upload:   32,
		Download: 2048,
	}
}

func TestRecordMitmHitReportsARequestRow(t *testing.T) {
	captured := captureRequests(t)

	hit := testHit()
	recordMitmHit(hit)

	if len(*captured) != 1 {
		t.Fatalf("reported %d requests, want 1", len(*captured))
	}
	tracker := (*captured)[0]
	info := tracker.Info()
	if info.Metadata.Host != "api.example.com" {
		t.Errorf("host = %q, want api.example.com", info.Metadata.Host)
	}
	if info.Metadata.DstPort != 443 {
		t.Errorf("port = %d, want the https default 443", info.Metadata.DstPort)
	}
	if info.Rule != mitmRuleName || info.RulePayload != hit.Rules[0] {
		t.Errorf("rule = %q %q, want %q %q", info.Rule, info.RulePayload, mitmRuleName, hit.Rules[0])
	}
	if len(info.Chain) != 1 || info.Chain[0] != mitmChainName {
		t.Errorf("chains = %v, want [%s]", info.Chain, mitmChainName)
	}
	if got := info.UploadTotal.Load(); got != hit.Upload {
		t.Errorf("upload = %d, want %d", got, hit.Upload)
	}
	if got := info.DownloadTotal.Load(); got != hit.Download {
		t.Errorf("download = %d, want %d", got, hit.Download)
	}
	if !info.Start.Equal(hit.Start) {
		t.Errorf("start = %v, want %v", info.Start, hit.Start)
	}
	// The row is a log entry, not a connection: it must not linger in the live
	// list, where it would look like something that can be closed.
	if statistic.DefaultManager.Get(tracker.ID()) != nil {
		t.Error("the request row stayed in the live connection list")
	}
}

func TestMitmTrackerMarshalsLikeARequest(t *testing.T) {
	data, err := json.Marshal(newMitmTracker(testHit()))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	// The keys the app reads a request from.
	for _, key := range []string{
		"id",
		"start",
		"metadata",
		"chains",
		"rule",
		"rulePayload",
		"upload",
		"download",
	} {
		if _, ok := decoded[key]; !ok {
			t.Errorf("marshalled request is missing %q: %s", key, data)
		}
	}

	metadata, ok := decoded["metadata"].(map[string]any)
	if !ok {
		t.Fatalf("metadata is not an object: %s", data)
	}
	if metadata["host"] != "api.example.com" {
		t.Errorf("metadata.host = %v", metadata["host"])
	}
	// The app parses the port as a string, which is why the field is tagged.
	if metadata["destinationPort"] != "443" {
		t.Errorf("metadata.destinationPort = %v, want \"443\"", metadata["destinationPort"])
	}
	if metadata["network"] != "tcp" {
		t.Errorf("metadata.network = %v, want tcp", metadata["network"])
	}
	if decoded["rule"] != mitmRuleName {
		t.Errorf("rule = %v, want %s", decoded["rule"], mitmRuleName)
	}
}
