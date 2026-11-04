'use strict';
// MyMusic web player. The whole library is loaded once (a few MB at most) and browsed client-side.

const $ = (id) => document.getElementById(id);
const audio = $('audio');
const state = {
  tracks: [], byPath: new Map(), keys: new Map(), tree: null,
  view: 'songs', folder: '', pick: null, query: '',
  queue: [], index: -1, original: [], shuffle: false, repeat: 'off', counted: false,
  shown: [], rendered: 0,
};

// ---------- search: case- and accent-insensitive, all words must match (same rules as the apps)
const EXTRA = { 'đ': 'dj', 'ð': 'd', 'ł': 'l', 'ø': 'o', 'æ': 'ae', 'œ': 'oe', 'ß': 'ss', 'þ': 'th', 'ı': 'i' };
function fold(s) {
  return (s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[đðłøæœßþı]/g, (c) => EXTRA[c]);
}
function makeQuery(text) {
  const words = fold(text).split(/\s+/).filter(Boolean);
  return { empty: words.length === 0, test: (key) => words.every((w) => key.includes(w) || (key.includes('dj') && key.replaceAll('dj', 'd').includes(w))) };
}

// ---------- helpers
const fmt = (s) => {
  if (!isFinite(s) || s <= 0) return '–:––';
  s = Math.round(s);
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = String(s % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${sec}` : `${m}:${sec}`;
};
const artistOf = (t) => t.artist || t.albumArtist || 'Unknown Artist';
const albumOf = (t) => t.album || 'Unknown Album';
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const cmp = (a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' });
const albumOrder = (a, b) => cmp(albumOf(a), albumOf(b)) || (a.discNumber || 0) - (b.discNumber || 0) ||
  (a.trackNumber || 0) - (b.trackNumber || 0) || cmp(a.relPath, b.relPath);
const api = (path, body) => fetch(path, body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
const save = (k, v) => { try { localStorage.setItem('mm.' + k, JSON.stringify(v)); } catch (_) {} };
const load = (k, d) => { try { const v = localStorage.getItem('mm.' + k); return v === null ? d : JSON.parse(v); } catch (_) { return d; } };

// ---------- library
async function loadLibrary() {
  const res = await fetch('api/tracks');
  const list = await res.json();
  list.sort((a, b) => cmp(a.title, b.title));
  state.tracks = list;
  state.byPath = new Map(list.map((t) => [t.relPath, t]));
  state.keys = new Map(list.map((t) => [t.relPath, fold([t.title, t.artist, t.albumArtist, t.album, t.relPath].join(' '))]));
  state.tree = buildTree(list);
  // keep the queue pointing at fresh objects
  state.queue = state.queue.map((t) => state.byPath.get(t.relPath) || t);
  render();
  loadInfo();
}

async function loadInfo() {
  try {
    const i = await (await fetch('api/info')).json();
    const ago = (iso) => { if (!iso) return 'never'; const m = Math.round((Date.now() - Date.parse(iso)) / 60000); return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 2880 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} days ago`; };
    $('status').innerHTML = `${i.trackCount} songs on ${esc(i.name)}<br>Mac sync: ${ago(i.lastMacSync)}${i.macName ? ` (${esc(i.macName)})` : ''}`;
  } catch (_) {}
}

function buildTree(tracks) {
  const root = { path: '', name: 'Music', dirs: new Map(), tracks: [], total: 0 };
  for (const t of tracks) {
    let node = root; node.total++;
    const parts = t.relPath.split('/'); parts.pop();
    for (const p of parts) {
      if (!node.dirs.has(p)) node.dirs.set(p, { path: node.path ? node.path + '/' + p : p, name: p, dirs: new Map(), tracks: [], total: 0 });
      node = node.dirs.get(p); node.total++;
    }
    node.tracks.push(t);
  }
  return root;
}
function nodeAt(path) {
  let n = state.tree;
  if (!path) return n;
  for (const p of path.split('/')) { n = n && n.dirs.get(p); }
  return n || state.tree;
}
const subdirs = (n) => [...n.dirs.values()].sort((a, b) => cmp(a.name, b.name));
function allTracks(n) { const out = [...n.tracks].sort(albumOrder); for (const d of subdirs(n)) out.push(...allTracks(d)); return out; }
function searchFolders(n, q, out = []) {
  for (const d of subdirs(n)) { if (out.length > 300) break; if (q.test(fold(d.path))) out.push(d); else searchFolders(d, q, out); }
  return out;
}
const filterTracks = (list, q) => (q.empty ? list : list.filter((t) => q.test(state.keys.get(t.relPath) || '')));

// ---------- rendering
const VIEWS = {
  songs: 'Songs', folders: 'Folders', artists: 'Artists', albums: 'Albums', favorites: 'Favorites',
  mostPlayed: 'Most Played', recentlyPlayed: 'Recently Played', recentlyAdded: 'Recently Added', youtube: 'YouTube Likes',
  duplicates: 'Duplicates',
};

function viewTracks(q) {
  const T = state.tracks;
  switch (state.view) {
    case 'songs': return filterTracks(T, q);
    case 'favorites': return filterTracks(T.filter((t) => t.favorite), q);
    case 'mostPlayed': return filterTracks(T.filter((t) => t.playCount > 0).sort((a, b) => b.playCount - a.playCount).slice(0, 300), q);
    case 'recentlyPlayed': return filterTracks(T.filter((t) => t.lastPlayed).sort((a, b) => b.lastPlayed - a.lastPlayed).slice(0, 300), q);
    case 'recentlyAdded': return filterTracks([...T].sort((a, b) => b.addedAt - a.addedAt).slice(0, 300), q);
    case 'youtube': return filterTracks(T.filter((t) => t.source === 'youtube'), q);
    case 'artists': return state.pick ? T.filter((t) => artistOf(t) === state.pick || t.albumArtist === state.pick).sort(albumOrder) : [];
    case 'albums': return state.pick ? T.filter((t) => `${albumOf(t)}\u0001${t.albumArtist || artistOf(t)}` === state.pick).sort(albumOrder) : [];
  }
  return [];
}

function render() {
  if (!state.tree) return;
  if (state.view !== 'duplicates') { $('list').style.background = ''; $('list').style.border = ''; }
  $('playAll').hidden = $('shuffleAll').hidden = state.view === 'duplicates';
  const q = makeQuery(state.query);
  document.querySelectorAll('#nav a').forEach((a) => a.classList.toggle('active', a.dataset.view === state.view));
  const crumbs = $('crumbs'), folders = $('folders'), empty = $('empty');
  folders.innerHTML = ''; empty.hidden = true;
  let tracks = [];

  if (state.view === 'duplicates') {
    crumbs.textContent = 'Duplicates';
    $('count').textContent = '';
    state.shown = [];
    renderDuplicates(q);
    return;
  }
  if (state.view === 'folders') {
    const node = nodeAt(state.folder);
    const parts = state.folder ? state.folder.split('/') : [];
    crumbs.innerHTML = `<a data-folder="">Music</a>` + parts.map((p, i) =>
      `<span class="sep">›</span><a data-folder="${esc(parts.slice(0, i + 1).join('/'))}">${esc(p)}</a>`).join('');
    const dirs = q.empty ? subdirs(node) : searchFolders(node, q);
    folders.innerHTML = dirs.map((d) => `<div class="folder" data-folder="${esc(d.path)}">
        <span class="ico">${d.path === 'yt' ? '▶︎' : '📁'}</span>
        <span class="name">${esc(d.name)}${q.empty ? '' : `<span class="path">${esc(d.path)}</span>`}</span>
        <span class="n">${d.total}</span></div>`).join('');
    tracks = q.empty ? [...node.tracks].sort(albumOrder) : filterTracks(allTracks(node), q);
    if (!q.empty && !dirs.length && !tracks.length) { empty.hidden = false; empty.textContent = `Nothing matches “${state.query}”`; }
  } else if ((state.view === 'artists' || state.view === 'albums') && !state.pick) {
    crumbs.textContent = VIEWS[state.view];
    renderPicker(q);
    $('count').textContent = '';
    return;
  } else {
    const back = state.pick ? `<a data-unpick>${VIEWS[state.view]}</a><span class="sep">›</span>` : '';
    const title = state.pick ? esc(state.pick.split('\u0001')[0]) : VIEWS[state.view];
    crumbs.innerHTML = back + title;
    tracks = viewTracks(q);
    if (!tracks.length) { empty.hidden = false; empty.textContent = q.empty ? 'Nothing here yet' : `Nothing matches “${state.query}”`; }
  }
  state.shown = tracks;
  $('count').textContent = tracks.length ? `${tracks.length} songs` : '';
  renderRows(true);
}

function renderPicker(q) {
  const T = state.tracks, list = $('list');
  let items;
  if (state.view === 'artists') {
    const counts = new Map();
    for (const t of T) counts.set(artistOf(t), (counts.get(artistOf(t)) || 0) + 1);
    items = [...counts].filter(([a]) => q.test(fold(a))).sort((a, b) => cmp(a[0], b[0]))
      .map(([a, n]) => `<div class="pick" data-pick="${esc(a)}"><span>${esc(a)}</span><span class="sub">${n}</span></div>`);
  } else {
    const albums = new Map();
    for (const t of T) {
      const k = `${albumOf(t)}\u0001${t.albumArtist || artistOf(t)}`;
      if (!albums.has(k)) albums.set(k, t);
    }
    items = [...albums].filter(([k]) => q.test(fold(k))).sort((a, b) => cmp(a[0], b[0])).map(([k, t]) => {
      const [al, ar] = k.split('\u0001');
      return `<div class="pick" data-pick="${esc(k)}"><img class="art" style="width:40px;height:40px" loading="lazy" src="api/art?path=${encodeURIComponent(t.relPath)}" onerror="this.style.visibility='hidden'">
        <div><div>${esc(al)}</div><div class="sub">${esc(ar)}</div></div></div>`;
    });
  }
  state.shown = [];
  list.innerHTML = items.slice(0, 3000).join('');
  $('empty').hidden = items.length > 0;
  $('empty').textContent = 'Nothing matches';
}

const PAGE = 250;
function renderRows(reset) {
  const list = $('list');
  if (reset) {
    state.rendered = 0;
    list.innerHTML = state.shown.length ? `<div class="row head"><button class="heart" data-favall title="Favorite every song in this list">♥</button>
      <div>Title</div><div class="artist">Artist</div><div class="album">Album</div><div class="num">Time</div><div class="num plays">Plays</div></div>` : '';
  }
  const cur = state.queue[state.index]?.relPath;
  const slice = state.shown.slice(state.rendered, state.rendered + PAGE);
  list.insertAdjacentHTML('beforeend', slice.map((t, i) => `<div class="row${t.relPath === cur ? ' current' : ''}" data-i="${state.rendered + i}">
      <button class="heart${t.favorite ? ' on' : ''}" data-fav="${state.rendered + i}">${t.favorite ? '♥' : '♡'}</button>
      <div class="cell title">${esc(t.title)}<small>${esc(artistOf(t))}</small></div>
      <div class="cell artist">${esc(artistOf(t))}</div><div class="cell album">${esc(albumOf(t))}</div>
      <div class="num">${fmt(t.duration)}</div><div class="num plays">${t.playCount || ''}</div></div>`).join(''));
  state.rendered += slice.length;
}
// load more rows as you scroll
new IntersectionObserver((e) => { if (e[0].isIntersecting && state.rendered < state.shown.length) renderRows(false); },
  { root: $('main'), rootMargin: '600px' }).observe($('sentinel'));

function refreshRow(t) {
  const i = state.shown.indexOf(t);
  const btn = i >= 0 && document.querySelector(`[data-fav="${i}"]`);
  if (btn) { btn.classList.toggle('on', t.favorite); btn.textContent = t.favorite ? '♥' : '♡'; }
  updateNowPlaying();
}

// ---------- duplicates (found and removed on the server; the Mac and iPhone follow on their next sync)
const dup = { groups: null, scanning: false, msg: '' };
const ext = (p) => p.split('.').pop().toUpperCase();
const mb = (n) => (n / 1048576).toFixed(1) + ' MB';

async function scanDuplicates() {
  dup.scanning = true; dup.msg = ''; render();
  const t0 = performance.now();
  try {
    dup.groups = await (await fetch('api/duplicates')).json();
    dup.msg = `Checked ${state.tracks.length} songs in ${((performance.now() - t0) / 1000).toFixed(1)} s`;
  } catch (e) { dup.msg = 'Scan failed: ' + e; }
  dup.scanning = false; render();
}

function renderDuplicates(q) {
  const list = $('list'), groups = dup.groups;
  $('folders').innerHTML = '';
  const visible = (groups || []).filter((g) => q.empty || g.tracks.some((t) => q.test(state.keys.get(t.relPath) || fold(t.title + ' ' + t.relPath))));
  const extra = visible.reduce((n, g) => n + g.tracks.length - 1, 0);
  const bar = `<div class="dup-bar">
      <button class="btn" data-dupscan ${dup.scanning ? 'disabled' : ''}>${dup.scanning ? 'Scanning…' : groups ? 'Scan again' : 'Find duplicates'}</button>
      ${groups ? `<span class="muted">${visible.length} groups · ${visible.filter((g) => g.kind === 'identical').length} identical</span>
        <button class="btn danger" data-dupremove ${extra ? '' : 'disabled'}>Remove ${extra} extra copies…</button>` : ''}
      <span class="muted">${esc(dup.msg)}</span></div>`;
  if (!groups) {
    list.innerHTML = '';
    $('empty').hidden = false;
    $('empty').innerHTML = bar + `Finds byte-identical files and the same song stored twice (e.g. MP3 + FLAC, or a YouTube copy).
      You choose which copy stays; extra copies move to a hidden <code>.duplicates</code> folder in the music root, and their
      plays and favorites move to the copy you keep. The Mac and iPhone follow on their next sync.`;
    return;
  }
  $('empty').hidden = true;
  list.style.background = 'none'; list.style.border = '0';
  list.innerHTML = bar + (visible.length ? '' : '<div class="empty">No duplicates</div>') + visible.map((g) => `
    <div class="dup-group">
      <div class="dup-head">${esc(g.tracks[0].title)} <span class="tag ${g.kind}">${g.kind === 'identical' ? 'Identical files' : 'Same song'}</span>
        <button class="ignore" data-dupignore="${esc(g.id)}">Not duplicates – ignore</button></div>
      ${g.tracks.map((t) => {
        const keep = t.relPath === g.keep;
        return `<div class="dup-row ${keep ? '' : 'remove'}">
          <button class="keep" data-dupkeep="${esc(g.id)}" data-path="${esc(t.relPath)}" title="${keep ? 'Kept' : 'Will be removed – click to keep this one instead'}">${keep ? '✅' : '🗑'}</button>
          <div class="info"><div class="p">${esc(t.relPath)}</div>
            <div class="meta">${esc(artistOf(t))} · ${ext(t.relPath)} · ${t.kbps || '?'} kbps · ${mb(t.size)} · ${fmt(t.duration)} · ${t.playCount || 0} plays${t.favorite ? ' · ♥' : ''}${t.source === 'youtube' ? ' · YouTube' : ''}</div></div>
          <button class="icon-btn" data-dupplay="${esc(t.relPath)}" title="Preview">▶</button></div>`;
      }).join('')}
    </div>`).join('');
}

async function removeDuplicates() {
  const q = makeQuery(state.query);
  const visible = dup.groups.filter((g) => q.empty || g.tracks.some((t) => q.test(state.keys.get(t.relPath) || '')));
  const plans = visible.map((g) => ({ keep: g.keep, remove: g.tracks.map((t) => t.relPath).filter((p) => p !== g.keep) }));
  const n = plans.reduce((a, p) => a + p.remove.length, 0);
  if (!n || !confirm(`Move ${n} extra copies to the .duplicates folder?\n\nPlays and favorites move to the copies you keep. The Mac and iPhone follow on their next sync.`)) return;
  const res = await (await api('api/duplicates/remove', plans)).json();
  const ids = new Set(visible.map((g) => g.id));
  dup.groups = dup.groups.filter((g) => !ids.has(g.id));
  dup.msg = `Removed ${res.removed} files` + (res.failed.length ? ` · ${res.failed.length} failed: ${res.failed.slice(0, 3).join('; ')}` : '');
  await loadLibrary();
}

document.addEventListener('click', (e) => {
  if (state.view !== 'duplicates') return;
  if (e.target.closest('[data-dupscan]')) { scanDuplicates(); return; }
  if (e.target.closest('[data-dupremove]')) { removeDuplicates(); return; }
  const ig = e.target.closest('[data-dupignore]');
  if (ig) { dup.groups = dup.groups.filter((g) => g.id !== ig.dataset.dupignore); render(); return; }
  const k = e.target.closest('[data-dupkeep]');
  if (k) { const g = dup.groups.find((g) => g.id === k.dataset.dupkeep); if (g) { g.keep = k.dataset.path; render(); } return; }
  const pl = e.target.closest('[data-dupplay]');
  if (pl) { const t = state.byPath.get(pl.dataset.dupplay); if (t) play([t]); }
}, true);

// ---------- favorites
async function setFavorite(list, fav) {
  list.forEach((t) => { t.favorite = fav; });
  list.forEach(refreshRow);
  await api('api/favorite', { paths: list.map((t) => t.relPath), favorite: fav });
}

// ---------- player
function play(list, start = 0) {
  if (!list.length) return;
  state.original = [...list];
  if (state.shuffle) {
    const first = list[start];
    const rest = list.filter((_, i) => i !== start);
    shuffleInPlace(rest);
    state.queue = [first, ...rest]; state.index = 0;
  } else { state.queue = [...list]; state.index = start; }
  loadCurrent(true);
}
function shuffleInPlace(a) { for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } }

function loadCurrent(autoplay) {
  const t = state.queue[state.index];
  if (!t) return;
  state.counted = false;
  audio.src = 'api/stream?path=' + encodeURIComponent(t.relPath);
  if (autoplay) audio.play().catch(() => {});
  updateNowPlaying();
  document.querySelectorAll('.row.current').forEach((r) => r.classList.remove('current'));
  const i = state.shown.indexOf(t);
  if (i >= 0) document.querySelector(`.row[data-i="${i}"]`)?.classList.add('current');
}

function next(manual = true) {
  if (!state.queue.length) return;
  const cur = state.queue[state.index];
  if (manual && !state.counted && audio.currentTime > 0 && cur) api('api/skipped', { path: cur.relPath });
  if (state.index + 1 < state.queue.length) state.index++;
  else if (state.repeat === 'all') state.index = 0;
  else { audio.pause(); audio.currentTime = 0; return; }
  loadCurrent(true);
}
function prev() {
  if (audio.currentTime > 3 || state.index <= 0) { audio.currentTime = 0; return; }
  state.index--; loadCurrent(true);
}
function countPlay() {
  const t = state.queue[state.index];
  if (!t || state.counted) return;
  state.counted = true;
  t.playCount = (t.playCount || 0) + 1; t.lastPlayed = Date.now() / 1000;
  api('api/played', { path: t.relPath });
}

function updateNowPlaying() {
  const t = state.queue[state.index];
  $('nowTitle').textContent = t ? t.title : 'Not playing';
  $('nowSub').textContent = t ? `${artistOf(t)} — ${albumOf(t)}` : '';
  $('favBtn').hidden = !t;
  if (t) { $('favBtn').textContent = t.favorite ? '♥' : '♡'; }
  const art = $('art');
  const src = t ? 'api/art?path=' + encodeURIComponent(t.relPath) : '';
  if (art.dataset.src !== src) { art.dataset.src = src; art.style.visibility = src ? 'visible' : 'hidden'; if (src) art.src = src; }
  document.title = t ? `${t.title} – MyMusic` : 'MyMusic';
  if ('mediaSession' in navigator && t) {
    navigator.mediaSession.metadata = new MediaMetadata({ title: t.title, artist: artistOf(t), album: albumOf(t),
      artwork: [{ src: location.origin + location.pathname.replace(/[^/]*$/, '') + src, sizes: '512x512' }] });
  }
}

audio.addEventListener('play', () => { $('playBtn').textContent = '⏸'; });
audio.addEventListener('pause', () => { $('playBtn').textContent = '▶'; });
audio.addEventListener('ended', () => {
  countPlay();
  if (state.repeat === 'one') { audio.currentTime = 0; audio.play(); state.counted = false; return; }
  next(false);
});
audio.addEventListener('error', () => { if (state.queue.length > 1) setTimeout(() => next(false), 800); });
let seeking = false;
audio.addEventListener('timeupdate', () => {
  const d = audio.duration, c = audio.currentTime;
  if (!seeking && isFinite(d) && d > 0) $('seek').value = Math.round((c / d) * 1000);
  $('cur').textContent = fmt(c); $('dur').textContent = fmt(d);
  if (!state.counted && isFinite(d) && d > 0 && c >= Math.min(d * 0.5, 240)) countPlay();
});
$('seek').addEventListener('input', () => { seeking = true; });
$('seek').addEventListener('change', () => {
  seeking = false;
  if (isFinite(audio.duration)) audio.currentTime = ($('seek').value / 1000) * audio.duration;
});
$('playBtn').onclick = () => {
  if (!audio.src) { play(state.shown.length ? state.shown : state.tracks); return; }
  audio.paused ? audio.play() : audio.pause();
};
$('nextBtn').onclick = () => next(true);
$('prevBtn').onclick = prev;
$('favBtn').onclick = () => { const t = state.queue[state.index]; if (t) setFavorite([t], !t.favorite); };
$('shuffleBtn').onclick = () => {
  state.shuffle = !state.shuffle; $('shuffleBtn').classList.toggle('on', state.shuffle); save('shuffle', state.shuffle);
  const cur = state.queue[state.index];
  if (!cur) return;
  if (state.shuffle) { const rest = state.queue.filter((t) => t !== cur); shuffleInPlace(rest); state.queue = [cur, ...rest]; state.index = 0; }
  else { state.queue = [...state.original]; state.index = Math.max(0, state.queue.indexOf(cur)); }
};
$('repeatBtn').onclick = () => {
  state.repeat = { off: 'all', all: 'one', one: 'off' }[state.repeat];
  $('repeatBtn').classList.toggle('on', state.repeat !== 'off');
  $('repeatBtn').textContent = state.repeat === 'one' ? '↻¹' : '↻';
  save('repeat', state.repeat);
};
$('vol').oninput = () => { audio.volume = +$('vol').value; save('volume', audio.volume); };

if ('mediaSession' in navigator) {
  const ms = navigator.mediaSession;
  ms.setActionHandler('play', () => audio.play());
  ms.setActionHandler('pause', () => audio.pause());
  ms.setActionHandler('nexttrack', () => next(true));
  ms.setActionHandler('previoustrack', prev);
  try { ms.setActionHandler('seekto', (e) => { audio.currentTime = e.seekTime; }); } catch (_) {}
}

// ---------- events
$('nav').addEventListener('click', (e) => {
  const a = e.target.closest('a[data-view]');
  if (!a) return;
  state.view = a.dataset.view; state.pick = null; state.query = ''; $('search').value = '';
  $('nav').classList.remove('open'); save('view', state.view);
  $('main').scrollTop = 0; render();
});
$('main').addEventListener('click', (e) => {
  const fav = e.target.closest('[data-fav]');
  if (fav) { const t = state.shown[+fav.dataset.fav]; setFavorite([t], !t.favorite); return; }
  if (e.target.closest('[data-favall]')) {
    const list = state.shown, all = list.every((t) => t.favorite);
    if (list.length > 25 && !confirm(`${all ? 'Remove' : 'Add'} all ${list.length} songs ${all ? 'from' : 'to'} favorites?`)) return;
    setFavorite(list, !all); return;
  }
  const folder = e.target.closest('[data-folder]');
  if (folder) { state.folder = folder.dataset.folder; state.query = ''; $('search').value = ''; $('main').scrollTop = 0; render(); return; }
  const pick = e.target.closest('[data-pick]');
  if (pick) { state.pick = pick.dataset.pick; state.query = ''; $('search').value = ''; $('main').scrollTop = 0; render(); return; }
  if (e.target.closest('[data-unpick]')) { state.pick = null; render(); return; }
  const row = e.target.closest('.row[data-i]');
  if (row) play(state.shown, +row.dataset.i);
});
$('playAll').onclick = () => { state.shuffle && $('shuffleBtn').click(); play(state.shown.length ? state.shown : allTracks(nodeAt(state.folder))); };
$('shuffleAll').onclick = () => {
  const list = state.shown.length ? state.shown : allTracks(nodeAt(state.folder));
  if (!state.shuffle) $('shuffleBtn').click();
  play(list, Math.floor(Math.random() * list.length));
};
let searchTimer;
$('search').addEventListener('input', () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => { state.query = $('search').value; $('main').scrollTop = 0; render(); }, 120);
});
$('reloadBtn').onclick = () => loadLibrary();
$('menuBtn').onclick = () => $('nav').classList.toggle('open');
document.addEventListener('keydown', (e) => {
  if (e.target.matches('input') ) { if (e.key === 'Escape') { e.target.value = ''; state.query = ''; render(); e.target.blur(); } return; }
  if (e.code === 'Space') { e.preventDefault(); $('playBtn').click(); }
  else if (e.key === '/') { e.preventDefault(); $('search').focus(); }
  else if (e.key === 'ArrowRight' && e.metaKey) next(true);
  else if (e.key === 'ArrowLeft' && e.metaKey) prev();
});

// ---------- start
state.view = load('view', 'songs');
state.shuffle = load('shuffle', false); $('shuffleBtn').classList.toggle('on', state.shuffle);
state.repeat = load('repeat', 'off'); $('repeatBtn').classList.toggle('on', state.repeat !== 'off');
if (state.repeat === 'one') $('repeatBtn').textContent = '↻¹';
audio.volume = load('volume', 1); $('vol').value = audio.volume;
updateNowPlaying();
loadLibrary().catch((e) => { $('empty').hidden = false; $('empty').textContent = 'Could not load the library: ' + e; });
setInterval(loadInfo, 60000);
// pick up Mac syncs (new songs, play counts, favorites) every few minutes while open
setInterval(() => { if (document.visibilityState === 'visible' && audio.paused) loadLibrary(); }, 5 * 60000);
