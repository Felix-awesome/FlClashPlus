package core

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/geodata"
	mihomoHttp "github.com/metacubex/mihomo/component/http"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/metacubex/mihomo/component/updater"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
)

const (
	geoDownloadTimeout = 90 * time.Second
	// MMDB is a few megabytes and GeoSite.dat about ten times that; anything
	// past this is not a rule database but a redirect that went somewhere else.
	geoDownloadLimit = 256 << 20
	geoDownloadTemp  = ".download"
)

// geoDatabase is one of the files rules and IP lookups are answered from.
//
// The download is ours rather than mihomo's updater on purpose. The updater
// fetches through the tunnel, so the request is routed by the very rule set
// these files implement and travels over whichever node is selected: a database
// that only matters once the tunnel works cannot be fetched through it. On iOS
// the tunnel lives in the same process that replaces the file, which turns a
// failed fetch into a dead tunnel.
type geoDatabase struct {
	url    func() string
	path   func() string
	verify func(path string) error
	reload func()
}

var (
	mmdbDatabase = geoDatabase{
		url:  geodata.MmdbUrl,
		path: func() string { return C.Path.MMDB() },
		verify: func(path string) error {
			if !mmdb.Verify(path) {
				return errors.New("invalid MMDB database file")
			}
			return nil
		},
		reload: mmdb.ReloadIP,
	}
	asnDatabase = geoDatabase{
		url:  geodata.ASNUrl,
		path: func() string { return C.Path.ASN() },
		verify: func(path string) error {
			if !mmdb.Verify(path) {
				return errors.New("invalid ASN database file")
			}
			return nil
		},
		reload: mmdb.ReloadASN,
	}
	geoIPDatabase = geoDatabase{
		url:  geodata.GeoIpUrl,
		path: func() string { return C.Path.GeoIP() },
		verify: func(path string) error {
			buf, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			loader, err := geodata.GetGeoDataLoader("standard")
			if err != nil {
				return err
			}
			if _, err = loader.LoadIPByBytes(buf, "cn"); err != nil {
				return fmt.Errorf("invalid GeoIP database file: %w", err)
			}
			return nil
		},
		reload: geodata.ClearGeoIPCache,
	}
	geoSiteDatabase = geoDatabase{
		url:  geodata.GeoSiteUrl,
		path: func() string { return C.Path.GeoSite() },
		verify: func(path string) error {
			buf, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			loader, err := geodata.GetGeoDataLoader("standard")
			if err != nil {
				return err
			}
			if _, err = loader.LoadSiteByBytes(buf, "cn"); err != nil {
				return fmt.Errorf("invalid GeoSite database file: %w", err)
			}
			return nil
		},
		reload: geodata.ClearGeoSiteCache,
	}
)

// geoUpdateFunc installs one database and reports whether the file on disk was
// already current.
type geoUpdateFunc func() (skipped bool, err error)

type geoResource struct {
	update geoUpdateFunc
	url    func() string
	setUrl func(string)
}

func updateDatabase(database geoDatabase) geoUpdateFunc {
	return func() (bool, error) {
		return installDatabase(database)
	}
}

var geoResources = map[string]geoResource{
	"MMDB":    {update: updateDatabase(mmdbDatabase), url: geodata.MmdbUrl, setUrl: geodata.SetMmdbUrl},
	"ASN":     {update: updateDatabase(asnDatabase), url: geodata.ASNUrl, setUrl: geodata.SetASNUrl},
	"GEOIP":   {update: updateDatabase(geoIPDatabase), url: geodata.GeoIpUrl, setUrl: geodata.SetGeoIpUrl},
	"GEOSITE": {update: updateDatabase(geoSiteDatabase), url: geodata.GeoSiteUrl, setUrl: geodata.SetGeoSiteUrl},
}

// mihomo's updaters read these links without a lock, so an unchanged one is never rewritten.
func setGeoResourceUrl(geoType string, link string) {
	resource, exist := geoResources[strings.ToUpper(geoType)]
	if !exist {
		log.Warnln("geox-url: unknown geo resource %q", geoType)
		return
	}
	if link != "" && link != resource.url() {
		resource.setUrl(link)
	}
}

func claimGeoUpdate(geoType string) bool {
	return claimUpdate(geoUpdateScope + geoType)
}

func releaseGeoUpdate(geoType string) {
	releaseUpdate(geoUpdateScope + geoType)
}

func handleUpdateGeoData(geoType string) error {
	resource, exist := geoResources[geoType]
	if !exist {
		logError("updateGeoData: unknown geo resource %q", geoType)
		return fmt.Errorf("unknown geo resource: %s", geoType)
	}
	if !claimGeoUpdate(geoType) {
		return fmt.Errorf("geo update already in progress: %s", geoType)
	}
	safeGo("updateGeoData("+geoType+")", func() {
		defer releaseGeoUpdate(geoType)
		runGeoUpdate(geoType, resource)
	})
	return nil
}

// runGeoUpdate installs one database and reports it exactly the way the
// scheduled updater does, so the app sees one event stream either way.
func runGeoUpdate(geoType string, resource geoResource) {
	onGeoUpdate(geoType, true, false, nil)
	skipped, err := resource.update()
	if err != nil {
		logError("updateGeoData(%s) error: %v", geoType, err)
	} else {
		bootLog("geo resource %s: skipped=%t", geoType, skipped)
	}
	onGeoUpdate(geoType, false, skipped, err)
}

// installDatabase downloads one database and swaps it in.
//
// The download is verified while it is still a temporary copy and only then
// renamed over the real file: a broken response can never leave the app with a
// truncated database. The old mapping is deliberately not closed first -- the
// rename gives the reload a new file without ever pulling the database out from
// under the connections being matched against it.
func installDatabase(database geoDatabase) (skipped bool, err error) {
	target := database.path()
	if target == "" {
		return false, errors.New("geo database path is not available")
	}
	data, err := downloadDatabase(database.url())
	if err != nil {
		return false, err
	}
	if len(data) == 0 {
		return false, errors.New("downloaded database is empty")
	}
	hash := utils.MakeHash(data)
	if current, readErr := os.ReadFile(target); readErr == nil && utils.MakeHash(current).Equal(hash) {
		// Same bytes: keep the file, but stamp it as checked now so the next
		// scheduled update is an interval away rather than immediate.
		_ = os.Chtimes(target, time.Now(), time.Now())
		return true, nil
	}
	temp := target + geoDownloadTemp
	if err = os.WriteFile(temp, data, 0o644); err != nil {
		return false, err
	}
	if err = database.verify(temp); err != nil {
		_ = os.Remove(temp)
		return false, err
	}
	if err = os.Rename(temp, target); err != nil {
		_ = os.Remove(temp)
		return false, err
	}
	database.reload()
	return false, nil
}

// geoHTTPClient fetches databases outside the tunnel.
//
// dialer.DialContext binds the socket to the physical interface on the mobile
// platforms, which is what keeps this request off the utun: it reaches the host
// directly, with no node in between.
var geoHTTPClient = &http.Client{
	Timeout: geoDownloadTimeout,
	Transport: &http.Transport{
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			return dialer.DialContext(ctx, network, address)
		},
		ForceAttemptHTTP2:   true,
		MaxIdleConns:        4,
		IdleConnTimeout:     30 * time.Second,
		TLSHandshakeTimeout: 10 * time.Second,
	},
}

func downloadDatabase(link string) ([]byte, error) {
	if link == "" {
		return nil, errors.New("geo database link is empty")
	}
	ctx, cancel := context.WithTimeout(context.Background(), geoDownloadTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, link, nil)
	if err != nil {
		return nil, err
	}
	if agent := mihomoHttp.UA(); agent != "" {
		request.Header.Set("User-Agent", agent)
	}
	response, err := geoHTTPClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return nil, errors.New(response.Status)
	}
	return io.ReadAll(io.LimitReader(response.Body, geoDownloadLimit))
}

func onGeoUpdate(geoType string, updating bool, skipped bool, updateErr error) {
	if updating {
		claimUpdateAs(geoUpdateScope+geoType, true)
	} else {
		releaseHookUpdate(geoUpdateScope + geoType)
		scheduleReclaimOwnership()
		if !skipped && updateErr == nil {
			changeRoute(routeMoved)
		}
	}
	status := GeoUpdateStatus{Type: geoType, Updating: updating, Skipped: skipped}
	if updateErr != nil {
		status.Error = updateErr.Error()
	}
	sendMessage(GeoUpdateMessage, status)
}

var (
	registerGeoUpdater = registerGeoUpdaterWithOwnDownloader
	stopGeoUpdater     = stopGeoUpdaterWithOwnDownloader
)

// The scheduled updater is ours as well: mihomo's own would fetch through the
// tunnel, which is the behaviour this file exists to avoid.
var (
	geoUpdaterMutex  sync.Mutex
	geoUpdaterCancel context.CancelFunc
)

func registerGeoUpdaterWithOwnDownloader() {
	geoUpdaterMutex.Lock()
	defer geoUpdaterMutex.Unlock()

	stopGeoUpdaterLocked()

	interval := updater.GeoUpdateInterval()
	if interval <= 0 {
		log.Infoln("[GEO] Invalid update interval: %d", interval)
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	geoUpdaterCancel = cancel
	go runGeoUpdater(ctx, interval)
}

func stopGeoUpdaterWithOwnDownloader() {
	geoUpdaterMutex.Lock()
	defer geoUpdaterMutex.Unlock()
	stopGeoUpdaterLocked()
}

func stopGeoUpdaterLocked() {
	if geoUpdaterCancel == nil {
		return
	}
	geoUpdaterCancel()
	geoUpdaterCancel = nil
}

func runGeoUpdater(ctx context.Context, intervalHours int) {
	interval := time.Duration(intervalHours) * time.Hour
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	if last, err := geoDatabaseModTime(); err == nil && last.Add(interval).Before(time.Now()) {
		if err := updateAllDatabases(); err != nil {
			log.Infoln("[GEO] Failed to update GEO database: %s", err.Error())
		}
	}
	for {
		select {
		case <-ctx.Done():
			log.Infoln("[GEO] Geo updater stopped")
			return
		case <-ticker.C:
			log.Infoln("[GEO] updating database every %d hours", intervalHours)
			if err := updateAllDatabases(); err != nil {
				log.Infoln("[GEO] Failed to update GEO database: %s", err.Error())
			}
		}
	}
}

func geoDatabaseModTime() (time.Time, error) {
	for _, database := range []geoDatabase{geoIPDatabase, mmdbDatabase, asnDatabase, geoSiteDatabase} {
		if info, err := os.Stat(database.path()); err == nil {
			return info.ModTime(), nil
		}
	}
	return time.Time{}, errors.New("no geo database on disk")
}

// updateAllDatabases covers what the scheduled update used to: whichever of the
// four files the loaded config says it reads.
func updateAllDatabases() error {
	names := make([]string, 0, 4)
	if geodata.GeoIpEnable() {
		if geodata.GeodataMode() {
			names = append(names, "GEOIP")
		} else {
			names = append(names, "MMDB")
		}
	}
	if geodata.ASNEnable() {
		names = append(names, "ASN")
	}
	if geodata.GeoSiteEnable() {
		names = append(names, "GEOSITE")
	}
	var firstErr error
	for _, name := range names {
		resource, exist := geoResources[name]
		if !exist {
			continue
		}
		// A manual update of the same file already owns it; running both would
		// close and replace the same database twice.
		if !claimGeoUpdate(name) {
			continue
		}
		err := runGeoUpdateForAuto(name, resource)
		releaseGeoUpdate(name)
		if err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func runGeoUpdateForAuto(geoType string, resource geoResource) error {
	onGeoUpdate(geoType, true, false, nil)
	skipped, err := resource.update()
	if err != nil {
		log.Infoln("[GEO] update %s error: %s", geoType, err.Error())
	}
	onGeoUpdate(geoType, false, skipped, err)
	return err
}

func syncGeoUpdater(autoUpdate *bool, interval *int) {
	changed := false
	if autoUpdate != nil && *autoUpdate != updater.GeoAutoUpdate() {
		updater.SetGeoAutoUpdate(*autoUpdate)
		changed = true
	}
	if interval != nil && *interval != updater.GeoUpdateInterval() {
		updater.SetGeoUpdateInterval(*interval)
		changed = true
	}
	if changed {
		reconcileGeoUpdater()
	}
}

func reconcileGeoUpdater() {
	if updater.GeoAutoUpdate() {
		registerGeoUpdater()
		return
	}
	stopGeoUpdater()
}
