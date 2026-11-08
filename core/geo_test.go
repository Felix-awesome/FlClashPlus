package core

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

func geoServer(t *testing.T, body string, status int) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)
	return server
}

func geoDatabaseFor(server *httptest.Server, path string) geoDatabase {
	return geoDatabase{
		url:  func() string { return server.URL + "/database" },
		path: func() string { return path },
		verify: func(file string) error {
			if _, err := os.ReadFile(file); err != nil {
				return err
			}
			return nil
		},
		reload: func() {},
	}
}

func TestInstallDatabaseReplacesTheFileWithTheStoredCopy(t *testing.T) {
	server := geoServer(t, "fresh database", http.StatusOK)
	path := filepath.Join(t.TempDir(), "GEOIP.metadb")
	if err := os.WriteFile(path, []byte("stale database"), 0o644); err != nil {
		t.Fatal(err)
	}
	var reloads atomic.Int32
	database := geoDatabaseFor(server, path)
	database.reload = func() { reloads.Add(1) }

	skipped, err := installDatabase(database)
	if err != nil {
		t.Fatalf("installDatabase = %v, want no error", err)
	}
	if skipped {
		t.Error("a database that changed was reported as skipped")
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != "fresh database" {
		t.Errorf("stored %q, want the downloaded copy", contents)
	}
	if reloads.Load() != 1 {
		t.Errorf("reloaded %d times, want once", reloads.Load())
	}
	if _, err := os.Stat(path + geoDownloadTemp); !os.IsNotExist(err) {
		t.Error("the temporary copy was left next to the database")
	}
}

func TestInstallDatabaseSkipsAnUnchangedDatabase(t *testing.T) {
	server := geoServer(t, "same database", http.StatusOK)
	path := filepath.Join(t.TempDir(), "GEOIP.metadb")
	if err := os.WriteFile(path, []byte("same database"), 0o644); err != nil {
		t.Fatal(err)
	}
	var reloads atomic.Int32
	database := geoDatabaseFor(server, path)
	database.reload = func() { reloads.Add(1) }

	skipped, err := installDatabase(database)
	if err != nil {
		t.Fatalf("installDatabase = %v, want no error", err)
	}
	if !skipped {
		t.Error("an identical database was reported as updated")
	}
	if reloads.Load() != 0 {
		t.Error("the file was reloaded although its contents did not change")
	}
}

func TestInstallDatabaseKeepsTheOldFileWhenVerificationFails(t *testing.T) {
	server := geoServer(t, "not a database", http.StatusOK)
	path := filepath.Join(t.TempDir(), "GEOIP.metadb")
	if err := os.WriteFile(path, []byte("stale database"), 0o644); err != nil {
		t.Fatal(err)
	}
	var reloads atomic.Int32
	database := geoDatabaseFor(server, path)
	database.verify = func(string) error { return errors.New("unreadable") }
	database.reload = func() { reloads.Add(1) }

	if _, err := installDatabase(database); err == nil {
		t.Fatal("a database that failed validation was installed")
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != "stale database" {
		t.Errorf("the rejected download replaced the working database with %q", contents)
	}
	if reloads.Load() != 0 {
		t.Error("a rejected download was reloaded")
	}
	if _, err := os.Stat(path + geoDownloadTemp); !os.IsNotExist(err) {
		t.Error("the rejected temporary copy was left behind")
	}
}

func TestInstallDatabaseRejectsAFailedResponse(t *testing.T) {
	server := geoServer(t, "gone", http.StatusNotFound)
	path := filepath.Join(t.TempDir(), "GEOIP.metadb")

	if _, err := installDatabase(geoDatabaseFor(server, path)); err == nil {
		t.Fatal("a 404 response was installed as a database")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("a failed download created the database anyway")
	}
}

func TestDownloadDatabaseRejectsAnEmptyLink(t *testing.T) {
	if _, err := downloadDatabase(""); err == nil {
		t.Fatal("an empty link was requested instead of rejected")
	}
}
