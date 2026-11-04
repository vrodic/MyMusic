package main

import (
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/dhowden/tag"
)

var audioExts = map[string]bool{".mp3": true, ".m4a": true, ".aac": true, ".flac": true, ".wav": true,
	".aif": true, ".aiff": true, ".caf": true, ".alac": true, ".m4b": true, ".mp4": true}

// Scan walks the music folder on this machine's own disk. It only adds files the Mac hasn't
// pushed yet (so the web player works even if the Mac never synced) and removes rows for
// files that are gone. Mac-provided metadata is never overwritten.
func Scan(db *DB, root string) (added, removed int, err error) {
	start := time.Now()
	stamps := db.Stamps()
	present := map[string]bool{}
	var changed []Track
	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // unreadable folder: skip it
		}
		name := d.Name()
		if strings.HasPrefix(name, ".") && path != root {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() || !audioExts[strings.ToLower(filepath.Ext(name))] {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		present[rel] = true
		info, err := d.Info()
		if err != nil {
			return nil
		}
		mtime := float64(info.ModTime().Unix())
		if s, ok := stamps[rel]; ok && int64(s[0]) == info.Size() && absf(s[1]-mtime) <= 1 {
			return nil
		}
		changed = append(changed, readTags(path, rel, info.Size(), mtime))
		return nil
	})
	if err != nil {
		return 0, 0, err
	}
	var gone []string
	for p := range stamps {
		if !present[p] {
			gone = append(gone, p)
		}
	}
	// Don't wipe the library if the music folder is temporarily missing (unmounted disk).
	if len(present) == 0 && len(stamps) > 0 {
		log.Printf("scan: %s has no audio files; keeping the existing %d tracks", root, len(stamps))
		gone = nil
	}
	if err := db.UpsertScanned(changed); err != nil {
		return 0, 0, err
	}
	if err := db.Delete(gone); err != nil {
		return 0, 0, err
	}
	log.Printf("scan: %d files, %d new/changed, %d removed in %s", len(present), len(changed), len(gone), time.Since(start).Round(time.Millisecond))
	return len(changed), len(gone), nil
}

func readTags(path, rel string, size int64, mtime float64) Track {
	base := strings.TrimSuffix(filepath.Base(rel), filepath.Ext(rel))
	t := Track{RelPath: rel, Size: size, Mtime: mtime, Title: base, Source: "local", AddedAt: now()}
	if strings.HasPrefix(rel, "yt/") {
		t.Source = "youtube"
	}
	if f, err := os.Open(path); err == nil {
		defer f.Close()
		if m, err := tag.ReadFrom(f); err == nil {
			if s := strings.TrimSpace(m.Title()); s != "" {
				t.Title = s
			}
			t.Artist = strp(m.Artist())
			t.Album = strp(m.Album())
			t.AlbumArtist = strp(m.AlbumArtist())
			t.Genre = strp(m.Genre())
			if n, _ := m.Track(); n > 0 {
				t.TrackNumber = &n
			}
			if n, _ := m.Disc(); n > 0 {
				t.DiscNumber = &n
			}
			if y := m.Year(); y > 0 {
				t.Year = &y
			}
		}
	}
	if t.Album == nil && t.Source != "youtube" {
		t.Album = strp(filepath.Base(filepath.Dir(rel)))
	}
	return t
}

// Artwork returns the embedded cover image, if any.
func Artwork(path string) ([]byte, string) {
	f, err := os.Open(path)
	if err != nil {
		return nil, ""
	}
	defer f.Close()
	m, err := tag.ReadFrom(f)
	if err != nil || m.Picture() == nil {
		return nil, ""
	}
	p := m.Picture()
	mime := p.MIMEType
	if mime == "" {
		mime = "image/jpeg"
	}
	return p.Data, mime
}

func strp(s string) *string {
	s = strings.TrimSpace(s)
	if s == "" || s == "." {
		return nil
	}
	return &s
}

func absf(f float64) float64 {
	if f < 0 {
		return -f
	}
	return f
}
