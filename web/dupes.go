package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

// Duplicate detection, the same rules as the Mac tool (Mac/DuplicateFinder.swift), but with
// direct disk access: byte-identical files (size + checksum of head and tail) and the same song
// stored twice (normalized artist + title, lengths within 4 s).

type DupTrack struct {
	WebTrack
	Kbps int `json:"kbps"`
}

type DupGroup struct {
	ID     string     `json:"id"`
	Kind   string     `json:"kind"` // "identical" | "sameSong"
	Tracks []DupTrack `json:"tracks"`
	Keep   string     `json:"keep"`
}

func FindDuplicates(tracks []WebTrack, root string) []DupGroup {
	var groups []DupGroup
	grouped := map[string]bool{}

	// 1. identical files
	bySize := map[int64][]WebTrack{}
	for _, t := range tracks {
		bySize[t.Size] = append(bySize[t.Size], t)
	}
	for _, same := range bySize {
		if len(same) < 2 {
			continue
		}
		byHash := map[string][]WebTrack{}
		for _, t := range same {
			if h := fingerprint(filepath.Join(root, filepath.FromSlash(t.RelPath)), t.Size); h != "" {
				byHash[h] = append(byHash[h], t)
			}
		}
		for h, ts := range byHash {
			if len(ts) < 2 {
				continue
			}
			g := makeGroup("id-"+h, "identical", ts)
			groups = append(groups, g)
			for _, t := range ts {
				grouped[t.RelPath] = true
			}
		}
	}

	// 2. same song
	byKey := map[string][]WebTrack{}
	for _, t := range tracks {
		if grouped[t.RelPath] {
			continue
		}
		for _, k := range songKeys(t.Track) {
			byKey[k] = append(byKey[k], t)
		}
	}
	keys := make([]string, 0, len(byKey))
	for k := range byKey {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	seen := map[string]bool{}
	for _, k := range keys {
		ts := byKey[k]
		if len(ts) < 2 {
			continue
		}
		sort.Slice(ts, func(i, j int) bool { return dur(ts[i]) < dur(ts[j]) })
		var clusters [][]WebTrack
		for _, t := range ts {
			if seen[t.RelPath] {
				continue
			}
			if n := len(clusters); n > 0 {
				last := clusters[n-1][len(clusters[n-1])-1]
				if t.Duration == nil || last.Duration == nil || dur(t)-dur(last) <= 4 {
					clusters[n-1] = append(clusters[n-1], t)
					continue
				}
			}
			clusters = append(clusters, []WebTrack{t})
		}
		for _, c := range clusters {
			uniq := map[string]WebTrack{}
			for _, t := range c {
				uniq[t.RelPath] = t
			}
			if len(uniq) < 2 {
				continue
			}
			list := make([]WebTrack, 0, len(uniq))
			for _, t := range uniq {
				list = append(list, t)
				seen[t.RelPath] = true
			}
			groups = append(groups, makeGroup("song-"+k+"-"+list[0].RelPath, "sameSong", list))
		}
	}
	sort.SliceStable(groups, func(i, j int) bool {
		if groups[i].Kind != groups[j].Kind {
			return groups[i].Kind == "identical"
		}
		return strings.ToLower(groups[i].Tracks[0].Title) < strings.ToLower(groups[j].Tracks[0].Title)
	})
	return groups
}

func makeGroup(id, kind string, ts []WebTrack) DupGroup {
	sort.SliceStable(ts, func(i, j int) bool { return better(ts[i], ts[j]) })
	g := DupGroup{ID: id, Kind: kind, Keep: ts[0].RelPath}
	for _, t := range ts {
		g.Tracks = append(g.Tracks, DupTrack{WebTrack: t, Kbps: int(kbps(t))})
	}
	return g
}

func fingerprint(path string, size int64) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	const chunk = 256 * 1024
	h := sha256.New()
	fmt.Fprintf(h, "%d|", size)
	if _, err := io.CopyN(h, f, chunk); err != nil && err != io.EOF {
		return ""
	}
	if size > 2*chunk {
		if _, err := f.Seek(size-chunk, io.SeekStart); err == nil {
			io.CopyN(h, f, chunk)
		}
	}
	return hex.EncodeToString(h.Sum(nil))
}

var (
	bracketRe   = regexp.MustCompile(`[\(\[\{]([^\)\]\}]*)[\)\]\}]`)
	featRe      = regexp.MustCompile(`\b(feat|ft|featuring)\.?\s.*$`)
	leadNumRe   = regexp.MustCompile(`^\s*\d{1,3}[\s\.\-]+`)
	genericRe   = regexp.MustCompile(`^(track|piste|titel|untitled)?\d*$`)
	noiseWords  = []string{"official", "video", "audio", "lyric", "visuali", "hd", "hq", "4k", "remaster", "explicit", "clean", "mv", "full song", "free download"}
	noisePhrase = []string{"official music video", "official video", "official audio", "lyric video", "+ lyrics", "hq audio"}
	extraLetter = strings.NewReplacer("đ", "dj", "ð", "d", "ł", "l", "ø", "o", "æ", "ae", "œ", "oe", "ß", "ss", "þ", "th", "ı", "i")
)

// normalize mirrors DuplicateFinder.normalize on the Mac.
func normalize(in string) string {
	s := strings.ToLower(in)
	s = stripAccents(s)
	s = extraLetter.Replace(s)
	s = strings.ReplaceAll(s, "_", " ")
	s = bracketRe.ReplaceAllStringFunc(s, func(m string) string {
		inner := bracketRe.FindStringSubmatch(m)[1]
		for _, w := range noiseWords {
			if strings.Contains(inner, w) {
				return " "
			}
		}
		return " " + inner + " "
	})
	for _, p := range noisePhrase {
		s = strings.ReplaceAll(s, p, " ")
	}
	s = featRe.ReplaceAllString(s, " ")
	s = leadNumRe.ReplaceAllString(s, "")
	s = strings.ReplaceAll(s, "&", "and")
	var b strings.Builder
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func stripAccents(s string) string {
	var b strings.Builder
	for _, r := range norm.NFD.String(s) {
		if !unicode.Is(unicode.Mn, r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func songKeys(t Track) []string {
	title := normalize(t.Title)
	if len(title) <= 2 || genericRe.MatchString(title) {
		return nil
	}
	set := map[string]bool{}
	artist := t.Artist
	if artist == nil {
		artist = t.AlbumArtist
	}
	if artist != nil {
		set[normalize(*artist)+"|"+title] = true
	}
	if i := strings.Index(t.Title, " - "); i >= 0 {
		a, ti := normalize(t.Title[:i]), normalize(t.Title[i+3:])
		if a != "" && ti != "" {
			set[a+"|"+ti] = true
		}
	}
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	return out
}

var lossless = map[string]bool{".flac": true, ".wav": true, ".aif": true, ".aiff": true, ".alac": true}

func dur(t WebTrack) float64 {
	if t.Duration == nil {
		return 0
	}
	return *t.Duration
}

func kbps(t WebTrack) float64 {
	if d := dur(t); d > 0 {
		return float64(t.Size) * 8 / (d * 1000)
	}
	return 0
}

func quality(t WebTrack) float64 {
	q := kbps(t)
	if lossless[strings.ToLower(filepath.Ext(t.RelPath))] {
		q += 10000
	}
	return q
}

// better: lossless first, then bitrate, then non-YouTube, then most played, then shorter path.
func better(a, b WebTrack) bool {
	qa, qb := quality(a), quality(b)
	if d := qa - qb; d > 16 || d < -16 {
		return qa > qb
	}
	if a.Source != b.Source {
		return a.Source != "youtube"
	}
	if a.PlayCount != b.PlayCount {
		return a.PlayCount > b.PlayCount
	}
	return len(a.RelPath) < len(b.RelPath)
}

// MARK: removal

type RemovePlan struct {
	Keep   string   `json:"keep"`
	Remove []string `json:"remove"`
}

// RemoveDuplicates moves each extra copy into <root>/.duplicates/<path> (hidden, so scans skip
// it; nothing is deleted), folds its plays and favorite into the kept copy, and logs the removal
// for the Mac to pick up.
func (s *server) removeDuplicates(plans []RemovePlan) (removed int, failed []string) {
	for _, p := range plans {
		if !s.db.Has(p.Keep) {
			failed = append(failed, p.Keep+": kept copy not in library")
			continue
		}
		for _, rel := range p.Remove {
			if rel == p.Keep || !s.db.Has(rel) {
				continue
			}
			src, ok := s.resolve(rel)
			if !ok {
				failed = append(failed, rel+": not in library")
				continue
			}
			dst := filepath.Join(s.root, ".duplicates", filepath.FromSlash(rel))
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				failed = append(failed, rel+": "+err.Error())
				continue
			}
			if _, err := os.Stat(dst); err == nil {
				dst += fmt.Sprintf(".%d", now64())
			}
			if err := os.Rename(src, dst); err != nil {
				failed = append(failed, rel+": "+err.Error())
				continue
			}
			_ = s.db.SyncAddAlias(rel, p.Keep, s.replica) // every peer folds its stats into the kept song
			if err := s.db.RecordRemoval(rel, p.Keep); err != nil {
				failed = append(failed, rel+": moved, but updating the library failed: "+err.Error())
				continue
			}
			removed++
		}
	}
	return removed, failed
}

func now64() int64 { return int64(now()) }
