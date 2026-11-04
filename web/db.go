package main

import (
	"database/sql"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	_ "modernc.org/sqlite"
)

// Track mirrors the Swift `Track` JSON (Shared/Models.swift) so the Mac can push its
// LibraryManifest as-is. PlayCount from the Mac is the Mac-side total (Mac + iPhones);
// the web player's own plays are kept separately and added on top.
type Track struct {
	RelPath     string   `json:"relPath"`
	Size        int64    `json:"size"`
	Mtime       float64  `json:"mtime"`
	Title       string   `json:"title"`
	Artist      *string  `json:"artist,omitempty"`
	Album       *string  `json:"album,omitempty"`
	AlbumArtist *string  `json:"albumArtist,omitempty"`
	TrackNumber *int     `json:"trackNumber,omitempty"`
	DiscNumber  *int     `json:"discNumber,omitempty"`
	Duration    *float64 `json:"duration,omitempty"`
	Genre       *string  `json:"genre,omitempty"`
	Year        *int     `json:"year,omitempty"`
	Source      string   `json:"source"`
	Origin      string   `json:"origin"`
	AddedAt     float64  `json:"addedAt"`
	PlayCount   int      `json:"playCount"`
	SkipCount   int      `json:"skipCount"`
	LastPlayed  *float64 `json:"lastPlayed,omitempty"`
	Favorite    bool     `json:"favorite"`
	FavoriteAt  *float64 `json:"favoriteAt,omitempty"`
}

type LibraryManifest struct {
	ServerName  string  `json:"serverName"`
	APIVersion  int     `json:"apiVersion"`
	GeneratedAt float64 `json:"generatedAt"`
	Tracks      []Track `json:"tracks"`
}

type PlayStatEntry struct {
	RelPath    string   `json:"relPath"`
	PlayCount  int      `json:"playCount"`
	SkipCount  int      `json:"skipCount"`
	LastPlayed *float64 `json:"lastPlayed,omitempty"`
	Favorite   bool     `json:"favorite"`
	FavoriteAt *float64 `json:"favoriteAt,omitempty"`
}

type StatsUpload struct {
	DeviceID   string          `json:"deviceID"`
	DeviceName string          `json:"deviceName"`
	Entries    []PlayStatEntry `json:"entries"`
}

type DB struct {
	sql *sql.DB
	mu  sync.Mutex // serialize writes; SQLite allows one writer
}

const schema = `
CREATE TABLE IF NOT EXISTS tracks (
	rel_path TEXT PRIMARY KEY,
	size INTEGER NOT NULL, mtime REAL NOT NULL, title TEXT NOT NULL,
	artist TEXT, album TEXT, album_artist TEXT, track_no INTEGER, disc_no INTEGER,
	duration REAL, genre TEXT, year INTEGER,
	source TEXT NOT NULL DEFAULT 'local',
	origin TEXT NOT NULL DEFAULT 'scan',          -- 'mac' (pushed by the Mac) or 'scan' (found on disk here)
	added_at REAL NOT NULL,
	base_play_count INTEGER NOT NULL DEFAULT 0,   -- plays counted on the Mac side (Mac + iPhones)
	play_count INTEGER NOT NULL DEFAULT 0,        -- plays in the web player (reported back to the Mac)
	skip_count INTEGER NOT NULL DEFAULT 0,
	last_played REAL,
	favorite INTEGER NOT NULL DEFAULT 0,
	favorite_at REAL
);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
`

// Columns added after the first release (ALTER fails harmlessly if they exist).
var migrations = []string{
	// The Mac's spelling of rel_path when it differs from the file on this disk (macOS gives
	// decomposed/NFD accents over SMB, Linux stores composed/NFC). Stats go back under this name.
	"ALTER TABLE tracks ADD COLUMN mac_path TEXT",
}

func OpenDB(path string) (*DB, error) {
	// WAL is fine here: the database lives on this machine's local disk.
	d, err := sql.Open("sqlite", "file:"+path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)")
	if err != nil {
		return nil, err
	}
	d.SetMaxOpenConns(4)
	if _, err := d.Exec(schema); err != nil {
		return nil, fmt.Errorf("schema: %w", err)
	}
	for _, m := range migrations {
		if _, err := d.Exec(m); err != nil && !strings.Contains(err.Error(), "duplicate column") {
			return nil, fmt.Errorf("migration %q: %w", m, err)
		}
	}
	return &DB{sql: d}, nil
}

func (db *DB) Meta(key string) string {
	var v string
	_ = db.sql.QueryRow("SELECT value FROM meta WHERE key = ?", key).Scan(&v)
	return v
}

func (db *DB) SetMeta(key, value string) {
	db.mu.Lock()
	defer db.mu.Unlock()
	_, _ = db.sql.Exec("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value)
}

const trackCols = `rel_path, size, mtime, title, artist, album, album_artist, track_no, disc_no, duration, genre, year,
	source, origin, added_at, base_play_count, play_count, skip_count, last_played, favorite, favorite_at`

// WebTrack is what the browser gets: total plays (Mac side + web).
type WebTrack struct {
	Track
	WebPlays int `json:"webPlays"`
}

func (db *DB) AllTracks() ([]WebTrack, error) {
	rows, err := db.sql.Query("SELECT " + trackCols + " FROM tracks")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []WebTrack
	for rows.Next() {
		var t WebTrack
		var base int
		var fav int
		if err := rows.Scan(&t.RelPath, &t.Size, &t.Mtime, &t.Title, &t.Artist, &t.Album, &t.AlbumArtist, &t.TrackNumber,
			&t.DiscNumber, &t.Duration, &t.Genre, &t.Year, &t.Source, &t.Origin, &t.AddedAt, &base, &t.WebPlays,
			&t.SkipCount, &t.LastPlayed, &fav, &t.FavoriteAt); err != nil {
			return nil, err
		}
		t.Favorite = fav != 0
		t.PlayCount = base + t.WebPlays
		out = append(out, t)
	}
	return out, rows.Err()
}

func (db *DB) Has(relPath string) bool {
	var n int
	_ = db.sql.QueryRow("SELECT 1 FROM tracks WHERE rel_path = ?", relPath).Scan(&n)
	return n == 1
}

func (db *DB) Stamps() map[string][2]float64 {
	out := map[string][2]float64{}
	rows, err := db.sql.Query("SELECT rel_path, size, mtime FROM tracks")
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var p string
		var size int64
		var mtime float64
		if rows.Scan(&p, &size, &mtime) == nil {
			out[p] = [2]float64{float64(size), mtime}
		}
	}
	return out
}

// UpsertScanned adds/updates tracks found on this machine's disk (keeps stats; never overrides Mac data).
func (db *DB) UpsertScanned(ts []Track) error {
	db.mu.Lock()
	defer db.mu.Unlock()
	tx, err := db.sql.Begin()
	if err != nil {
		return err
	}
	stmt, err := tx.Prepare(`INSERT INTO tracks (rel_path, size, mtime, title, artist, album, album_artist, track_no, disc_no, genre, year, source, origin, added_at)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,'scan',?)
		ON CONFLICT(rel_path) DO UPDATE SET size=excluded.size, mtime=excluded.mtime,
		  title=CASE WHEN tracks.origin='scan' THEN excluded.title ELSE tracks.title END,
		  artist=CASE WHEN tracks.origin='scan' THEN excluded.artist ELSE tracks.artist END,
		  album=CASE WHEN tracks.origin='scan' THEN excluded.album ELSE tracks.album END`)
	if err != nil {
		tx.Rollback()
		return err
	}
	defer stmt.Close()
	for _, t := range ts {
		if _, err := stmt.Exec(t.RelPath, t.Size, t.Mtime, t.Title, t.Artist, t.Album, t.AlbumArtist, t.TrackNumber, t.DiscNumber,
			t.Genre, t.Year, t.Source, t.AddedAt); err != nil {
			tx.Rollback()
			return err
		}
	}
	return tx.Commit()
}

func (db *DB) Delete(paths []string) error {
	db.mu.Lock()
	defer db.mu.Unlock()
	tx, err := db.sql.Begin()
	if err != nil {
		return err
	}
	for _, p := range paths {
		if _, err := tx.Exec("DELETE FROM tracks WHERE rel_path = ?", p); err != nil {
			tx.Rollback()
			return err
		}
	}
	return tx.Commit()
}

// ApplyMacLibrary replaces the library with the Mac's view. Metadata and Mac-side play counts come
// from the Mac; favorites follow newest-change-wins; web plays are kept. Tracks the Mac no longer
// has are removed (files found only by the local scan stay until the Mac sees them).
//
// diskPath maps the Mac's relPath to the spelling of the file on this disk (Unicode normalization).
func (db *DB) ApplyMacLibrary(m LibraryManifest, diskPath func(string) string) (added, removed, favChanged int, err error) {
	db.mu.Lock()
	defer db.mu.Unlock()
	tx, err := db.sql.Begin()
	if err != nil {
		return 0, 0, 0, err
	}
	defer func() {
		if err != nil {
			tx.Rollback()
		}
	}()
	existing := map[string]struct {
		fav   bool
		favAt sql.NullFloat64
	}{}
	rows, err := tx.Query("SELECT rel_path, favorite, favorite_at FROM tracks")
	if err != nil {
		return 0, 0, 0, err
	}
	for rows.Next() {
		var p string
		var f int
		var at sql.NullFloat64
		if rows.Scan(&p, &f, &at) == nil {
			existing[p] = struct {
				fav   bool
				favAt sql.NullFloat64
			}{f != 0, at}
		}
	}
	rows.Close()

	seen := make(map[string]bool, len(m.Tracks))
	for _, t := range m.Tracks {
		var macPath *string
		if p := diskPath(t.RelPath); p != t.RelPath {
			mp := t.RelPath
			macPath = &mp
			t.RelPath = p
		}
		seen[t.RelPath] = true
		ex, ok := existing[t.RelPath]
		// favorite: take the Mac's state if it changed more recently (or ours has no timestamp)
		fav, favAt := t.Favorite, t.FavoriteAt
		if ok {
			macNewer := t.FavoriteAt != nil && (!ex.favAt.Valid || *t.FavoriteAt > ex.favAt.Float64)
			legacy := t.FavoriteAt == nil && !ex.favAt.Valid
			if !macNewer && !legacy {
				fav = ex.fav
				v := ex.favAt.Float64
				favAt = &v
			}
			if fav != ex.fav {
				favChanged++
			}
		} else {
			added++
		}
		_, err = tx.Exec(`INSERT INTO tracks (rel_path, size, mtime, title, artist, album, album_artist, track_no, disc_no, duration, genre, year,
				source, origin, added_at, base_play_count, last_played, favorite, favorite_at, mac_path)
			VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,'mac',?,?,?,?,?,?)
			ON CONFLICT(rel_path) DO UPDATE SET size=excluded.size, mtime=excluded.mtime, title=excluded.title, artist=excluded.artist,
			  album=excluded.album, album_artist=excluded.album_artist, track_no=excluded.track_no, disc_no=excluded.disc_no,
			  duration=excluded.duration, genre=excluded.genre, year=excluded.year, source=excluded.source, origin='mac',
			  added_at=excluded.added_at, base_play_count=excluded.base_play_count,
			  last_played=MAX(COALESCE(tracks.last_played, 0), COALESCE(excluded.last_played, 0)),
			  favorite=excluded.favorite, favorite_at=excluded.favorite_at, mac_path=excluded.mac_path`,
			t.RelPath, t.Size, t.Mtime, t.Title, t.Artist, t.Album, t.AlbumArtist, t.TrackNumber, t.DiscNumber, t.Duration,
			t.Genre, t.Year, nz(t.Source, "local"), t.AddedAt, t.PlayCount, t.LastPlayed, fav, favAt, macPath)
		if err != nil {
			return 0, 0, 0, err
		}
	}
	// drop Mac tracks the Mac removed
	rows, err = tx.Query("SELECT rel_path FROM tracks WHERE origin = 'mac'")
	if err != nil {
		return 0, 0, 0, err
	}
	var gone []string
	for rows.Next() {
		var p string
		if rows.Scan(&p) == nil && !seen[p] {
			gone = append(gone, p)
		}
	}
	rows.Close()
	for _, p := range gone {
		if _, err = tx.Exec("DELETE FROM tracks WHERE rel_path = ?", p); err != nil {
			return 0, 0, 0, err
		}
	}
	if err = tx.Commit(); err != nil {
		return 0, 0, 0, err
	}
	return added, len(gone), favChanged, nil
}

// WebStats is what the Mac pulls: this player's own plays and all favorite changes.
func (db *DB) WebStats() ([]PlayStatEntry, error) {
	// report under the Mac's own spelling of each path
	rows, err := db.sql.Query(`SELECT COALESCE(mac_path, rel_path), play_count, skip_count, last_played, favorite, favorite_at FROM tracks
		WHERE play_count > 0 OR skip_count > 0 OR favorite_at IS NOT NULL OR favorite = 1`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []PlayStatEntry{}
	for rows.Next() {
		var e PlayStatEntry
		var fav int
		if err := rows.Scan(&e.RelPath, &e.PlayCount, &e.SkipCount, &e.LastPlayed, &fav, &e.FavoriteAt); err != nil {
			return nil, err
		}
		e.Favorite = fav != 0
		out = append(out, e)
	}
	return out, rows.Err()
}

func (db *DB) RecordPlay(relPath string) error {
	db.mu.Lock()
	defer db.mu.Unlock()
	_, err := db.sql.Exec("UPDATE tracks SET play_count = play_count + 1, last_played = ? WHERE rel_path = ?", now(), relPath)
	return err
}

func (db *DB) RecordSkip(relPath string) error {
	db.mu.Lock()
	defer db.mu.Unlock()
	_, err := db.sql.Exec("UPDATE tracks SET skip_count = skip_count + 1 WHERE rel_path = ?", relPath)
	return err
}

func (db *DB) SetFavorite(paths []string, fav bool) error {
	db.mu.Lock()
	defer db.mu.Unlock()
	tx, err := db.sql.Begin()
	if err != nil {
		return err
	}
	at := now()
	for _, p := range paths {
		if _, err := tx.Exec("UPDATE tracks SET favorite = ?, favorite_at = ? WHERE rel_path = ?", fav, at, p); err != nil {
			tx.Rollback()
			return err
		}
	}
	return tx.Commit()
}

// clockOffset corrects this machine's clock to the Mac's (which sends its time with every sync).
// Favorite changes are merged newest-wins across machines, so their timestamps must agree even
// if this server's clock isn't NTP-synced.
var clockOffset atomic.Value // float64 seconds

func now() float64 {
	off, _ := clockOffset.Load().(float64)
	return float64(time.Now().UnixNano())/1e9 + off
}

func nz(s, def string) string {
	if strings.TrimSpace(s) == "" {
		return def
	}
	return s
}
