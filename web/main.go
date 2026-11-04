// mymusic-web: a peer of the MyMusic Mac app. It runs on the machine that holds the music,
// keeps its own SQLite database on local disk, serves a browser player, and exchanges
// library metadata, play counts and favorites with the Mac whenever the Mac is around.
package main

import (
	"compress/gzip"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/text/unicode/norm"
)

//go:embed static
var staticFiles embed.FS

type server struct {
	db       *DB
	root     string
	token    string
	name     string
	scanning sync.Mutex
}

func main() {
	musicDir := flag.String("music", envOr("MYMUSIC_ROOT", ""), "music root folder (same tree as the Mac's music root)")
	dbPath := flag.String("db", envOr("MYMUSIC_DB", "mymusic-web.sqlite"), "SQLite database path; keep it on a LOCAL disk, not a network share")
	listen := flag.String("listen", envOr("MYMUSIC_LISTEN", ":47824"), "listen address")
	token := flag.String("token", envOr("MYMUSIC_TOKEN", ""), "shared secret the Mac must send for peer sync (optional)")
	scanEvery := flag.Duration("scan-every", 6*time.Hour, "re-scan the music folder this often (0 = only at start)")
	flag.Parse()
	if *musicDir == "" {
		log.Fatal("-music is required (e.g. -music /mnt/picko/stuff/mp3)")
	}
	root, err := filepath.Abs(*musicDir)
	if err != nil {
		log.Fatal(err)
	}
	db, err := OpenDB(*dbPath)
	if err != nil {
		log.Fatal(err)
	}
	if v, err := strconv.ParseFloat(db.Meta("clockOffset"), 64); err == nil {
		clockOffset.Store(v) // last known correction, until the Mac syncs again
	}
	host, _ := os.Hostname()
	s := &server{db: db, root: root, token: *token, name: host}

	go func() {
		for {
			s.scan()
			if *scanEvery <= 0 {
				return
			}
			time.Sleep(*scanEvery)
		}
	}()

	mux := http.NewServeMux()
	static, _ := fs.Sub(staticFiles, "static")
	mux.Handle("GET /", http.FileServer(http.FS(static)))
	mux.HandleFunc("GET /api/info", s.info)
	mux.HandleFunc("GET /api/tracks", s.tracks)
	mux.HandleFunc("GET /api/stream", s.stream)
	mux.HandleFunc("GET /api/art", s.art)
	mux.HandleFunc("POST /api/played", s.played)
	mux.HandleFunc("POST /api/skipped", s.skipped)
	mux.HandleFunc("POST /api/favorite", s.favorite)
	mux.HandleFunc("POST /api/rescan", s.rescan)
	mux.HandleFunc("GET /api/duplicates", s.duplicates)
	mux.HandleFunc("POST /api/duplicates/remove", s.removeDuplicatesHandler)
	// peer sync with the Mac app
	mux.HandleFunc("GET /api/peer/stats", s.peerOnly(s.peerStats))
	mux.HandleFunc("POST /api/peer/library", s.peerOnly(s.peerLibrary))
	mux.HandleFunc("GET /api/peer/removals", s.peerOnly(s.peerRemovals))
	mux.HandleFunc("POST /api/peer/removals/ack", s.peerOnly(s.peerAckRemovals))

	log.Printf("mymusic-web: music %s, database %s, listening on %s", root, *dbPath, *listen)
	log.Fatal(http.ListenAndServe(*listen, logRequests(mux)))
}

func (s *server) scan() {
	if !s.scanning.TryLock() {
		return
	}
	defer s.scanning.Unlock()
	if _, _, err := Scan(s.db, s.root); err != nil {
		log.Printf("scan failed: %v", err)
	}
	s.db.SetMeta("lastScan", time.Now().Format(time.RFC3339))
}

// MARK: browser API

func (s *server) info(w http.ResponseWriter, r *http.Request) {
	ts, _ := s.db.AllTracks()
	writeJSON(w, r, map[string]any{
		"name": s.name, "trackCount": len(ts),
		"lastMacSync": s.db.Meta("lastMacSync"), "macName": s.db.Meta("macName"), "lastScan": s.db.Meta("lastScan"),
	})
}

func (s *server) tracks(w http.ResponseWriter, r *http.Request) {
	ts, err := s.db.AllTracks()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if ts == nil {
		ts = []WebTrack{}
	}
	writeJSON(w, r, ts)
}

// resolve maps a relPath from the client to a file, refusing anything outside the library.
func (s *server) resolve(rel string) (string, bool) {
	clean := path.Clean("/" + rel)[1:]
	if clean == "" || clean != rel || strings.HasPrefix(clean, "../") || !s.db.Has(rel) {
		return "", false
	}
	return filepath.Join(s.root, filepath.FromSlash(clean)), true
}

func (s *server) stream(w http.ResponseWriter, r *http.Request) {
	p, ok := s.resolve(r.URL.Query().Get("path"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	f, err := os.Open(p)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", mime(p))
	http.ServeContent(w, r, filepath.Base(p), st.ModTime(), f) // handles Range for seeking
}

func (s *server) art(w http.ResponseWriter, r *http.Request) {
	p, ok := s.resolve(r.URL.Query().Get("path"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	data, typ := Artwork(p)
	if data == nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", typ)
	w.Header().Set("Cache-Control", "public, max-age=604800")
	w.Write(data)
}

type pathsReq struct {
	Path     string   `json:"path"`
	Paths    []string `json:"paths"`
	Favorite bool     `json:"favorite"`
}

func readReq(r *http.Request) (pathsReq, error) {
	var q pathsReq
	err := json.NewDecoder(io.LimitReader(r.Body, 8<<20)).Decode(&q)
	if q.Path != "" {
		q.Paths = append(q.Paths, q.Path)
	}
	return q, err
}

func (s *server) played(w http.ResponseWriter, r *http.Request) {
	q, err := readReq(r)
	if err != nil || q.Path == "" {
		http.Error(w, "bad request", 400)
		return
	}
	_ = s.db.RecordPlay(q.Path)
	writeJSON(w, r, map[string]bool{"ok": true})
}

func (s *server) skipped(w http.ResponseWriter, r *http.Request) {
	q, err := readReq(r)
	if err != nil || q.Path == "" {
		http.Error(w, "bad request", 400)
		return
	}
	_ = s.db.RecordSkip(q.Path)
	writeJSON(w, r, map[string]bool{"ok": true})
}

func (s *server) favorite(w http.ResponseWriter, r *http.Request) {
	q, err := readReq(r)
	if err != nil || len(q.Paths) == 0 {
		http.Error(w, "bad request", 400)
		return
	}
	if err := s.db.SetFavorite(q.Paths, q.Favorite); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, r, map[string]bool{"ok": true})
}

func (s *server) rescan(w http.ResponseWriter, r *http.Request) {
	go s.scan()
	writeJSON(w, r, map[string]bool{"ok": true})
}

// MARK: duplicates

func (s *server) duplicates(w http.ResponseWriter, r *http.Request) {
	ts, err := s.db.AllTracks()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	start := time.Now()
	groups := FindDuplicates(ts, s.root)
	if groups == nil {
		groups = []DupGroup{}
	}
	log.Printf("duplicates: %d groups among %d tracks in %s", len(groups), len(ts), time.Since(start).Round(time.Millisecond))
	writeJSON(w, r, groups)
}

func (s *server) removeDuplicatesHandler(w http.ResponseWriter, r *http.Request) {
	var plans []RemovePlan
	if err := json.NewDecoder(io.LimitReader(r.Body, 8<<20)).Decode(&plans); err != nil {
		http.Error(w, "bad request", 400)
		return
	}
	removed, failed := s.removeDuplicates(plans)
	log.Printf("duplicates: removed %d, %d failed", removed, len(failed))
	if failed == nil {
		failed = []string{}
	}
	writeJSON(w, r, map[string]any{"removed": removed, "failed": failed})
}

// MARK: peer API (Mac app)

// The Mac pulls duplicates removed here (before pushing its library, so it doesn't re-add them).
func (s *server) peerRemovals(w http.ResponseWriter, r *http.Request) {
	list, err := s.db.PendingRemovals()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, r, list)
}

func (s *server) peerAckRemovals(w http.ResponseWriter, r *http.Request) {
	var q struct {
		IDs []int64 `json:"ids"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&q); err != nil {
		http.Error(w, "bad request", 400)
		return
	}
	if err := s.db.AckRemovals(q.IDs); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, r, map[string]bool{"ok": true})
}

func (s *server) peerOnly(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.token != "" && subtle.ConstantTimeCompare([]byte(r.Header.Get("X-MyMusic-Token")), []byte(s.token)) != 1 {
			http.Error(w, "bad token", http.StatusUnauthorized)
			return
		}
		h(w, r)
	}
}

// The Mac pulls our plays and favorite changes and stores them like an iPhone's stats.
func (s *server) peerStats(w http.ResponseWriter, r *http.Request) {
	entries, err := s.db.WebStats()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, r, StatsUpload{DeviceID: "web-" + s.name, DeviceName: "Web player (" + s.name + ")", Entries: entries})
}

// The Mac pushes its full library (with Mac-side play counts and merged favorites).
func (s *server) peerLibrary(w http.ResponseWriter, r *http.Request) {
	var body io.Reader = io.LimitReader(r.Body, 256<<20)
	if r.Header.Get("Content-Encoding") == "gzip" {
		gz, err := gzip.NewReader(body)
		if err != nil {
			http.Error(w, "bad gzip", 400)
			return
		}
		defer gz.Close()
		body = gz
	}
	var m LibraryManifest
	if err := json.NewDecoder(body).Decode(&m); err != nil {
		http.Error(w, "bad json: "+err.Error(), 400)
		return
	}
	if m.GeneratedAt > 0 {
		// GeneratedAt was stamped just before sending; network latency is negligible next to clock drift.
		off := m.GeneratedAt - float64(time.Now().UnixNano())/1e9
		clockOffset.Store(off)
		s.db.SetMeta("clockOffset", fmt.Sprintf("%.3f", off))
		if off > 5 || off < -5 {
			log.Printf("peer: this server's clock is %.0f s off the Mac's; correcting timestamps (enable NTP to fix)", -off)
		}
	}
	added, removed, favs, err := s.db.ApplyMacLibrary(m, s.diskPath)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.db.SetMeta("lastMacSync", time.Now().Format(time.RFC3339))
	s.db.SetMeta("macName", m.ServerName)
	log.Printf("peer: library from %q: %d tracks, %d added, %d removed, %d favorites changed", m.ServerName, len(m.Tracks), added, removed, favs)
	writeJSON(w, r, map[string]int{"tracks": len(m.Tracks), "added": added, "removed": removed, "favoritesChanged": favs})
}

// diskPath finds the spelling of relPath that exists on this disk. macOS sends accented names
// decomposed (NFD) while Linux usually stores them composed (NFC); both are the same file.
func (s *server) diskPath(rel string) string {
	exists := func(p string) bool { _, err := os.Stat(filepath.Join(s.root, filepath.FromSlash(p))); return err == nil }
	if isASCII(rel) || exists(rel) {
		return rel
	}
	for _, p := range []string{norm.NFC.String(rel), norm.NFD.String(rel)} {
		if p != rel && exists(p) {
			return p
		}
	}
	return norm.NFC.String(rel)
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

// MARK: helpers

func writeJSON(w http.ResponseWriter, r *http.Request, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		w.Header().Set("Content-Encoding", "gzip")
		gz := gzip.NewWriter(w)
		defer gz.Close()
		_ = json.NewEncoder(gz).Encode(v)
		return
	}
	_ = json.NewEncoder(w).Encode(v)
}

func mime(p string) string {
	switch strings.ToLower(filepath.Ext(p)) {
	case ".mp3":
		return "audio/mpeg"
	case ".m4a", ".m4b", ".mp4", ".aac", ".alac":
		return "audio/mp4"
	case ".flac":
		return "audio/flac"
	case ".wav":
		return "audio/wav"
	case ".aif", ".aiff":
		return "audio/aiff"
	}
	return "application/octet-stream"
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func logRequests(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/peer/") || r.URL.Path == "/api/rescan" {
			log.Printf("%s %s from %s", r.Method, r.URL.Path, r.RemoteAddr)
		}
		h.ServeHTTP(w, r)
	})
}
