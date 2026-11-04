package main

// Peer-to-peer replicated state, the same model and merge rules as the apps (Shared/SyncStore.swift):
// per-user play-count cells per device (max per cell, sum for totals), newest-wins favorites /
// users / playlists / settings, duplicate aliases, and the Macs' YouTube queue (relayed here so Macs
// that are never on at the same time still agree). The web player is one peer among the others.

import (
	"database/sql"
	"encoding/json"
	"strconv"
	"strings"

	"golang.org/x/text/unicode/norm"
)

const syncSchema = `
CREATE TABLE IF NOT EXISTS sync_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sync_users (user_id TEXT PRIMARY KEY, name TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, ts REAL NOT NULL, by TEXT NOT NULL, seq INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sync_plays (user_id TEXT NOT NULL, track_key TEXT NOT NULL, replica TEXT NOT NULL, plays INTEGER NOT NULL DEFAULT 0, skips INTEGER NOT NULL DEFAULT 0, last_played REAL, seq INTEGER NOT NULL, PRIMARY KEY (user_id, track_key, replica));
CREATE TABLE IF NOT EXISTS sync_favorites (user_id TEXT NOT NULL, track_key TEXT NOT NULL, favorite INTEGER NOT NULL, ts REAL NOT NULL, by TEXT NOT NULL, seq INTEGER NOT NULL, PRIMARY KEY (user_id, track_key));
CREATE TABLE IF NOT EXISTS sync_aliases (old_key TEXT PRIMARY KEY, keep_key TEXT NOT NULL, ts REAL NOT NULL, by TEXT NOT NULL, seq INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sync_playlists (playlist_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, name TEXT NOT NULL, items TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, ts REAL NOT NULL, by TEXT NOT NULL, seq INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sync_settings (user_id TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, ts REAL NOT NULL, by TEXT NOT NULL, seq INTEGER NOT NULL, PRIMARY KEY (user_id, key));
CREATE TABLE IF NOT EXISTS sync_yt (video_id TEXT PRIMARY KEY, doc TEXT NOT NULL, user_ts REAL NOT NULL, dl_ts REAL NOT NULL, done INTEGER NOT NULL DEFAULT 0, seq INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sync_claims (video_id TEXT PRIMARY KEY, replica TEXT NOT NULL, until REAL NOT NULL, ts REAL NOT NULL, seq INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS sync_plays_seq ON sync_plays(seq);
`

const defaultUser = "default"

type PlayCell struct {
	U string   `json:"u"`
	K string   `json:"k"`
	R string   `json:"r"`
	P int      `json:"p"`
	S int      `json:"s"`
	L *float64 `json:"l,omitempty"`
}
type FavCell struct {
	U string  `json:"u"`
	K string  `json:"k"`
	F bool    `json:"f"`
	T float64 `json:"t"`
	B string  `json:"b"`
}
type AliasCell struct {
	O string  `json:"o"`
	K string  `json:"k"`
	T float64 `json:"t"`
	B string  `json:"b"`
}
type UserCell struct {
	ID string  `json:"id"`
	N  string  `json:"n"`
	D  bool    `json:"d"`
	T  float64 `json:"t"`
	B  string  `json:"b"`
}
type PlaylistCell struct {
	ID string   `json:"id"`
	U  string   `json:"u"`
	N  string   `json:"n"`
	I  []string `json:"i"`
	D  bool     `json:"d"`
	T  float64  `json:"t"`
	B  string   `json:"b"`
}
type SettingCell struct {
	U string  `json:"u"`
	K string  `json:"k"`
	V string  `json:"v"`
	T float64 `json:"t"`
	B string  `json:"b"`
}
type YTCell struct {
	ID   string  `json:"id"`
	Doc  string  `json:"doc"`
	UT   float64 `json:"ut"`
	DT   float64 `json:"dt"`
	Done bool    `json:"done"`
}
type ClaimCell struct {
	ID    string  `json:"id"`
	R     string  `json:"r"`
	Until float64 `json:"until"`
	T     float64 `json:"t"`
}

type ChangeSet struct {
	Replica   string         `json:"replica"`
	Name      *string        `json:"name,omitempty"`
	Seq       int            `json:"seq"`
	Now       *float64       `json:"now,omitempty"`
	Plays     []PlayCell     `json:"plays"`
	Favorites []FavCell      `json:"favorites"`
	Aliases   []AliasCell    `json:"aliases"`
	Users     []UserCell     `json:"users"`
	Playlists []PlaylistCell `json:"playlists"`
	Settings  []SettingCell  `json:"settings"`
	YT        []YTCell       `json:"yt"`
	Claims    []ClaimCell    `json:"claims"`
}

func trackKey(relPath string) string { return norm.NFC.String(relPath) }

// MARK: sequence

func (db *DB) syncMeta(q interface {
	QueryRow(string, ...any) *sql.Row
}, k string) string {
	var v string
	_ = q.QueryRow("SELECT value FROM sync_meta WHERE key = ?", k).Scan(&v)
	return v
}

func (db *DB) CurrentSeq() int {
	n, _ := strconv.Atoi(db.syncMeta(db.sql, "seq"))
	return n
}

func nextSeq(tx *sql.Tx) (int, error) {
	var v string
	_ = tx.QueryRow("SELECT value FROM sync_meta WHERE key = 'seq'").Scan(&v)
	n, _ := strconv.Atoi(v)
	n++
	_, err := tx.Exec("INSERT INTO sync_meta (key, value) VALUES ('seq', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", strconv.Itoa(n))
	return n, err
}

func newer(t float64, b string, t2 float64, b2 string) bool {
	if t != t2 {
		return t > t2
	}
	return b > b2
}

// MARK: merge (same rules as SyncStore)

func mergePlay(tx *sql.Tx, c PlayCell) (bool, error) {
	var p, s int
	var l sql.NullFloat64
	err := tx.QueryRow("SELECT plays, skips, last_played FROM sync_plays WHERE user_id = ? AND track_key = ? AND replica = ?", c.U, c.K, c.R).Scan(&p, &s, &l)
	exists := err == nil
	np, ns, nl := max(p, c.P), max(s, c.S), l.Float64
	if c.L != nil && *c.L > nl {
		nl = *c.L
	}
	if exists && np == p && ns == s && nl == l.Float64 {
		return false, nil
	}
	seq, err := nextSeq(tx)
	if err != nil {
		return false, err
	}
	var lp any
	if nl > 0 {
		lp = nl
	}
	_, err = tx.Exec(`INSERT INTO sync_plays VALUES (?,?,?,?,?,?,?) ON CONFLICT(user_id, track_key, replica) DO UPDATE SET plays = excluded.plays, skips = excluded.skips, last_played = excluded.last_played, seq = excluded.seq`,
		c.U, c.K, c.R, np, ns, lp, seq)
	return err == nil, err
}

func lwwOK(tx *sql.Tx, query string, args []any, t float64, b string) bool {
	var ct float64
	var cb string
	if err := tx.QueryRow(query, args...).Scan(&ct, &cb); err != nil {
		return true // no row yet
	}
	return newer(t, b, ct, cb)
}

func mergeFavorite(tx *sql.Tx, c FavCell) (bool, error) {
	if !lwwOK(tx, "SELECT ts, by FROM sync_favorites WHERE user_id = ? AND track_key = ?", []any{c.U, c.K}, c.T, c.B) {
		return false, nil
	}
	seq, err := nextSeq(tx)
	if err != nil {
		return false, err
	}
	_, err = tx.Exec(`INSERT INTO sync_favorites VALUES (?,?,?,?,?,?) ON CONFLICT(user_id, track_key) DO UPDATE SET favorite = excluded.favorite, ts = excluded.ts, by = excluded.by, seq = excluded.seq`,
		c.U, c.K, c.F, c.T, c.B, seq)
	return err == nil, err
}

func mergeAlias(tx *sql.Tx, c AliasCell) (bool, error) {
	if c.O == c.K {
		return false, nil
	}
	var keep string
	var ct float64
	var cb string
	if err := tx.QueryRow("SELECT keep_key, ts, by FROM sync_aliases WHERE old_key = ?", c.O).Scan(&keep, &ct, &cb); err == nil {
		if keep == c.K || !newer(c.T, c.B, ct, cb) {
			return false, nil
		}
	}
	seq, err := nextSeq(tx)
	if err != nil {
		return false, err
	}
	_, err = tx.Exec(`INSERT INTO sync_aliases VALUES (?,?,?,?,?) ON CONFLICT(old_key) DO UPDATE SET keep_key = excluded.keep_key, ts = excluded.ts, by = excluded.by, seq = excluded.seq`,
		c.O, c.K, c.T, c.B, seq)
	return err == nil, err
}

func mergeUser(tx *sql.Tx, c UserCell) (bool, error) {
	if !lwwOK(tx, "SELECT ts, by FROM sync_users WHERE user_id = ?", []any{c.ID}, c.T, c.B) {
		return false, nil
	}
	seq, err := nextSeq(tx)
	if err != nil {
		return false, err
	}
	_, err = tx.Exec(`INSERT INTO sync_users VALUES (?,?,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET name = excluded.name, deleted = excluded.deleted, ts = excluded.ts, by = excluded.by, seq = excluded.seq`,
		c.ID, c.N, c.D, c.T, c.B, seq)
	return err == nil, err
}

func mergePlaylist(tx *sql.Tx, c PlaylistCell) (bool, error) {
	if !lwwOK(tx, "SELECT ts, by FROM sync_playlists WHERE playlist_id = ?", []any{c.ID}, c.T, c.B) {
		return false, nil
	}
	seq, err := nextSeq(tx)
	if err != nil {
		return false, err
	}
	items, _ := json.Marshal(nonNil(c.I))
	_, err = tx.Exec(`INSERT INTO sync_playlists VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(playlist_id) DO UPDATE SET user_id = excluded.user_id, name = excluded.name, items = excluded.items, deleted = excluded.deleted, ts = excluded.ts, by = excluded.by, seq = excluded.seq`,
		c.ID, c.U, c.N, string(items), c.D, c.T, c.B, seq)
	return err == nil, err
}

func mergeSetting(tx *sql.Tx, c SettingCell) (bool, error) {
	if !lwwOK(tx, "SELECT ts, by FROM sync_settings WHERE user_id = ? AND key = ?", []any{c.U, c.K}, c.T, c.B) {
		return false, nil
	}
	seq, err := nextSeq(tx)
	if err != nil {
		return false, err
	}
	_, err = tx.Exec(`INSERT INTO sync_settings VALUES (?,?,?,?,?,?) ON CONFLICT(user_id, key) DO UPDATE SET value = excluded.value, ts = excluded.ts, by = excluded.by, seq = excluded.seq`,
		c.U, c.K, c.V, c.T, c.B, seq)
	return err == nil, err
}

var (
	ytInfo     = []string{"title", "uploader", "duration", "playlistIndex", "inPlaylist", "addedAt"}
	ytUser     = []string{"priority", "favorite", "matchOverride"}
	ytDownload = []string{"status", "relPath", "error", "attempts"}
)

func mergeYT(tx *sql.Tx, c YTCell) (bool, error) {
	var doc string
	var ut, dt float64
	var done bool
	err := tx.QueryRow("SELECT doc, user_ts, dl_ts, done FROM sync_yt WHERE video_id = ?", c.ID).Scan(&doc, &ut, &dt, &done)
	seq := 0
	if err != nil {
		if seq, err = nextSeq(tx); err != nil {
			return false, err
		}
		_, err = tx.Exec("INSERT INTO sync_yt VALUES (?,?,?,?,?,?)", c.ID, c.Doc, c.UT, c.DT, c.Done, seq)
		return err == nil, err
	}
	mine, theirs := map[string]any{}, map[string]any{}
	_ = json.Unmarshal([]byte(doc), &mine)
	_ = json.Unmarshal([]byte(c.Doc), &theirs)
	changed := false
	if c.UT > ut {
		for _, k := range ytUser {
			mine[k] = theirs[k]
		}
		changed = true
	}
	takeDL := (c.Done && !done) || (c.Done == done && c.DT > dt)
	if takeDL {
		for _, k := range ytDownload {
			mine[k] = theirs[k]
		}
		changed = true
	}
	for _, k := range ytInfo {
		if _, have := mine[k]; !have {
			if v, ok := theirs[k]; ok {
				mine[k] = v
				changed = true
			}
		}
	}
	if !changed {
		return false, nil
	}
	if seq, err = nextSeq(tx); err != nil {
		return false, err
	}
	b, _ := json.Marshal(mine)
	newDT := dt
	if takeDL {
		newDT = c.DT
	}
	_, err = tx.Exec("UPDATE sync_yt SET doc = ?, user_ts = ?, dl_ts = ?, done = ?, seq = ? WHERE video_id = ?",
		string(b), max(ut, c.UT), newDT, done || c.Done, seq, c.ID)
	return err == nil, err
}

func mergeClaim(tx *sql.Tx, c ClaimCell) (bool, error) {
	if !lwwOK(tx, "SELECT ts, replica FROM sync_claims WHERE video_id = ?", []any{c.ID}, c.T, c.R) {
		return false, nil
	}
	seq, err := nextSeq(tx)
	if err != nil {
		return false, err
	}
	_, err = tx.Exec(`INSERT INTO sync_claims VALUES (?,?,?,?,?) ON CONFLICT(video_id) DO UPDATE SET replica = excluded.replica, until = excluded.until, ts = excluded.ts, seq = excluded.seq`,
		c.ID, c.R, c.Until, c.T, seq)
	return err == nil, err
}

// ApplyChanges merges a peer's change set; returns how many rows changed here.
func (db *DB) ApplyChanges(cs ChangeSet) (int, error) {
	db.mu.Lock()
	defer db.mu.Unlock()
	tx, err := db.sql.Begin()
	if err != nil {
		return 0, err
	}
	n := 0
	try := func(ok bool, err error) error {
		if ok {
			n++
		}
		return err
	}
	for _, c := range cs.Plays {
		if err := try(mergePlay(tx, c)); err != nil {
			tx.Rollback()
			return 0, err
		}
	}
	for _, c := range cs.Favorites {
		if err := try(mergeFavorite(tx, c)); err != nil {
			tx.Rollback()
			return 0, err
		}
	}
	for _, c := range cs.Aliases {
		if err := try(mergeAlias(tx, c)); err != nil {
			tx.Rollback()
			return 0, err
		}
	}
	for _, c := range cs.Users {
		if err := try(mergeUser(tx, c)); err != nil {
			tx.Rollback()
			return 0, err
		}
	}
	for _, c := range cs.Playlists {
		if err := try(mergePlaylist(tx, c)); err != nil {
			tx.Rollback()
			return 0, err
		}
	}
	for _, c := range cs.Settings {
		if err := try(mergeSetting(tx, c)); err != nil {
			tx.Rollback()
			return 0, err
		}
	}
	for _, c := range cs.YT {
		if err := try(mergeYT(tx, c)); err != nil {
			tx.Rollback()
			return 0, err
		}
	}
	for _, c := range cs.Claims {
		if err := try(mergeClaim(tx, c)); err != nil {
			tx.Rollback()
			return 0, err
		}
	}
	return n, tx.Commit()
}

// Changes returns everything written or learned here after `since` (our sequence numbers).
func (db *DB) Changes(since int, includeYT bool, replica, name string) (ChangeSet, error) {
	t := now()
	cs := ChangeSet{Replica: replica, Name: &name, Seq: db.CurrentSeq(), Now: &t,
		Plays: []PlayCell{}, Favorites: []FavCell{}, Aliases: []AliasCell{}, Users: []UserCell{},
		Playlists: []PlaylistCell{}, Settings: []SettingCell{}, YT: []YTCell{}, Claims: []ClaimCell{}}
	q := func(sqlText string, scan func(*sql.Rows) error) error {
		rows, err := db.sql.Query(sqlText, since)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			if err := scan(rows); err != nil {
				return err
			}
		}
		return rows.Err()
	}
	if err := q("SELECT user_id, track_key, replica, plays, skips, last_played FROM sync_plays WHERE seq > ?", func(r *sql.Rows) error {
		var c PlayCell
		var l sql.NullFloat64
		if err := r.Scan(&c.U, &c.K, &c.R, &c.P, &c.S, &l); err != nil {
			return err
		}
		if l.Valid {
			c.L = &l.Float64
		}
		cs.Plays = append(cs.Plays, c)
		return nil
	}); err != nil {
		return cs, err
	}
	if err := q("SELECT user_id, track_key, favorite, ts, by FROM sync_favorites WHERE seq > ?", func(r *sql.Rows) error {
		var c FavCell
		if err := r.Scan(&c.U, &c.K, &c.F, &c.T, &c.B); err != nil {
			return err
		}
		cs.Favorites = append(cs.Favorites, c)
		return nil
	}); err != nil {
		return cs, err
	}
	if err := q("SELECT old_key, keep_key, ts, by FROM sync_aliases WHERE seq > ?", func(r *sql.Rows) error {
		var c AliasCell
		if err := r.Scan(&c.O, &c.K, &c.T, &c.B); err != nil {
			return err
		}
		cs.Aliases = append(cs.Aliases, c)
		return nil
	}); err != nil {
		return cs, err
	}
	if err := q("SELECT user_id, name, deleted, ts, by FROM sync_users WHERE seq > ?", func(r *sql.Rows) error {
		var c UserCell
		if err := r.Scan(&c.ID, &c.N, &c.D, &c.T, &c.B); err != nil {
			return err
		}
		cs.Users = append(cs.Users, c)
		return nil
	}); err != nil {
		return cs, err
	}
	if err := q("SELECT playlist_id, user_id, name, items, deleted, ts, by FROM sync_playlists WHERE seq > ?", func(r *sql.Rows) error {
		var c PlaylistCell
		var items string
		if err := r.Scan(&c.ID, &c.U, &c.N, &items, &c.D, &c.T, &c.B); err != nil {
			return err
		}
		_ = json.Unmarshal([]byte(items), &c.I)
		c.I = nonNil(c.I)
		cs.Playlists = append(cs.Playlists, c)
		return nil
	}); err != nil {
		return cs, err
	}
	if err := q("SELECT user_id, key, value, ts, by FROM sync_settings WHERE seq > ?", func(r *sql.Rows) error {
		var c SettingCell
		if err := r.Scan(&c.U, &c.K, &c.V, &c.T, &c.B); err != nil {
			return err
		}
		cs.Settings = append(cs.Settings, c)
		return nil
	}); err != nil {
		return cs, err
	}
	if includeYT {
		if err := q("SELECT video_id, doc, user_ts, dl_ts, done FROM sync_yt WHERE seq > ?", func(r *sql.Rows) error {
			var c YTCell
			if err := r.Scan(&c.ID, &c.Doc, &c.UT, &c.DT, &c.Done); err != nil {
				return err
			}
			cs.YT = append(cs.YT, c)
			return nil
		}); err != nil {
			return cs, err
		}
		if err := q("SELECT video_id, replica, until, ts FROM sync_claims WHERE seq > ?", func(r *sql.Rows) error {
			var c ClaimCell
			if err := r.Scan(&c.ID, &c.R, &c.Until, &c.T); err != nil {
				return err
			}
			cs.Claims = append(cs.Claims, c)
			return nil
		}); err != nil {
			return cs, err
		}
	}
	return cs, nil
}

// MARK: local writes from the web player

func (db *DB) localWrite(f func(tx *sql.Tx) error) error {
	db.mu.Lock()
	defer db.mu.Unlock()
	tx, err := db.sql.Begin()
	if err != nil {
		return err
	}
	if err := f(tx); err != nil {
		tx.Rollback()
		return err
	}
	return tx.Commit()
}

func (db *DB) SyncRecordPlay(user, relPath, replica string, play bool) error {
	return db.localWrite(func(tx *sql.Tx) error {
		k := trackKey(relPath)
		var p, s int
		var l sql.NullFloat64
		_ = tx.QueryRow("SELECT plays, skips, last_played FROM sync_plays WHERE user_id = ? AND track_key = ? AND replica = ?", user, k, replica).Scan(&p, &s, &l)
		c := PlayCell{U: user, K: k, R: replica, P: p, S: s}
		if l.Valid {
			c.L = &l.Float64
		}
		if play {
			c.P++
			t := now()
			c.L = &t
		} else {
			c.S++
		}
		_, err := mergePlay(tx, c)
		return err
	})
}

func (db *DB) SyncSetFavorite(user string, paths []string, fav bool, replica string) error {
	return db.localWrite(func(tx *sql.Tx) error {
		t := now()
		for _, p := range paths {
			if _, err := mergeFavorite(tx, FavCell{U: user, K: trackKey(p), F: fav, T: t, B: replica}); err != nil {
				return err
			}
		}
		return nil
	})
}

func (db *DB) SyncAddAlias(old, keep, replica string) error {
	return db.localWrite(func(tx *sql.Tx) error {
		_, err := mergeAlias(tx, AliasCell{O: trackKey(old), K: trackKey(keep), T: now(), B: replica})
		return err
	})
}

func (db *DB) SyncSavePlaylist(p PlaylistCell) error {
	return db.localWrite(func(tx *sql.Tx) error {
		for i := range p.I {
			p.I[i] = trackKey(p.I[i])
		}
		_, err := mergePlaylist(tx, p)
		return err
	})
}

// MARK: queries for the web UI

type SyncUser struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func (db *DB) SyncUsers(hostDefaultName string) []SyncUser {
	out := []SyncUser{}
	hasDefault := false
	rows, err := db.sql.Query("SELECT user_id, name FROM sync_users WHERE deleted = 0 ORDER BY name")
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var u SyncUser
			if rows.Scan(&u.ID, &u.Name) == nil {
				if u.ID == defaultUser {
					hasDefault = true
				}
				out = append(out, u)
			}
		}
	}
	if !hasDefault {
		out = append([]SyncUser{{ID: defaultUser, Name: hostDefaultName}}, out...)
	}
	return out
}

func (db *DB) aliasMap() map[string]string {
	m := map[string]string{}
	rows, err := db.sql.Query("SELECT old_key, keep_key FROM sync_aliases")
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var o, k string
			if rows.Scan(&o, &k) == nil {
				m[o] = k
			}
		}
	}
	resolve := func(k string) string {
		for i := 0; i < 20; i++ {
			n, ok := m[k]
			if !ok {
				break
			}
			k = n
		}
		return k
	}
	out := make(map[string]string, len(m))
	for o := range m {
		out[o] = resolve(o)
	}
	return out
}

type userStats struct {
	plays, skips int
	last         float64
	fav          bool
	favTS        float64
	hasFav       bool
}

// UserStats: per song key (after aliases), totals over every device + the user's favorite.
func (db *DB) UserStats(user string) map[string]*userStats {
	alias := db.aliasMap()
	out := map[string]*userStats{}
	get := func(k string) *userStats {
		if a, ok := alias[k]; ok {
			k = a
		}
		s := out[k]
		if s == nil {
			s = &userStats{}
			out[k] = s
		}
		return s
	}
	if rows, err := db.sql.Query("SELECT track_key, SUM(plays), SUM(skips), MAX(COALESCE(last_played,0)) FROM sync_plays WHERE user_id = ? GROUP BY track_key", user); err == nil {
		for rows.Next() {
			var k string
			var p, s int
			var l float64
			if rows.Scan(&k, &p, &s, &l) == nil {
				st := get(k)
				st.plays += p
				st.skips += s
				st.last = max(st.last, l)
			}
		}
		rows.Close()
	}
	if rows, err := db.sql.Query("SELECT track_key, favorite, ts FROM sync_favorites WHERE user_id = ?", user); err == nil {
		for rows.Next() {
			var k string
			var f bool
			var t float64
			if rows.Scan(&k, &f, &t) == nil {
				st := get(k)
				if !st.hasFav || t > st.favTS {
					st.fav, st.favTS, st.hasFav = f, t, true
				}
			}
		}
		rows.Close()
	}
	return out
}

func (db *DB) Playlists(user string) []PlaylistCell {
	alias := db.aliasMap()
	out := []PlaylistCell{}
	rows, err := db.sql.Query("SELECT playlist_id, user_id, name, items, ts, by FROM sync_playlists WHERE user_id = ? AND deleted = 0 ORDER BY name", user)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var p PlaylistCell
		var items string
		if rows.Scan(&p.ID, &p.U, &p.N, &items, &p.T, &p.B) == nil {
			_ = json.Unmarshal([]byte(items), &p.I)
			for i, k := range p.I {
				if a, ok := alias[k]; ok {
					p.I[i] = a
				}
			}
			p.I = nonNil(p.I)
			out = append(out, p)
		}
	}
	return out
}

// MigrateLegacy moves pre-sync web plays and favorites into the replicated tables (once).
func (db *DB) MigrateLegacy(replica string) error {
	if db.syncMeta(db.sql, "legacyMigrated") != "" {
		return nil
	}
	return db.localWrite(func(tx *sql.Tx) error {
		rows, err := tx.Query("SELECT rel_path, play_count, skip_count, last_played, favorite, favorite_at FROM tracks WHERE play_count > 0 OR skip_count > 0 OR favorite = 1 OR favorite_at IS NOT NULL")
		if err != nil {
			return err
		}
		type row struct {
			p        string
			pc, sc   int
			lp, fat  sql.NullFloat64
			fav      bool
		}
		var list []row
		for rows.Next() {
			var r row
			if rows.Scan(&r.p, &r.pc, &r.sc, &r.lp, &r.fav, &r.fat) == nil {
				list = append(list, r)
			}
		}
		rows.Close()
		for _, r := range list {
			k := trackKey(r.p)
			if r.pc > 0 || r.sc > 0 {
				c := PlayCell{U: defaultUser, K: k, R: replica, P: r.pc, S: r.sc}
				if r.lp.Valid {
					c.L = &r.lp.Float64
				}
				if _, err := mergePlay(tx, c); err != nil {
					return err
				}
			}
			if r.fav || r.fat.Valid {
				t := 1.0
				if r.fat.Valid {
					t = r.fat.Float64
				}
				if _, err := mergeFavorite(tx, FavCell{U: defaultUser, K: k, F: r.fav, T: t, B: replica}); err != nil {
					return err
				}
			}
		}
		_, err = tx.Exec("INSERT INTO sync_meta (key, value) VALUES ('legacyMigrated', '1') ON CONFLICT(key) DO NOTHING")
		return err
	})
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

var _ = strings.TrimSpace
