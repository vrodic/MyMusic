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
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/text/unicode/norm"
)

//go:embed static
var staticFiles embed.FS

type server struct {
	db         *DB
	root       string
	token      string
	name       string
	smbURL     string
	replica    string // this web player's id among the peers
	backupPath string // latest copy of the Mac's library database (for setting up a new Mac)
	scanning   sync.Mutex
}

func main() {
	musicDir := flag.String("music", envOr("MYMUSIC_ROOT", ""), "music root folder (same tree as the Mac's music root)")
	dbPath := flag.String("db", envOr("MYMUSIC_DB", "mymusic-web.sqlite"), "SQLite database path; keep it on a LOCAL disk, not a network share")
	listen := flag.String("listen", envOr("MYMUSIC_LISTEN", ":47824"), "listen address")
	token := flag.String("token", envOr("MYMUSIC_TOKEN", ""), "shared secret the Mac must send for peer sync (optional)")
	scanEvery := flag.Duration("scan-every", 6*time.Hour, "re-scan the music folder this often (0 = only at start)")
	smbURL := flag.String("smb", envOr("MYMUSIC_SMB_URL", ""), "how Macs reach this music folder over SMB, e.g. smb://192.168.100.7/root/mnt/picko/stuff/mp3 (share + path); used to set up a new Mac")
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
	host = strings.TrimSuffix(host, ".local")
	if err := db.MigrateLegacy("web-" + host); err != nil {
		log.Printf("sync: migrating old stats failed: %v", err)
	}
	s := &server{db: db, root: root, token: *token, name: host, smbURL: *smbURL, backupPath: filepath.Join(filepath.Dir(*dbPath), "mac-library-backup.sqlite"), replica: "web-" + host}

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

	// peer sync (Macs, iPhones through the Macs): see sync.go
	mux.HandleFunc("GET /api/v2/changes", s.peerOnly(s.getChanges))
	mux.HandleFunc("POST /api/v2/changes", s.peerOnly(s.postChanges))
	mux.HandleFunc("GET /api/users", s.users)
	mux.HandleFunc("GET /api/playlists", s.playlists)
	mux.HandleFunc("POST /api/playlists", s.savePlaylist)
	mux.HandleFunc("GET /api/peer/backups", s.peerOnly(s.listBackups))
	mux.HandleFunc("GET /api/peer/backup", s.peerOnly(s.getBackup))
	mux.HandleFunc("POST /api/peer/backup", s.peerOnly(s.putBackup))

	log.Printf("mymusic-web: music %s, database %s, listening on %s", root, *dbPath, *listen)
	go advertise(s, *listen)
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
		"smbURL": s.smbURL, "tokenRequired": s.token != "", "macBackupAt": s.db.Meta("macBackupAt"), "replica": s.replica, "backupCount": len(s.backups()),
		"libraryVersion": s.db.LibraryVersion(),
	})
}

func userParam(r *http.Request) string {
	if u := r.URL.Query().Get("user"); u != "" {
		return u
	}
	return defaultUser
}

func (s *server) tracks(w http.ResponseWriter, r *http.Request) {
	ts, err := s.db.AllTracksFor(userParam(r))
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
// A Mac may ask in its own accent spelling (it indexed the share as NFD; this disk is usually
// NFC), so a song it knows from its own scan can stream from here when the share isn't mounted.
func (s *server) resolve(rel string) (string, bool) {
	clean := path.Clean("/" + rel)[1:]
	if clean == "" || clean != rel || strings.HasPrefix(clean, "../") {
		return "", false
	}
	candidates := []string{rel}
	if !isASCII(rel) {
		candidates = append(candidates, norm.NFC.String(rel), norm.NFD.String(rel))
	}
	for _, p := range candidates {
		if s.db.Has(p) {
			return filepath.Join(s.root, filepath.FromSlash(p)), true
		}
	}
	return "", false
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
	User     string   `json:"user"`
}

func (q pathsReq) user() string {
	if q.User != "" {
		return q.User
	}
	return defaultUser
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
	_ = s.db.SyncRecordPlay(q.user(), q.Path, s.replica, true)
	writeJSON(w, r, map[string]bool{"ok": true})
}

func (s *server) skipped(w http.ResponseWriter, r *http.Request) {
	q, err := readReq(r)
	if err != nil || q.Path == "" {
		http.Error(w, "bad request", 400)
		return
	}
	_ = s.db.SyncRecordPlay(q.user(), q.Path, s.replica, false)
	writeJSON(w, r, map[string]bool{"ok": true})
}

func (s *server) favorite(w http.ResponseWriter, r *http.Request) {
	q, err := readReq(r)
	if err != nil || len(q.Paths) == 0 {
		http.Error(w, "bad request", 400)
		return
	}
	if err := s.db.SyncSetFavorite(q.user(), q.Paths, q.Favorite, s.replica); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, r, map[string]bool{"ok": true})
}

func (s *server) rescan(w http.ResponseWriter, r *http.Request) {
	go s.scan()
	writeJSON(w, r, map[string]bool{"ok": true})
}

// MARK: peer sync, users, playlists

func (s *server) getChanges(w http.ResponseWriter, r *http.Request) {
	since, _ := strconv.Atoi(r.URL.Query().Get("since"))
	cs, err := s.db.Changes(since, r.URL.Query().Get("yt") == "1", s.replica, s.name)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, r, cs)
}

func (s *server) postChanges(w http.ResponseWriter, r *http.Request) {
	var cs ChangeSet
	if err := json.NewDecoder(io.LimitReader(r.Body, 128<<20)).Decode(&cs); err != nil {
		http.Error(w, "bad json: "+err.Error(), 400)
		return
	}
	if cs.Now != nil && cs.Replica != "" && !strings.HasPrefix(cs.Replica, "web-") {
		// Macs keep NTP time; follow their clock so newest-wins comparisons agree
		clockOffset.Store(*cs.Now - float64(time.Now().UnixNano())/1e9)
	}
	n, err := s.db.ApplyChanges(cs)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if n > 0 {
		name := cs.Replica
		if cs.Name != nil {
			name = *cs.Name
		}
		log.Printf("sync: %d changes from %s", n, name)
	}
	writeJSON(w, r, map[string]int{"seq": s.db.CurrentSeq(), "changed": n})
}

func (s *server) users(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, r, s.db.SyncUsers("Me"))
}

func (s *server) playlists(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, r, s.db.Playlists(userParam(r)))
}

func (s *server) savePlaylist(w http.ResponseWriter, r *http.Request) {
	var p PlaylistCell
	if err := json.NewDecoder(io.LimitReader(r.Body, 8<<20)).Decode(&p); err != nil || p.U == "" {
		http.Error(w, "bad request", 400)
		return
	}
	if p.ID == "" {
		p.ID = fmt.Sprintf("web-%d", time.Now().UnixNano())
	}
	p.I = nonNil(p.I)
	p.T, p.B = now(), s.replica
	if err := s.db.SyncSavePlaylist(p); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, r, p)
}

// MARK: duplicates

func (s *server) duplicates(w http.ResponseWriter, r *http.Request) {
	ts, err := s.db.AllTracksFor(userParam(r))
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

// MARK: Mac library backup

// Each Mac uploads a copy of its library database every so often (its own slot, by sync id);
// a new Mac picks one to start from.
type BackupInfo struct {
	Replica string `json:"replica"`
	Name    string `json:"name"`
	At      string `json:"at"`
	Size    int64  `json:"size"`
}

var safeID = regexp.MustCompile(`[^A-Za-z0-9._-]`)

func (s *server) backupFile(replica string) string {
	if replica == "" {
		return s.backupPath // the single slot from before backups had owners
	}
	return filepath.Join(filepath.Dir(s.backupPath), "mac-backup-"+safeID.ReplaceAllString(replica, "_")+".sqlite")
}

func (s *server) backups() []BackupInfo {
	var list []BackupInfo
	_ = json.Unmarshal([]byte(s.db.Meta("backups")), &list)
	out := []BackupInfo{}
	for _, b := range list {
		if st, err := os.Stat(s.backupFile(b.Replica)); err == nil {
			b.Size = st.Size()
			out = append(out, b)
		}
	}
	if st, err := os.Stat(s.backupPath); err == nil && len(out) == 0 {
		out = append(out, BackupInfo{Name: s.db.Meta("macName"), At: st.ModTime().Format(time.RFC3339), Size: st.Size()})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].At > out[j].At })
	return out
}

func (s *server) putBackup(w http.ResponseWriter, r *http.Request) {
	replica, name := r.URL.Query().Get("replica"), r.URL.Query().Get("name")
	dst := s.backupFile(replica)
	tmp := dst + ".upload"
	f, err := os.Create(tmp)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	n, err := io.Copy(f, io.LimitReader(r.Body, 512<<20))
	f.Close()
	if err != nil || n < 4096 {
		os.Remove(tmp)
		http.Error(w, "upload failed", 400)
		return
	}
	if err := os.Rename(tmp, dst); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	at := time.Now().Format(time.RFC3339)
	if replica != "" {
		list := s.backups()
		kept := []BackupInfo{}
		for _, b := range list {
			if b.Replica != replica && b.Replica != "" {
				kept = append(kept, b)
			}
		}
		kept = append(kept, BackupInfo{Replica: replica, Name: name, At: at})
		b, _ := json.Marshal(kept)
		s.db.SetMeta("backups", string(b))
	}
	s.db.SetMeta("macBackupAt", at)
	log.Printf("peer: stored library backup from %q (%d KB)", name, n/1024)
	writeJSON(w, r, map[string]string{"ok": "1", "at": at})
}

func (s *server) listBackups(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, r, s.backups())
}

func (s *server) getBackup(w http.ResponseWriter, r *http.Request) {
	replica := r.URL.Query().Get("replica")
	if replica == "" {
		if list := s.backups(); len(list) > 0 {
			replica = list[0].Replica // newest
		}
	}
	f, err := os.Open(s.backupFile(replica))
	if err != nil {
		http.Error(w, "no backup yet", http.StatusNotFound)
		return
	}
	defer f.Close()
	st, _ := f.Stat()
	w.Header().Set("Content-Type", "application/vnd.sqlite3")
	http.ServeContent(w, r, "library.sqlite", st.ModTime(), f)
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
