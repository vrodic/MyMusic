package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/text/unicode/norm"
)

// A Mac streams with the path spelling from its own index, which for accented names can differ
// from the spelling on this disk. Seeking relies on Range requests.
func TestStreamAcceptsEitherAccentSpelling(t *testing.T) {
	dir := t.TempDir()
	db, err := OpenDB(filepath.Join(t.TempDir(), "test.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	composed := norm.NFC.String("Šuma/Čaj.mp3")
	if err := os.MkdirAll(filepath.Join(dir, "Šuma"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, filepath.FromSlash(composed)), []byte("0123456789"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := db.UpsertScanned([]Track{{RelPath: composed, Size: 10, Mtime: 1, Title: "Čaj", Source: "local", AddedAt: 1}}); err != nil {
		t.Fatal(err)
	}
	s := &server{db: db, root: dir}

	get := func(rel, rng string) *http.Response {
		r := httptest.NewRequest("GET", "/api/stream?path="+url.QueryEscape(rel), nil)
		if rng != "" {
			r.Header.Set("Range", rng)
		}
		w := httptest.NewRecorder()
		s.stream(w, r)
		return w.Result()
	}

	for name, rel := range map[string]string{"composed": composed, "decomposed": norm.NFD.String(composed)} {
		res := get(rel, "bytes=2-5")
		if res.StatusCode != http.StatusPartialContent {
			t.Fatalf("%s: status %d, want 206", name, res.StatusCode)
		}
		if b, _ := io.ReadAll(res.Body); string(b) != "2345" {
			t.Fatalf("%s: body %q, want 2345", name, b)
		}
	}

	for _, rel := range []string{"", "../secret.mp3", "Šuma/../../secret.mp3", "Šuma/Unknown.mp3"} {
		if res := get(rel, ""); res.StatusCode != http.StatusNotFound {
			t.Fatalf("%q: status %d, want 404", rel, res.StatusCode)
		}
	}
}

func TestLibraryVersionOnlyFollowsTheSongs(t *testing.T) {
	db, err := OpenDB(filepath.Join(t.TempDir(), "test.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	song := Track{RelPath: "a.mp3", Size: 10, Mtime: 1, Title: "A", Source: "local", AddedAt: 1}
	if err := db.UpsertScanned([]Track{song}); err != nil {
		t.Fatal(err)
	}
	v := db.LibraryVersion()
	db.SetMeta("lastMacSync", "now")
	db.SetMeta("lastScan", "now")
	if got := db.LibraryVersion(); got != v {
		t.Fatalf("sync timestamps changed the version: %s -> %s", v, got)
	}
	song.Size = 11
	if err := db.UpsertScanned([]Track{song}); err != nil {
		t.Fatal(err)
	}
	if got := db.LibraryVersion(); got == v {
		t.Fatal("a changed file didn't change the version")
	}
}
