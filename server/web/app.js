// Mediaserver im Browser: dieselbe API und dasselbe Token wie die App.
// Kein fremder Code; alle Texte gehen über textContent, nie über HTML.
"use strict";

const TOKEN_KEY = "mediaserver.token";
const DEVICE_KEY = "mediaserver.webDevice";
const PAGE = 500;
/// Ab diesem Anteil gilt ein Video als gesehen, wie in der App.
const FINISHED = 0.93;
const state = {
  token: null, items: [], byId: new Map(), meta: {}, albums: [], series: [], movies: [], songs: [], artists: [],
  seriesById: new Map(), episodeInfo: new Map(), seriesInfo: new Map(), movieInfo: new Map(), albumInfo: new Map(), artistInfo: new Map(),
  watched: new Map(), lastPlayed: new Map(), cursor: 0, progress: new Map(),
  favorites: new Map(), plays: new Map(), ownPlays: new Map(), playlists: [], albumFavorite: new Map(),
};
const art = new Map();
const $ = (id) => document.getElementById(id);

// MARK: Speicher im Browser

function storage(kind) { try { return kind === "local" ? localStorage : sessionStorage; } catch { return null; } }
function storedToken() { return storage("local")?.getItem(TOKEN_KEY) || storage("session")?.getItem(TOKEN_KEY) || null; }
function keepToken(token, remember) {
  storage("local")?.removeItem(TOKEN_KEY); storage("session")?.removeItem(TOKEN_KEY);
  storage(remember ? "local" : "session")?.setItem(TOKEN_KEY, token);
}
function forgetToken() { storage("local")?.removeItem(TOKEN_KEY); storage("session")?.removeItem(TOKEN_KEY); }
function device() {
  let id = storage("local")?.getItem(DEVICE_KEY);
  if (!id) { id = `web-${crypto.randomUUID()}`; storage("local")?.setItem(DEVICE_KEY, id); }
  return id;
}

// MARK: Anmeldung und API

async function api(path, options = {}) {
  const response = await fetch(path, { ...options, headers: { ...(options.headers || {}), Authorization: `Bearer ${state.token}` } });
  if (response.status === 401) { signOut(); throw new Error("Nicht angemeldet"); }
  if (!response.ok) throw new Error(`Server antwortet ${response.status}`);
  return response;
}
const json = async (path, options) => (await api(path, options)).json();
const send = (path, method, body) => api(path, { method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

async function signIn(token, remember) {
  const response = await fetch("/v1/library?limit=1", { headers: { Authorization: `Bearer ${token}` } });
  if (response.status === 401) throw new Error("Das Token stimmt nicht.");
  if (!response.ok) throw new Error(`Der Server antwortet nicht richtig (${response.status}).`);
  keepToken(token, remember);
  state.token = token;
}

function signOut() {
  forgetToken();
  state.token = null;
  stopAudio();
  closeVideo();
  for (const url of art.values()) if (typeof url === "string") URL.revokeObjectURL(url);
  art.clear();
  $("app").hidden = true;
  $("anmelden").hidden = false;
  $("token").value = "";
  $("token").focus();
}

// MARK: Bibliothek

async function loadLibrary() {
  $("inhalt").replaceChildren(text("p", "Bibliothek wird geladen …", "empty"));
  const items = [];
  for (let offset = 0; ; offset += PAGE) {
    const page = await json(`/v1/library?offset=${offset}&limit=${PAGE}`);
    items.push(...page.items);
    if (items.length >= page.total || page.items.length === 0) break;
  }
  const [meta, playlists, disk] = await Promise.all([json("/v1/metadata").catch(() => ({})), json("/v1/playlists").catch(() => []),
    json("/v1/storage").catch(() => null), sync()]);
  state.meta = meta;
  state.storage = disk;
  state.playlists = Array.isArray(playlists) ? playlists : (playlists.playlists || []);
  state.items = items;
  state.byId = new Map(items.map((item) => [item.id, item]));
  group();
  // Lieblingsalben gleicht die App über einen Hash des Albumschlüssels ab, so auch hier.
  await Promise.all(state.albums.map(async (album) => {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`album:${album.id}`));
    state.albumFavorite.set(album.id, [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join(""));
  }));
}
const isFavorite = (id) => state.favorites.get(id)?.on === true;
const isFavoriteAlbum = (album) => isFavorite(state.albumFavorite.get(album.id));

/// Gesehen-Markierungen und zuletzt Gespieltes, gemeinsam mit App und anderen Geräten.
async function sync(changes = {}) {
  try {
    const answer = await json("/v1/personal/sync", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device: device(), since: state.cursor, watched: changes.watched || [], favorites: changes.favorites || [],
        plays: changes.plays || [], last_played: changes.lastPlayed || [] }),
    });
    if (answer.cursor < state.cursor) { state.cursor = 0; return sync(changes); }
    for (const flag of answer.watched || []) {
      const known = state.watched.get(flag.id);
      if (!known || flag.at >= known.at) state.watched.set(flag.id, flag);
    }
    for (const flag of answer.favorites || []) {
      const known = state.favorites.get(flag.id);
      if (!known || flag.at >= known.at) state.favorites.set(flag.id, flag);
    }
    for (const entry of answer.plays || []) state.plays.set(entry.id, entry.count);
    for (const entry of answer.last_played || []) {
      if ((state.lastPlayed.get(entry.id) || 0) < entry.at) state.lastPlayed.set(entry.id, entry.at);
    }
    state.cursor = answer.cursor;
  } catch { /* ohne Abgleich weiter; die Bibliothek bleibt nutzbar */ }
}
const isWatched = (item) => state.watched.get(item.id)?.on === true;

function setWatched(items, on) {
  const at = Date.now() / 1000;
  const flags = items.map((item) => ({ id: item.id, on, at }));
  for (const flag of flags) state.watched.set(flag.id, flag);
  for (const item of items) if (on) state.progress.set(item.id, 0);
  render();
  sync({ watched: flags });
  if (on) for (const item of items) send(`/v1/progress/${encodeURIComponent(item.id)}`, "PUT", { seconds: 0 }).catch(() => {});
}

function recordPlay(item) {
  const at = Date.now() / 1000;
  state.lastPlayed.set(item.id, at);
  const changes = { lastPlayed: [{ id: item.id, at }] };
  if (item.kind === "audio") {
    // Wie die App: jedes Gerät meldet seine eigene Zahl, der Server zählt zusammen.
    const own = (state.ownPlays.get(item.id) || 0) + 1;
    state.ownPlays.set(item.id, own);
    storage("local")?.setItem("mediaserver.webPlays", JSON.stringify([...state.ownPlays]));
    state.plays.set(item.id, (state.plays.get(item.id) || 0) + 1);
    changes.plays = [{ id: item.id, count: own }];
  }
  sync(changes);
}
function toggleFavorite(id) {
  const flag = { id, on: !isFavorite(id), at: Date.now() / 1000 };
  state.favorites.set(id, flag);
  sync({ favorites: [flag] });
  return flag.on;
}

async function progressOf(item) {
  if (state.progress.has(item.id)) return state.progress.get(item.id);
  const value = await json(`/v1/progress/${encodeURIComponent(item.id)}`).then((p) => p.seconds || 0).catch(() => 0);
  state.progress.set(item.id, value);
  return value;
}
/// Lädt Positionen mit höchstens sechs Anfragen gleichzeitig.
async function loadProgress(items) {
  const waiting = items.filter((item) => !state.progress.has(item.id));
  const workers = Array.from({ length: Math.min(6, waiting.length) }, async () => {
    while (waiting.length) await progressOf(waiting.shift());
  });
  await Promise.all(workers);
}

function lookup(list, field, transform = (v) => v) { return new Map((list || []).map((entry) => [transform(entry[field]), entry])); }

function group() {
  const covers = lookup(state.meta.covers, "directory");
  state.albumInfo = lookup(state.meta.albums, "key");
  state.seriesInfo = lookup(state.meta.series, "key");
  state.movieInfo = lookup(state.meta.movies, "key");
  state.artistInfo = lookup(state.meta.artists, "key", (k) => String(k || "").toLowerCase());
  state.episodeInfo = new Map();
  for (const series of state.meta.series || []) for (const e of series.episodes || []) state.episodeInfo.set(`${series.key}|${e.season}|${e.number}`, e);
  const thumbs = new Set(state.meta.thumbnails || []);
  const audio = state.items.filter((item) => item.kind === "audio");
  const video = state.items.filter((item) => item.kind === "video");

  const albums = new Map();
  for (const track of audio) {
    const key = track.album_key || `tag:${track.album || "Ohne Album"}\u001f${track.album_artist || track.artist || ""}`;
    if (!albums.has(key)) albums.set(key, { id: key, title: track.album || "Ohne Album", artist: track.album_artist || track.artist || "", tracks: [] });
    albums.get(key).tracks.push(track);
  }
  for (const album of albums.values()) {
    album.tracks.sort((a, b) => (a.disc_number || 1) - (b.disc_number || 1) || (a.track_number || 999) - (b.track_number || 999) || a.title.localeCompare(b.title, "de"));
    album.cover = album.tracks.find((t) => t.cover_id)?.cover_id || state.albumInfo.get(album.id)?.artwork || covers.get(album.id)?.artwork || null;
    album.added = Math.max(...album.tracks.map((t) => t.added || t.modified || 0));
    album.info = state.albumInfo.get(album.id);
    for (const track of album.tracks) { track.art = track.cover_id || album.cover; track.albumId = album.id; }
  }
  state.albums = [...albums.values()].sort((a, b) => b.added - a.added);
  state.songs = [...audio].sort((a, b) => a.title.localeCompare(b.title, "de"));
  state.artists = [...new Set(audio.map((t) => t.album_artist || t.artist).filter(Boolean))].sort((a, b) => a.localeCompare(b, "de"));

  const series = new Map();
  const movies = [];
  for (const item of video) {
    const parts = item.path.split("/");
    const root = parts.findIndex((p) => /^(serien|series|tv|tv shows)$/i.test(p));
    const key = item.series_key || (root >= 0 && parts.length > root + 2 ? parts.slice(0, root + 2).join("/") : null);
    item.still = thumbs.has(item.id) ? `thumb-${item.id}` : null;
    if (!key) {
      item.info = state.movieInfo.get(item.id);
      item.art = item.cover_id || item.info?.poster || item.still;
      movies.push(item);
      continue;
    }
    if (!series.has(key)) series.set(key, { id: key, name: key.split("/").pop(), seasons: new Map(), episodes: [] });
    const entry = series.get(key);
    const season = item.season_folder || (item.season != null ? `Staffel ${item.season}` : (root >= 0 && parts.length > root + 3 ? parts[root + 2] : "Folgen"));
    if (!entry.seasons.has(season)) entry.seasons.set(season, { title: seasonLabel(season), number: item.season ?? seasonNumber(season), episodes: [], cover: covers.get(`${key}/${season}`)?.artwork || null });
    entry.seasons.get(season).episodes.push(item);
    item.seriesId = key;
    item.art = item.cover_id || covers.get(`${key}/${season}`)?.artwork || covers.get(key)?.artwork || state.seriesInfo.get(key)?.poster || null;
    item.info = item.season != null && item.episode != null ? state.episodeInfo.get(`${key}|${item.season}|${item.episode}`) : null;
  }
  for (const entry of series.values()) {
    entry.list = [...entry.seasons.values()].sort((a, b) => (a.number ?? 999) - (b.number ?? 999) || a.title.localeCompare(b.title, "de"));
    for (const season of entry.list) season.episodes.sort((a, b) => (a.episode ?? 999) - (b.episode ?? 999) || a.path.localeCompare(b.path, "de", { numeric: true }));
    entry.episodes = entry.list.flatMap((s) => s.episodes);
    entry.info = state.seriesInfo.get(entry.id);
    entry.cover = covers.get(entry.id)?.artwork || entry.info?.poster || entry.episodes.find((e) => e.art)?.art || null;
    entry.added = Math.max(...entry.episodes.map((e) => e.added || e.modified || 0));
    entry.name = entry.info?.name || entry.name;
  }
  state.series = [...series.values()].sort((a, b) => a.name.localeCompare(b.name, "de"));
  state.seriesById = new Map(state.series.map((s) => [s.id, s]));
  state.movies = movies.sort((a, b) => (a.info?.title || a.title).localeCompare(b.info?.title || b.title, "de"));
}

function seasonLabel(title) { return title.replace(/^(season|staffel)\s*0*(\d+)$/i, "Staffel $2"); }
function seasonNumber(title) { const m = title.match(/(\d+)/); return m ? Number(m[1]) : null; }
function plain(value) { return String(value || "").replace(/<[^>]+>/g, "").replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'").trim(); }

// MARK: Weiterschauen

/// Je Serie die angefangene oder die nächste ungesehene Folge, je Film ein angefangener;
/// das zuletzt Gespielte zuerst.
async function continueWatching() {
  const candidates = [];
  for (const entry of state.series) {
    let last = null, lastAt = 0;
    for (const e of entry.episodes) { const at = state.lastPlayed.get(e.id) || 0; if (at > lastAt) { last = e; lastAt = at; } }
    if (!last) continue;
    candidates.push({ entry, last, at: lastAt });
  }
  for (const movie of state.movies) {
    const at = state.lastPlayed.get(movie.id);
    if (at && !isWatched(movie)) candidates.push({ movie, at });
  }
  candidates.sort((a, b) => b.at - a.at);
  const shown = candidates.slice(0, 24);
  await loadProgress(shown.map((c) => c.last || c.movie));
  const result = [];
  for (const c of shown) {
    if (c.movie) { if ((state.progress.get(c.movie.id) || 0) > 10) result.push({ item: c.movie, queue: [c.movie], series: "" }); continue; }
    const episodes = c.entry.episodes;
    let item = c.last;
    if (isWatched(item) || (state.progress.get(item.id) || 0) <= 10) {
      const start = episodes.indexOf(item);
      item = episodes.slice(start + (isWatched(item) ? 1 : 0)).find((e) => !isWatched(e));
    }
    if (item) result.push({ item, queue: episodes, series: c.entry.name });
  }
  await loadProgress(result.map((r) => r.item));
  return result.slice(0, 12);
}

// MARK: Bilder

const artObserver = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    artObserver.unobserve(entry.target);
    showArt(entry.target, entry.target.dataset.art);
  }
}, { rootMargin: "300px" });

async function artURL(id) {
  if (!id) return null;
  if (art.has(id)) return art.get(id);
  const promise = api(`/v1/artwork/${encodeURIComponent(id)}`).then((r) => r.blob()).then((b) => URL.createObjectURL(b)).catch(() => null);
  art.set(id, promise);
  const url = await promise;
  art.set(id, url);
  return url;
}
async function showArt(element, id) {
  const url = await artURL(id);
  if (!url) return;
  if (element.tagName === "IMG") element.src = url; else { element.style.backgroundImage = `url("${url}")`; element.classList.add("loaded"); }
}
function cover(id, className, symbol = "♪") {
  const element = document.createElement("div");
  element.className = `cover ${className || ""}`;
  element.setAttribute("aria-hidden", "true");
  element.dataset.symbol = symbol;
  if (id) { element.dataset.art = id; artObserver.observe(element); }
  return element;
}

// MARK: Bausteine

function el(tag, className, ...children) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  element.append(...children.filter((c) => c != null && c !== false));
  return element;
}
function text(tag, content, className) { const element = document.createElement(tag); element.textContent = content; if (className) element.className = className; return element; }
function link(href, content, className) { const a = text("a", content, className); a.href = href; return a; }
function button(label, className, action, aria) {
  const b = text("button", label, className); b.type = "button"; b.addEventListener("click", action);
  if (aria) b.setAttribute("aria-label", aria);
  return b;
}
function clock(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const s = Math.floor(seconds), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = String(s % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${r}` : `${m}:${r}`;
}
function minutes(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return "";
  const m = Math.round(seconds / 60);
  return m >= 60 ? `${Math.floor(m / 60)} Std. ${m % 60} Min.` : `${Math.max(1, m)} Min.`;
}
function day(value) {
  const date = value ? new Date(value) : null;
  return date && !Number.isNaN(date.getTime()) ? date.toLocaleDateString("de-DE", { day: "numeric", month: "short", year: "numeric" }) : "";
}
function matches(query, ...fields) { return !query || fields.some((f) => f && String(f).toLocaleLowerCase("de").includes(query)); }
function query() { return $("suche").value.trim().toLocaleLowerCase("de"); }
function bar(share) {
  const outer = el("div", "progress");
  const inner = el("span"); inner.style.width = `${Math.round(Math.min(1, Math.max(0, share)) * 100)}%`;
  outer.append(inner);
  outer.setAttribute("role", "progressbar"); outer.setAttribute("aria-valuenow", String(Math.round(share * 100)));
  outer.setAttribute("aria-valuemin", "0"); outer.setAttribute("aria-valuemax", "100"); outer.setAttribute("aria-label", "Bereits geschaut");
  return outer;
}

function card(href, artId, title, subtitle, options = {}) {
  const a = el("a", `card${options.wide ? " wide" : ""}${options.round ? " round" : ""}`);
  a.href = href;
  const picture = cover(artId, "", options.symbol);
  if (options.share != null) picture.append(bar(options.share));
  if (options.watched) picture.append(badge());
  a.append(picture, text("strong", title), text("span", subtitle || ""));
  if (options.onClick) a.addEventListener("click", (event) => { event.preventDefault(); options.onClick(); });
  return a;
}
function shelf(title, cards, moreHref) {
  if (!cards.length) return null;
  const head = el("div", "shelf-head", text("h3", title), moreHref ? link(moreHref, "Alle anzeigen", "more") : null);
  return el("section", "shelf", head, el("div", "row", ...cards));
}
function trackList(tracks, { numbered = false, covers = false, extra = null, queueFor = null } = {}) {
  const list = el("ul", "tracks");
  tracks.forEach((track, index) => {
    const b = el("button", `track${covers ? " with-cover" : ""}`);
    b.type = "button"; b.dataset.id = track.id;
    b.append(covers ? cover(track.art, "small") : text("span", numbered ? String(track.track_number || index + 1) : String(index + 1), "num"));
    b.append(el("div", "", text("strong", track.title), text("span", [track.artist, covers ? track.album : null].filter(Boolean).join(" · "))), text("span", clock(track.duration), "time"));
    b.addEventListener("click", () => queueFor ? playAudio(queueFor(track), 0) : playAudio(tracks, index));
    list.append(el("li", "", b, moreButton(track.title, (anchor) => showMenu(anchor, [...trackActions(track), ...(extra ? [null, ...extra(track, index)] : [])]))));
  });
  return list;
}
/// Der „…“-Knopf rechts in einer Zeile, wie MediaActionsMenu in der App.
function moreButton(title, open) {
  const b = el("button", "row-more", icon("more"));
  b.type = "button"; b.setAttribute("aria-label", `Aktionen für ${title}`); b.setAttribute("aria-haspopup", "menu");
  b.addEventListener("click", (event) => { event.stopPropagation(); open(b); });
  return b;
}
function trackActions(track) {
  const favorite = isFavorite(track.id);
  const artist = track.album_artist || track.artist;
  return [
    [favorite ? "Aus Lieblingssongs entfernen" : "Zu Lieblingssongs", favorite ? "heartSlash" : "heartOutline", () => { toggleFavorite(track.id); updateHeart(); toast(favorite ? "Aus Lieblingssongs entfernt" : "Zu Lieblingssongs hinzugefügt"); }],
    ["Als Nächstes spielen", "playNext", () => playNext(track)],
    ["Ans Ende der Warteschlange", "playLast", () => addToQueue(track)],
    null,
    track.albumId ? ["Zum Album", "album", () => { location.hash = `#musik/album/${encodeURIComponent(track.albumId)}`; }] : null,
    artist ? ["Zum Interpreten", "person", () => { location.hash = `#musik/interpret/${encodeURIComponent(artist)}`; }] : null,
    null,
    ["Zur Playlist hinzufügen …", "playlistAdd", (anchor) => choosePlaylist(anchor, [track])],
    ["Infos", "info", () => showInfo(track)],
    ["Herunterladen", "download", () => downloadFile(track)],
    ...deleteEntry([track], track.title),
  ];
}
/// „Vom Server löschen“ nur, wenn der Server es erlaubt (MINIPLY_DELETES).
function deleteEntry(items, name, after) {
  return state.storage?.deletes ? [null, ["Vom Server löschen", "trash", () => deleteFromServer(items, name, after)]] : [];
}
function albumActions(album) {
  const favorite = isFavoriteAlbum(album);
  return [
    [favorite ? "Kein Lieblingsalbum mehr" : "Lieblingsalbum", favorite ? "heartSlash" : "heartOutline", () => toggleAlbumFavorite(album)],
    ["Abspielen", "play", () => playAudio(album.tracks, 0)],
    ["Zufällig", "shuffle", () => playAudio(shuffled(album.tracks), 0)],
    ["Als Nächstes spielen", "playNext", () => playNext(...album.tracks)],
    ["Ans Ende der Warteschlange", "playLast", () => addToQueue(...album.tracks)],
    ["Zur Playlist hinzufügen …", "playlistAdd", (anchor) => choosePlaylist(anchor, album.tracks)],
    ...deleteEntry(album.tracks, album.title, () => { location.hash = "#musik/alben"; }),
  ];
}
function toggleAlbumFavorite(album) {
  const on = toggleFavorite(state.albumFavorite.get(album.id));
  toast(on ? "Als Lieblingsalbum markiert" : "Kein Lieblingsalbum mehr");
  render();
}

// MARK: Menü und Hinweise

let openMenu = null;
/// Ein Kontextmenü wie unter iOS: abgerundet, unscharf hinterlegt, neben dem Knopf.
function showMenu(anchor, entries, at) {
  closeMenu();
  const menu = el("div", "menu");
  menu.setAttribute("role", "menu");
  let lastWasLine = true;
  for (const entry of entries) {
    if (entry === undefined) continue;
    if (entry === null) { if (!lastWasLine) { menu.append(el("hr")); lastWasLine = true; } continue; }
    const [label, iconName, action] = entry;
    const item = el("button", "", text("span", label), icon(iconName));
    item.type = "button"; item.setAttribute("role", "menuitem");
    item.addEventListener("click", () => { closeMenu(); action(anchor?.isConnected ? anchor : null); });
    menu.append(item); lastWasLine = false;
  }
  if (menu.lastChild?.tagName === "HR") menu.lastChild.remove();
  document.body.append(menu);
  const box = at || anchor.getBoundingClientRect();
  const width = menu.offsetWidth, height = menu.offsetHeight;
  const left = Math.min(Math.max(8, (at ? box.x : box.right) - (at ? 0 : width)), innerWidth - width - 8);
  const below = (at ? box.y : box.bottom) + 4;
  menu.style.left = `${left}px`;
  menu.style.top = `${below + height > innerHeight - 8 ? Math.max(8, (at ? box.y : box.top) - height - 4) : below}px`;
  openMenu = { menu, anchor };
  menu.querySelector("button")?.focus({ preventScroll: true });
}
function closeMenu() {
  if (!openMenu) return;
  const { menu, anchor } = openMenu;
  openMenu = null;
  menu.remove();
  if (anchor?.isConnected && menu.contains(document.activeElement)) anchor.focus({ preventScroll: true });
}
let toastTimer;
function toast(message) {
  let box = $("hinweis");
  if (!box) { box = el("div", "toast"); box.id = "hinweis"; box.setAttribute("role", "status"); document.body.append(box); }
  box.textContent = message;
  box.classList.add("shown");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => box.classList.remove("shown"), 2200);
}
function markPlaying() {
  for (const node of document.querySelectorAll(".track")) node.classList.toggle("playing", node.dataset.id === player.queue[player.index]?.id);
}
function emptyNote(message) { return text("p", message, "empty"); }

// MARK: Symbole

const SVG = "http://www.w3.org/2000/svg";
const ICONS = {
  check: [["path", { d: "m5 12.5 4.5 4.5L19 7.5" }]],
  circle: [["circle", { cx: "12", cy: "12", r: "9" }]],
  checkCircle: [["circle", { cx: "12", cy: "12", r: "9", class: "fill" }], ["path", { d: "m7.5 12.3 3 3 6-6.3", stroke: "#002624", "stroke-width": "2.4" }]],
  back: [["path", { d: "m15 5-7 7 7 7" }]],
  play: [["path", { d: "M8 5v14l11-7z", class: "fill" }]],
  shuffle: [["path", { d: "M3 7h3.5c4 0 6 10 10 10H21M3 17h3.5c1.6 0 2.8-1.6 3.9-3.6M14.1 9.6C15 8 16 7 17.5 7H21M18 4l3 3-3 3M18 14l3 3-3 3" }]],
  heart: [["path", { d: "M12 20s-7.5-4.6-9.2-9.4C1.6 7.2 3.8 4 7.2 4c2 0 3.6 1.1 4.8 2.8C13.2 5.1 14.8 4 16.8 4c3.4 0 5.6 3.2 4.4 6.6C19.5 15.4 12 20 12 20z", class: "fill" }]],
  chart: [["path", { d: "M5 20V11M12 20V5M19 20v-7" }]],
  clock: [["circle", { cx: "12", cy: "12", r: "8.5" }], ["path", { d: "M12 7.5V12l3 2" }]],
  more: [["circle", { cx: "5.5", cy: "12", r: "1.6", class: "fill" }], ["circle", { cx: "12", cy: "12", r: "1.6", class: "fill" }], ["circle", { cx: "18.5", cy: "12", r: "1.6", class: "fill" }]],
  heartOutline: [["path", { d: "M12 20s-7.5-4.6-9.2-9.4C1.6 7.2 3.8 4 7.2 4c2 0 3.6 1.1 4.8 2.8C13.2 5.1 14.8 4 16.8 4c3.4 0 5.6 3.2 4.4 6.6C19.5 15.4 12 20 12 20z" }]],
  heartSlash: [["path", { d: "M12 20s-7.5-4.6-9.2-9.4C1.6 7.2 3.8 4 7.2 4c2 0 3.6 1.1 4.8 2.8C13.2 5.1 14.8 4 16.8 4c3.4 0 5.6 3.2 4.4 6.6C19.5 15.4 12 20 12 20z" }], ["path", { d: "M3 3l18 18" }]],
  playNext: [["path", { d: "M4 6h10M4 11h7M4 16h7" }], ["path", { d: "M15 10v8l6-4z", class: "fill" }]],
  playLast: [["path", { d: "M4 6h10M4 11h10M4 16h5" }], ["path", { d: "M15 14v8l6-4z", class: "fill" }]],
  album: [["rect", { x: "3.5", y: "3.5", width: "17", height: "17", rx: "3" }], ["circle", { cx: "12", cy: "12", r: "3.5" }]],
  person: [["circle", { cx: "12", cy: "8", r: "4" }], ["path", { d: "M4.5 20.5c1.2-3.6 4-5.5 7.5-5.5s6.3 1.9 7.5 5.5" }]],
  sort: [["path", { d: "M7 4v16M3.5 7.5 7 4l3.5 3.5M17 20V4M13.5 16.5 17 20l3.5-3.5" }]],
  eyeSlash: [["path", { d: "M2.5 12s3.5-6.5 9.5-6.5 9.5 6.5 9.5 6.5-3.5 6.5-9.5 6.5S2.5 12 2.5 12z" }], ["circle", { cx: "12", cy: "12", r: "3" }], ["path", { d: "M4 4l16 16" }]],
  checkCircleOutline: [["circle", { cx: "12", cy: "12", r: "9" }], ["path", { d: "m7.5 12.3 3 3 6-6.3" }]],
  playlistAdd: [["path", { d: "M4 6h12M4 11h12M4 16h7M18 13v8M14 17h8" }]],
  info: [["circle", { cx: "12", cy: "12", r: "9" }], ["path", { d: "M12 11v6M12 7.5v.5" }]],
  download: [["path", { d: "M12 4v11M7 10.5l5 5 5-5M5 20h14" }]],
  trash: [["path", { d: "M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3" }]],
  pencil: [["path", { d: "M4 20h4L19 9l-4-4L4 16zM13.5 6.5l4 4" }]],
  minus: [["circle", { cx: "12", cy: "12", r: "9" }], ["path", { d: "M8 12h8" }]],
  plus: [["path", { d: "M12 5v14M5 12h14" }]],
  folder: [["path", { d: "M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" }]],
  note: [["path", { d: "M9 18V6l10-2v12" }], ["circle", { cx: "6.5", cy: "18", r: "2.5" }], ["circle", { cx: "16.5", cy: "16", r: "2.5" }]],
  film: [["rect", { x: "3", y: "5", width: "18", height: "14", rx: "2" }], ["path", { d: "M7 5v14M17 5v14M3 9.5h4M3 14.5h4M17 9.5h4M17 14.5h4" }]],
  doc: [["path", { d: "M6 3h8l4 4v14H6zM14 3v4h4" }]],
  moon: [["path", { d: "M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z" }]],
  close: [["path", { d: "M6 6l12 12M18 6 6 18" }]],
  chevron: [["path", { d: "m9 5 7 7-7 7" }]],
  sparkle: [["path", { d: "M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5 18 18M6 18l2.5-2.5M15.5 8.5 18 6" }]],
};
function icon(name) {
  const svg = document.createElementNS(SVG, "svg");
  svg.setAttribute("viewBox", "0 0 24 24"); svg.setAttribute("aria-hidden", "true");
  for (const [tag, attributes] of ICONS[name]) {
    const shape = document.createElementNS(SVG, tag);
    for (const [key, value] of Object.entries(attributes)) shape.setAttribute(key, value);
    svg.append(shape);
  }
  return svg;
}
function badge() { const span = el("span", "badge"); span.append(icon("check")); return span; }
function iconButton(iconName, label, className, action) {
  const b = el("button", className); b.type = "button"; b.append(icon(iconName), text("span", label));
  b.addEventListener("click", action);
  return b;
}

// MARK: Ansichten

function pageTitle(value) { return text("h1", value, "large-title"); }
function segmented(label, entries, current, scroll = false) {
  const nav = el("nav", `segmented${scroll ? " scroll" : ""}`);
  nav.setAttribute("aria-label", label);
  for (const [href, title, key] of entries) {
    const a = link(href, title);
    if (key === current) a.setAttribute("aria-current", "page");
    nav.append(a);
  }
  return nav;
}
function backLink(href, label) { const a = el("a", "back"); a.href = href; a.append(icon("back"), text("span", label)); return a; }
/// Das unscharfe Cover hinter dem Kopf einer Detailseite, wie ArtworkBackdrop in der App.
function backdrop(artId) {
  const layer = el("div", "backdrop");
  layer.setAttribute("aria-hidden", "true");
  if (artId) artURL(artId).then((url) => { if (url) layer.style.setProperty("--art", `url("${url}")`); });
  return layer;
}
function hero({ art, shape = "", symbol = "♪", title, accent, meta, share, actions }) {
  const picture = cover(art, shape, symbol);
  const actionRow = actions?.length ? el("div", `actions${actions.length === 1 ? " single" : ""}`, ...actions) : null;
  return el("div", "hero", picture,
    el("div", "hero-text", text("h2", title), accent ? (typeof accent === "string" ? text("p", accent, "accent") : accent) : null, meta ? text("p", meta, "muted") : null,
      share != null ? Object.assign(bar(share), { className: "progress inline" }) : null, actionRow));
}

const views = {
  start() {
    const holder = el("div", "", text("p", "Lädt …", "muted"));
    continueWatching().then((list) => {
      const music = collectionsToHear(4);
      const parts = [];
      if (list.length) parts.push(text("h3", "Weiterschauen"), el("div", "home-field", ...list.slice(0, 4).map(continueCard)));
      if (music.length) parts.push(text("h3", "Oft und zuletzt gehört"), el("div", "home-field", ...music.map(musicTile)));
      if (!parts.length) parts.push(emptyNote(state.items.length ? "Hier erscheinen deine zuletzt geschauten Videos und deine meistgehörte Musik." : "Kopiere Musik, Filme und Serien auf deinen Server. Sie erscheinen hier automatisch."));
      holder.replaceChildren(...parts);
    });
    return [pageTitle(greeting()), holder];
  },
  musik(sub, id) {
    if (sub === "album") return albumView(id);
    if (sub === "interpret") return artistView(id);
    if (sub === "playlist") return playlistView(id);
    if (sub === "finden") return finderView(id);
    const parts = [el("div", "title-row", pageTitle("Musik"), link("#musik/finden", "Musik finden", "secondary small")),
      segmented("Musik", [["#musik/titel", "Titel", "titel"], ["#musik/alben", "Alben", "alben"], ["#musik/interpreten", "Interpreten", "interpreten"], ["#musik/playlists", "Playlists", "playlists"]], sub)];
    if (sub === "titel") parts.push(state.songs.length ? trackList(state.songs, { covers: true }) : emptyNote("Noch keine Titel."));
    else if (sub === "interpreten") parts.push(state.artists.length ? el("div", "grid", ...state.artists.map(artistCard)) : emptyNote("Noch keine Interpreten."));
    else if (sub === "playlists") parts.push(el("div", "tools", button("Neue Playlist", "secondary", () => newPlaylist())), el("div", "grid", ...allPlaylists().map(playlistCard)));
    else {
      const favorites = state.albums.filter(isFavoriteAlbum);
      if (favorites.length) {
        parts.push(text("h3", "Lieblingsalben"), el("div", "grid", ...favorites.map((a) => albumCard(a))), text("h3", "Weitere Alben"),
          el("div", "grid", ...state.albums.filter((a) => !isFavoriteAlbum(a)).map((a) => albumCard(a))));
      } else parts.push(state.albums.length ? el("div", "grid", ...state.albums.map((a) => albumCard(a))) : emptyNote("Kopiere einen Ordner pro Album in „Musik“."));
    }
    return parts;
  },
  videos(sub) {
    const kind = sub === "serien" ? "serien" : "filme";
    const holder = el("div");
    continueWatching().then((list) => { if (list.length) holder.replaceChildren(shelf("Weiterschauen", list.map((entry) => continueCard(entry, true)))); });
    const parts = [pageTitle("Videos"), segmented("Videos", [["#videos/filme", "Filme & Videos", "filme"], ["#videos/serien", "Serien", "serien"]], kind), holder];
    if (kind === "filme") parts.push(state.movies.length ? el("div", "grid posters", ...state.movies.map(movieCard)) : emptyNote("Filme und Videos erscheinen nach dem Kopieren auf den Server."));
    else parts.push(state.series.length ? el("div", "grid posters", ...state.series.map(seriesCard)) : emptyNote("Lege Folgen unter Serien/Serienname/Season 1/ ab."));
    return parts;
  },
  filme() { return views.videos("filme"); },
  serien(sub, id) { return !sub ? views.videos("serien") : id != null ? seasonView(sub, id) : seriesView(sub); },
  einstellungen() {
    const row = (label, value) => el("li", "", text("span", label), text("span", value, "muted"));
    const linkRow = (href, label) => { const a = link(href, label); a.append(icon("chevron")); return el("li", "link-row", a); };
    const disk = state.storage;
    const status = el("ul", "settings-list settings-group", row("Zustand", "wird geladen …"));
    json("/v1/status").then((info) => {
      const rows = [row("Läuft seit", info.uptime_seconds != null ? duration(info.uptime_seconds) : "–")];
      if (info.load != null) rows.push(row("Last", Array.isArray(info.load) ? info.load.map((n) => Number(n).toFixed(2)).join(" · ") : String(info.load)));
      if (info.memory_total_bytes) rows.push(row("Arbeitsspeicher frei", `${bytes(info.memory_available_bytes)} von ${bytes(info.memory_total_bytes)}`));
      if (info.temperature_c != null) rows.push(row("Temperatur", `${Number(info.temperature_c).toFixed(1)} °C`));
      if (info.music_service_seconds_ago != null) rows.push(row("Musik-Dienst", info.music_service_seconds_ago < 300 ? "läuft" : `zuletzt vor ${duration(info.music_service_seconds_ago)}`));
      status.replaceChildren(...rows);
    }).catch(() => status.replaceChildren(row("Zustand", "nicht verfügbar")));
    const rescanButton = button("Bibliothek neu einlesen", "plain-button", async () => {
      rescanButton.disabled = true; rescanButton.textContent = "Wird eingelesen …";
      try { await api("/v1/scan", { method: "POST" }); await loadLibrary(); toast("Bibliothek ist aktuell"); render(); }
      catch (error) { toast(`Einlesen fehlgeschlagen: ${error.message}`); rescanButton.disabled = false; rescanButton.textContent = "Bibliothek neu einlesen"; }
    });
    const signOutButton = button("Abmelden", "danger", signOut);
    const normalize = el("input"); normalize.type = "checkbox"; normalize.checked = setting("normalize", "1") === "1";
    normalize.addEventListener("change", () => { setSetting("normalize", normalize.checked ? "1" : "0"); applyVolume(); });
    const subtitles = el("select", "", ...[["off", "Aus"], ["de", "Deutsch"], ["en", "Englisch"], ["auto", "Erste verfügbare"]].map(([value, label]) => {
      const option = text("option", label); option.value = value; return option;
    }));
    subtitles.value = setting("subtitles", "off");
    subtitles.addEventListener("change", () => setSetting("subtitles", subtitles.value));
    const label = (title, control) => { const l = el("label", "", text("span", title), control); return el("li", "control-row", l); };
    const seen = state.series.reduce((sum, s) => sum + s.episodes.filter(isWatched).length, 0) + state.movies.filter(isWatched).length;
    return [pageTitle("Einstellungen"),
      text("p", "Verbindung", "settings-head"),
      el("ul", "settings-list settings-group", row("Server", location.host), el("li", "", rescanButton), el("li", "", signOutButton)),
      text("p", "Das Token liegt nur in diesem Browser. „Abmelden“ löscht es hier, die App bleibt verbunden.", "settings-caption"),
      text("p", "Serverzustand", "settings-head"), status,
      disk ? text("p", "SSD am Server", "settings-head") : null,
      disk ? el("ul", "settings-list settings-group", row("Verfügbar", bytes(disk.available_bytes)), row("Gesamt", bytes(disk.total_bytes)),
        row("Indexiert", `${disk.file_count} Dateien · ${bytes(disk.indexed_bytes)}`)) : null,
      text("p", "Bibliothek", "settings-head"),
      el("ul", "settings-list settings-group", linkRow("#musik/finden", "Musik finden"), linkRow("#hochladen", "Hochladen"), linkRow("#dateien", "SSD durchsuchen"),
        row("Titel · Alben", `${state.songs.length} · ${state.albums.length}`), row("Serien · Filme", `${state.series.length} · ${state.movies.length}`), row("Gesehen", `${seen} Folgen und Filme`)),
      text("p", "Wiedergabe", "settings-head"),
      el("ul", "settings-list settings-group", label("Lautstärke angleichen", normalize), label("Untertitel", subtitles)),
      text("p", "Gleicht unterschiedlich laute Songs an. Untertitel gibt es, wenn neben dem Video eine .srt-Datei liegt.", "settings-caption"),
      text("p", "Tastatur", "settings-head"),
      el("ul", "settings-list settings-group", row("Abspielen / Pause", "Leertaste"), row("Nächster / vorheriger Titel", "⌘ → / ⌘ ←"), row("Suchen", "/"))];
  },
  hochladen() { return uploadView(); },
  dateien(sub) { return filesView(sub ? decodeURIComponent(sub) : ""); },
  suche() {
    const q = query();
    const albums = state.albums.filter((a) => matches(q, a.title, a.artist));
    const songs = state.songs.filter((t) => matches(q, t.title, t.artist, t.album)).slice(0, 50);
    const artists = state.artists.filter((n) => matches(q, n));
    const series = state.series.filter((s) => matches(q, s.name));
    const episodes = state.series.flatMap((s) => s.episodes.filter((e) => matches(q, e.title, e.info?.name)).map((e) => ({ e, s }))).slice(0, 30);
    const movies = state.movies.filter((m) => matches(q, m.title, m.info?.title));
    const parts = [pageTitle("Suche")];
    if (artists.length) parts.push(shelf("Interpreten", artists.slice(0, 20).map(artistCard)));
    if (albums.length) parts.push(shelf("Alben", albums.slice(0, 30).map((a) => albumCard(a))));
    // Wie in der App: Ein gefundener Song spielt mit ähnlichen weiter, nicht mit den anderen Treffern.
    if (songs.length) parts.push(text("h3", "Titel"), trackList(songs, { covers: true, queueFor: similarQueue }));
    if (series.length) parts.push(shelf("Serien", series.map(seriesCard)));
    if (episodes.length) parts.push(text("h3", "Folgen"), el("ul", "episodes", ...episodes.map(({ e, s }) => episodeRow(e, s, s.episodes))));
    if (movies.length) parts.push(shelf("Filme", movies.map(movieCard)));
    if (parts.length === 1) parts.push(emptyNote(`Keine Treffer für „${$("suche").value.trim()}“.`));
    return parts;
  },
};

function continueCard({ item, queue, series }, inRow = false) {
  const p = state.progress.get(item.id) || 0;
  const a = el("a", inRow ? "card wide continue" : "continue");
  a.href = "#start";
  const picture = cover(item.still || item.art, "", "▶");
  const capsule = el("div", "capsule", el("span")); capsule.firstChild.style.width = `${item.duration ? Math.min(100, (p / item.duration) * 100) : 30}%`;
  picture.append(el("span", "shade"), el("span", "play-badge", icon("play")), capsule);
  const left = p > 10 && item.duration ? `noch ${minutes(item.duration - p)}` : minutes(item.duration);
  a.append(picture, text("strong", series || item.info?.title || item.title),
    text("span", (series ? [episodeCode(item), episodeTitle(item, series)].filter(Boolean).join(" · ") : left) || "\u00a0"));
  a.addEventListener("click", (event) => { event.preventDefault(); playVideo(queue, queue.indexOf(item), series); });
  return a;
}

/// Wie in der App: zuletzt gehörte Alben, danach die meistgehörten.
function collectionsToHear(limit) {
  const last = (album) => Math.max(0, ...album.tracks.map((t) => state.lastPlayed.get(t.id) || 0));
  const heard = (album) => album.tracks.reduce((sum, t) => sum + (state.plays.get(t.id) || 0), 0);
  const recent = state.albums.filter((a) => last(a) > 0).sort((a, b) => last(b) - last(a));
  const most = state.albums.filter((a) => heard(a) > 0 && !recent.includes(a)).sort((a, b) => heard(b) - heard(a));
  return [...recent, ...most].slice(0, limit);
}
function musicTile(album) {
  const a = el("a", "tile");
  a.href = `#musik/album/${encodeURIComponent(album.id)}`;
  a.append(cover(album.cover), el("span", "", text("strong", album.title), text("small", album.artist || "Album")));
  return a;
}

const AUTO_PLAYLISTS = {
  lieblingssongs: { name: "Lieblingssongs", icon: "heart", colors: ["#ff6b8b", "#c2185b"],
    tracks: () => state.songs.filter((t) => isFavorite(t.id)) },
  meistgehoert: { name: "Meistgehört", icon: "chart", colors: ["#66d4cf", "#1f7a8c"],
    tracks: () => state.songs.filter((t) => state.plays.get(t.id)).sort((a, b) => state.plays.get(b.id) - state.plays.get(a.id)).slice(0, 100) },
  zuletzt: { name: "Zuletzt gespielt", icon: "clock", colors: ["#ffb347", "#d9534f"],
    tracks: () => state.songs.filter((t) => state.lastPlayed.get(t.id)).sort((a, b) => state.lastPlayed.get(b.id) - state.lastPlayed.get(a.id)).slice(0, 100) },
  wieder: { name: "Lange nicht gehört", icon: "clock", colors: ["#5bc0eb", "#2d6a8f"],
    tracks: () => { const limit = Date.now() / 1000 - 30 * 86400; return state.songs.filter((t) => (state.plays.get(t.id) || 0) >= 3 && (state.lastPlayed.get(t.id) || 0) < limit).sort((a, b) => state.plays.get(b.id) - state.plays.get(a.id)).slice(0, 100); } },
  neu: { name: "Neu hinzugefügt", icon: "sparkle", colors: ["#8e7dff", "#4a3fb5"],
    tracks: () => [...state.songs].sort((a, b) => (b.added || b.modified) - (a.added || a.modified)).slice(0, 100) },
};
function allPlaylists() {
  const auto = Object.entries(AUTO_PLAYLISTS).map(([key, list]) => ({ id: `auto:${key}`, name: list.name, auto: list, tracks: list.tracks() }));
  const own = state.playlists.map((list) => ({ id: list.id, name: list.name, tracks: (list.media_ids || []).map((id) => state.byId.get(id)).filter(Boolean) }));
  return [...auto, ...own];
}
function mosaic(list) {
  if (list.auto) {
    const box = el("div", "cover mosaic auto");
    box.style.setProperty("--from", list.auto.colors[0]); box.style.setProperty("--to", list.auto.colors[1]);
    box.append(icon(list.auto.icon));
    return box;
  }
  const covers = [...new Set(list.tracks.map((t) => t.art).filter(Boolean))].slice(0, 4);
  if (covers.length < 4) return cover(covers[0], "", "♪");
  return el("div", "cover mosaic", ...covers.map((id) => cover(id)));
}
function playlistCard(list) {
  const a = el("a", "card");
  a.href = `#musik/playlist/${encodeURIComponent(list.id)}`;
  a.append(mosaic(list), text("strong", list.name), text("span", `${list.tracks.length} Titel`));
  return a;
}
function playlistView(id) {
  const list = allPlaylists().find((entry) => entry.id === id);
  if (!list) return [emptyNote("Playlist nicht gefunden.")];
  const picture = mosaic(list); picture.classList.add("hero-mosaic");
  const total = list.tracks.reduce((sum, t) => sum + (t.duration || 0), 0);
  const head = hero({ art: null, title: list.name, accent: list.auto ? "Automatische Playlist" : "Playlist", meta: [`${list.tracks.length} Titel`, minutes(total)].filter(Boolean).join(" · "),
    actions: list.tracks.length ? [playButton("Abspielen", () => playAudio(list.tracks, 0)), shuffleButton(() => playAudio(shuffled(list.tracks), 0))] : [] });
  head.firstChild.replaceWith(picture);
  const own = state.playlists.find((entry) => entry.id === id);
  const buttons = [];
  if (own) {
    const more = el("button", "round-button", icon("more"));
    more.type = "button"; more.setAttribute("aria-label", "Playlistaktionen"); more.setAttribute("aria-haspopup", "menu");
    more.addEventListener("click", () => showMenu(more, [
      ["Umbenennen", "pencil", () => { const name = prompt("Neuer Name der Playlist", own.name)?.trim(); if (name) savePlaylist(own, { name }); }],
      ["Als Nächstes spielen", "playNext", () => playNext(...list.tracks)],
      ["Playlist löschen", "trash", () => removePlaylist(own)],
    ]));
    buttons.push(more);
  }
  const extra = own ? (track, index) => [["Aus Playlist entfernen", "minus", () => {
    const ids = [...own.media_ids]; const at = ids.indexOf(track.id, index > -1 ? index : 0);
    ids.splice(at >= 0 ? at : ids.indexOf(track.id), 1);
    savePlaylist(own, { media_ids: ids }).then(() => toast(`„${track.title}“ entfernt`));
  }]] : null;
  return [backdrop(list.tracks.find((t) => t.art)?.art), navBar("#musik/playlists", "Playlists", ...buttons), head,
    list.tracks.length ? trackList(list.tracks, { covers: true, extra }) : emptyNote(list.auto === AUTO_PLAYLISTS.lieblingssongs ? "Markiere Songs im großen Player mit dem Herz." : own ? "Noch leer. Füge Titel über „…“ → „Zur Playlist hinzufügen“ hinzu." : "Noch leer.")];
}

// MARK: Playlists bearbeiten

async function createPlaylist(name, tracks = []) {
  const saved = await (await send("/v1/playlists", "POST", { name, media_ids: tracks.map((t) => t.id) })).json();
  state.playlists.push(saved);
  return saved;
}
async function savePlaylist(list, changes) {
  try {
    const saved = await (await send(`/v1/playlists/${encodeURIComponent(list.id)}`, "PUT",
      { name: changes.name ?? list.name, media_ids: changes.media_ids ?? list.media_ids })).json();
    Object.assign(list, saved);
    render();
  } catch (error) { toast(`Konnte die Playlist nicht speichern: ${error.message}`); }
}
async function removePlaylist(list) {
  if (!confirm(`Playlist „${list.name}“ löschen? Die Titel selbst bleiben erhalten.`)) return;
  try {
    await api(`/v1/playlists/${encodeURIComponent(list.id)}`, { method: "DELETE" });
    state.playlists = state.playlists.filter((entry) => entry !== list);
    location.hash = "#musik/playlists";
    toast("Playlist gelöscht");
  } catch (error) { toast(`Konnte die Playlist nicht löschen: ${error.message}`); }
}
async function newPlaylist(tracks = []) {
  const name = prompt("Name der neuen Playlist")?.trim();
  if (!name) return;
  try {
    const saved = await createPlaylist(name, tracks);
    toast(tracks.length ? `${tracks.length === 1 ? `„${tracks[0].title}“` : `${tracks.length} Titel`} in „${saved.name}“` : `„${saved.name}“ angelegt`);
    render();
  } catch (error) { toast(`Konnte die Playlist nicht anlegen: ${error.message}`); }
}
function choosePlaylist(anchor, tracks) {
  const entries = state.playlists.map((list) => [list.name, "playlistAdd", () => {
    savePlaylist(list, { media_ids: [...list.media_ids, ...tracks.map((t) => t.id)] })
      .then(() => toast(`${tracks.length === 1 ? `„${tracks[0].title}“` : `${tracks.length} Titel`} in „${list.name}“`));
  }]);
  entries.push(null, ["Neue Playlist …", "plus", () => newPlaylist(tracks)]);
  showMenu(anchor || document.body, entries, anchor ? undefined : { x: innerWidth / 2 - 120, y: innerHeight / 3 });
}

function bytes(value) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let n = value, i = 0;
  while (n >= 1000 && i < units.length - 1) { n /= 1000; i++; }
  return `${n.toLocaleString("de-DE", { maximumFractionDigits: n < 10 ? 1 : 0 })} ${units[i]}`;
}
function greeting() {
  const hour = new Date().getHours();
  return hour >= 5 && hour < 11 ? "Guten Morgen" : hour >= 11 && hour < 17 ? "Hallo" : hour >= 17 && hour < 22 ? "Guten Abend" : "Gute Nacht";
}
function seriesSummary(s) {
  const seasons = `${s.list.length} ${s.list.length === 1 ? "Staffel" : "Staffeln"}`;
  const seen = s.episodes.filter(isWatched).length;
  return seen ? `${seen} von ${s.episodes.length} gesehen` : `${seasons} · ${s.episodes.length} Folgen`;
}
function albumCard(a, subtitle = a.artist || `${a.tracks.length} Titel`) {
  const c = card(`#musik/album/${encodeURIComponent(a.id)}`, a.cover, a.title, subtitle);
  c.addEventListener("contextmenu", (event) => { event.preventDefault(); showMenu(c, albumActions(a), { x: event.clientX, y: event.clientY }); });
  return c;
}
function seriesCard(s) {
  const seen = s.episodes.filter(isWatched).length;
  return card(`#serien/${encodeURIComponent(s.id)}`, s.cover, s.name, seriesSummary(s), { symbol: "▶", share: seen && seen < s.episodes.length ? seen / s.episodes.length : null, watched: seen === s.episodes.length });
}
function movieCard(movie) {
  const p = state.progress.get(movie.id) || 0;
  return card("#videos/filme", movie.art, movie.info?.title || movie.title, [movie.info?.year, minutes(movie.duration)].filter(Boolean).join(" · "),
    { symbol: "▶", watched: isWatched(movie), share: p > 10 && movie.duration ? p / movie.duration : null, onClick: () => movieView(movie) });
}
function artistCard(name) {
  const info = state.artistInfo.get(name.toLowerCase());
  const first = state.albums.find((a) => a.artist === name);
  return card(`#musik/interpret/${encodeURIComponent(name)}`, info?.image || first?.cover, name, "", { round: true, symbol: "♪" });
}
function episodeCode(item) { return item.season != null && item.episode != null ? `S${item.season} F${item.episode}` : ""; }
function episodeTitle(episode, seriesName) {
  if (episode.info?.name) return episode.info.name;
  let title = episode.title || episode.name;
  if (seriesName && title.toLowerCase().startsWith(seriesName.toLowerCase())) title = title.slice(seriesName.length).trim();
  return title.replace(/^[-–:\s]*S\d+\s*E\d+[\s.:-]*/i, "") || title;
}
function shuffled(list) {
  const copy = [...list];
  for (let i = copy.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [copy[i], copy[j]] = [copy[j], copy[i]]; }
  return copy;
}
function description(textValue, limit = 300) {
  const value = plain(textValue);
  if (!value) return null;
  const p = text("p", value.length > limit ? `${value.slice(0, limit).replace(/\s+\S*$/, "")} …` : value, "description");
  if (value.length > limit) {
    p.tabIndex = 0; p.classList.add("expandable"); p.setAttribute("role", "button"); p.setAttribute("aria-label", "Ganzen Text zeigen");
    const expand = () => { p.textContent = value; p.classList.remove("expandable"); p.removeAttribute("role"); p.removeAttribute("aria-label"); };
    p.addEventListener("click", expand, { once: true });
    p.addEventListener("keydown", (e) => { if (e.key === "Enter") expand(); }, { once: true });
  }
  return p;
}
const playButton = (label, action) => iconButton("play", label, "primary", action);
const shuffleButton = (action) => iconButton("shuffle", "Zufällig", "secondary", action);

function albumView(id) {
  const album = state.albums.find((a) => a.id === id);
  if (!album) return [emptyNote("Album nicht gefunden.")];
  const total = album.tracks.reduce((sum, t) => sum + (t.duration || 0), 0);
  const favorite = isFavoriteAlbum(album);
  const heart = el("button", "round-button", icon(favorite ? "heart" : "heartOutline"));
  heart.type = "button"; heart.setAttribute("aria-pressed", String(favorite));
  heart.setAttribute("aria-label", favorite ? "Kein Lieblingsalbum mehr" : "Lieblingsalbum");
  heart.addEventListener("click", () => toggleAlbumFavorite(album));
  const more = el("button", "round-button", icon("more"));
  more.type = "button"; more.setAttribute("aria-label", "Albumaktionen"); more.setAttribute("aria-haspopup", "menu");
  more.addEventListener("click", () => showMenu(more, albumActions(album)));
  return [backdrop(album.cover), navBar("#musik/alben", "Alben", heart, more),
    hero({ art: album.cover, title: album.title, accent: album.artist ? artistLink(album.artist) : null,
      meta: [album.info?.genre, album.info?.year, `${album.tracks.length} Titel`, minutes(total)].filter(Boolean).join(" · "),
      actions: [playButton("Abspielen", () => playAudio(album.tracks, 0)), shuffleButton(() => playAudio(shuffled(album.tracks), 0))] }),
    description(album.info?.description), trackList(album.tracks, { numbered: true }),
    album.info?.copyright ? text("p", album.info.copyright, "copyright") : null];
}
/// Zurück links, Knöpfe rechts: die Leiste oben auf Detailseiten der App.
function navBar(href, label, ...buttons) { return el("div", "navbar", backLink(href, label), el("div", "navbar-buttons", ...buttons)); }
function artistLink(name) {
  const a = el("a", "artist-link");
  a.href = `#musik/interpret/${encodeURIComponent(name)}`;
  a.append(cover(artistImage(name), "round tiny", ""), text("span", name));
  return a;
}
function artistImage(name) {
  return state.artistInfo.get(name.toLowerCase())?.image || artistAlbums(name)[0]?.cover || null;
}

/// Alben wie artistAlbums in der App: eigene und solche mit Titeln des Interpreten, die neuesten zuerst.
function artistAlbums(name) {
  const key = name.toLowerCase();
  const released = (a) => a.info?.release_date || a.info?.year || "";
  return state.albums.filter((a) => a.artist.toLowerCase() === key || a.tracks.some((t) => (t.artist || "").toLowerCase() === key))
    .sort((a, b) => released(b).localeCompare(released(a)) || b.added - a.added);
}
const sameArtist = (value, name) => (value || "").toLowerCase() === name.toLowerCase();
/// Wie catalogKey in der App: ohne Gäste, Satzzeichen und „- Single“.
function catalogKey(title) {
  return String(title || "").toLowerCase().replace(/\s*[(\[](feat|ft|with)[^)\]]*[)\]]/g, "").replace(" - single", "").replace(/[^\p{L}\p{N}]/gu, "");
}

function artistView(name) {
  const info = state.artistInfo.get(name.toLowerCase());
  const albums = artistAlbums(name);
  const songs = state.songs.filter((t) => sameArtist(t.artist || t.album_artist, name))
    .sort((a, b) => (a.album || "").localeCompare(b.album || "", "de") || (a.disc_number || 1) - (b.disc_number || 1) || (a.track_number || 0) - (b.track_number || 0));
  const guest = state.songs.filter((t) => (t.featured || []).some((f) => sameArtist(f, name)));
  const liked = state.songs.filter((t) => isFavorite(t.id) && [t.artist, ...(t.featured || [])].some((a) => sameArtist(a, name)));
  const image = info?.image || albums[0]?.cover || guest[0]?.art;
  const picture = el("button", "hero-image", cover(image, "round", "♪"));
  picture.type = "button"; picture.disabled = !image;
  picture.setAttribute("aria-label", `Bild von ${name} groß anzeigen`);
  picture.addEventListener("click", () => showLargeImage(image, name));
  const head = hero({ art: null, shape: "round", title: name, meta: [info?.genre, info?.short_description].filter(Boolean)[0] || `${songs.length} Titel`,
    actions: songs.length ? [playButton("Abspielen", () => playAudio(songs, 0)), shuffleButton(() => playAudio(shuffled(songs), 0))] : [] });
  head.firstChild.replaceWith(picture);
  const catalogHolder = el("div", "", ...librarySections(name, albums, songs));
  loadArtistCatalog(name).then((catalog) => {
    if (catalog && $("inhalt").contains(catalogHolder)) catalogHolder.replaceChildren(...catalogSections(catalog, name, albums));
  });
  return [backdrop(image), navBar("#musik/interpreten", "Interpreten"), head, description(info?.description),
    liked.length ? text("h3", "Deine Lieblingssongs") : null, liked.length ? trackList(liked, { covers: true }) : null,
    catalogHolder,
    songs.length ? text("h3", "Deine Titel") : null, songs.length ? trackList(songs, { covers: true }) : null,
    guest.length ? text("h3", "Auch dabei bei") : null, guest.length ? trackList(guest, { covers: true }) : null];
}

/// Ohne Katalog: das Meistgehörte und die Alben aus der eigenen Bibliothek.
function librarySections(name, albums, songs) {
  const popular = [...songs].sort((a, b) => (state.plays.get(b.id) || 0) - (state.plays.get(a.id) || 0) || (b.modified || 0) - (a.modified || 0)).slice(0, 10);
  return [popular.length ? text("h3", "Songs") : null, popular.length ? trackList(popular, { covers: true }) : null,
    albums.length ? text("h3", "Alben") : null, albums.length ? el("div", "grid", ...albums.map((a) => albumCard(a, a.info?.year || `${a.tracks.length} Titel`))) : null].filter(Boolean);
}

const catalogs = new Map();
function loadArtistCatalog(name) {
  if (!catalogs.has(name)) catalogs.set(name, json(`/v1/music/artist?name=${encodeURIComponent(name)}`).catch(() => { catalogs.delete(name); return null; }));
  return catalogs.get(name);
}
const RELEASE_LABEL = { single: "Single", ep: "EP" };
const releaseLabel = (r) => RELEASE_LABEL[r.release_type] || (r.kind === "song" ? "Song" : "Album");
const catalogObserver = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    catalogObserver.unobserve(entry.target);
    entry.target.querySelector("img").src = entry.target.dataset.src;
  }
}, { rootMargin: "300px" });
function catalogCover(result, large) {
  const box = el("div", `cover catalog${large ? "" : " small"}`);
  box.dataset.symbol = "♪";
  box.setAttribute("aria-hidden", "true");
  if (result.cover) {
    const img = new Image();
    img.alt = ""; img.referrerPolicy = "no-referrer";
    img.addEventListener("load", () => box.classList.add("loaded"));
    box.append(img);
    // Erst kurz vor dem Sichtbarwerden laden, wie die Cover aus der Bibliothek.
    box.dataset.src = large ? result.cover.replace("100x100bb", "300x300bb") : result.cover;
    catalogObserver.observe(box);
  }
  return box;
}

/// Die Bereiche der App aus dem Katalog: Neuerscheinung, Beliebt, Neue Songs, Neu erschienen, Diskografie.
function catalogSections(catalog, name, albums) {
  const owned = new Map(state.songs.filter((t) => [t.artist, t.album_artist, ...(t.featured || [])].some((a) => sameArtist(a, name))).map((t) => [catalogKey(t.title), t]));
  const ownedAlbums = new Map(albums.map((a) => [catalogKey(a.title), a]));
  const unique = (list) => { const seen = new Set(); return (list || []).filter((r) => { const k = catalogKey(r.title); return !seen.has(k) && seen.add(k); }); };
  const releases = catalog.releases || catalog.albums || [];
  const parts = [];

  const newest = releases[0];
  if (newest) {
    const album = ownedAlbums.get(catalogKey(newest.title));
    const box = el("a", `newest${album ? "" : " missing"}`, catalogCover(newest, true),
      el("div", "newest-text", newest.released ? text("small", day(newest.released)) : null, text("strong", newest.title),
        text("span", [releaseLabel(newest), newest.track_count ? `${newest.track_count} Titel` : null].filter(Boolean).join(" · "))),
      icon("chevron"));
    box.href = album ? `#musik/album/${encodeURIComponent(album.id)}` : `#musik/finden/album/${newest.id}`;
    parts.push(text("h3", "Neuerscheinung"), box);
  }

  const popular = unique(catalog.popular).slice(0, 10);
  if (popular.length) {
    const list = el("div");
    let all = false;
    const show = () => list.replaceChildren(catalogSongs(all ? popular : popular.slice(0, 5), owned, true));
    const toggle = popular.length > 5 ? button("Mehr anzeigen", "more link-button", () => { all = !all; toggle.textContent = all ? "Weniger" : "Mehr anzeigen"; show(); }) : null;
    show();
    parts.push(el("div", "shelf-head", text("h3", "Beliebt"), toggle), list);
  }

  const fresh = unique((catalog.latest || []).filter((r) => r.kind === "song")).slice(0, 5);
  if (fresh.length) parts.push(text("h3", "Neue Songs"), catalogSongs(fresh, owned, false));

  const recent = releases.slice(1, 11);
  if (recent.length) parts.push(shelf("Neu erschienen", recent.map((r) => releaseCard(r, ownedAlbums))));

  const singles = catalog.singles || [];
  const longPlays = catalog.albums || [];
  if (longPlays.length || singles.length) {
    const grid = el("div", "grid");
    let showSingles = !longPlays.length;
    const fill = () => grid.replaceChildren(...(showSingles ? singles : longPlays).map((r) => releaseCard(r, ownedAlbums)));
    parts.push(text("h3", "Diskografie"));
    if (longPlays.length && singles.length) {
      const picker = el("div", "segmented", ...[["Alben", false], ["Singles & EPs", true]].map(([label, value]) => {
        const b = button(label, "", () => { showSingles = value; for (const other of picker.children) other.setAttribute("aria-pressed", String(other === b)); fill(); });
        b.setAttribute("aria-pressed", String(value === showSingles));
        return b;
      }));
      picker.setAttribute("aria-label", "Diskografie");
      parts.push(picker);
    }
    fill();
    parts.push(grid);
  }
  return parts.length ? parts : librarySections(name, albums, state.songs.filter((t) => sameArtist(t.artist || t.album_artist, name)));
}
function catalogSongs(results, owned, numbered) {
  const queue = results.map((r) => owned.get(catalogKey(r.title))).filter(Boolean);
  const list = el("ul", "tracks");
  results.forEach((result, position) => {
    const track = owned.get(catalogKey(result.title));
    const row = el("button", `track with-cover${numbered ? " ranked" : ""}${track ? "" : " missing"}`);
    row.type = "button";
    if (numbered) row.append(text("span", String(position + 1), "num"));
    row.append(track ? cover(track.art, "small") : catalogCover(result, false),
      el("div", "", text("strong", result.title), text("span", track ? [track.artist, track.album].filter(Boolean).join(" · ") : [result.album, result.year, "nicht in deiner Bibliothek"].filter(Boolean).join(" · "))),
      text("span", track ? clock(track.duration) : (result.seconds ? clock(result.seconds) : ""), "time"));
    if (track) { row.dataset.id = track.id; row.addEventListener("click", () => playAudio(queue, queue.indexOf(track))); }
    else { row.title = "Nicht in deiner Bibliothek: ansehen und auf den Server laden"; row.addEventListener("click", () => { location.hash = `#musik/finden/song/${result.id}`; }); }
    list.append(el("li", "", row, track ? moreButton(track.title, (anchor) => showMenu(anchor, trackActions(track))) : null));
  });
  return list;
}
function releaseCard(result, ownedAlbums) {
  const album = ownedAlbums.get(catalogKey(result.title));
  if (album) return albumCard(album, [releaseLabel(result), result.year].filter(Boolean).join(" · "));
  const box = el("a", "card missing", catalogCover(result, true), text("strong", result.title), text("span", [releaseLabel(result), result.year].filter(Boolean).join(" · ")));
  box.href = `#musik/finden/album/${result.id}`;
  box.title = "Nicht in deiner Bibliothek: ansehen und auf den Server laden";
  return box;
}

/// Ein Bild groß wie LargeArtworkView: Klick, Escape oder der Knopf schließen es.
async function showLargeImage(id, title) {
  const url = await artURL(id);
  if (!url) return;
  const layer = el("div", "lightbox");
  layer.setAttribute("role", "dialog"); layer.setAttribute("aria-modal", "true"); layer.setAttribute("aria-label", title);
  const img = new Image(); img.src = url; img.alt = title;
  const close = el("button", "round-button lightbox-close", icon("close"));
  close.type = "button"; close.setAttribute("aria-label", "Schließen");
  const previous = document.activeElement;
  const done = () => { layer.remove(); document.removeEventListener("keydown", onKey); previous?.focus?.({ preventScroll: true }); };
  const onKey = (event) => { if (event.key === "Escape") { event.stopPropagation(); done(); } };
  layer.addEventListener("click", done);
  document.addEventListener("keydown", onKey);
  layer.append(img, close);
  document.body.append(layer);
  close.focus();
}

/// Poster links, Titel und Fakten daneben: DetailHeader der App für Filme und Serien.
function detailHeader(artId, title, facts) {
  return el("div", "detail-head", cover(artId, "poster", "▶"),
    el("div", "", text("h2", title), ...facts.filter(Boolean).map((fact) => text("p", fact, "muted"))));
}
function wideButton(label, sub, action) {
  const b = el("button", "primary wide play-wide", el("span", "", icon("play"), text("span", label)), sub ? text("small", sub) : null);
  b.type = "button"; b.addEventListener("click", action);
  return b;
}

function movieView(movie) {
  const p = state.progress.get(movie.id) || 0;
  const started = p > 10 && movie.duration && p < movie.duration * FINISHED;
  const watched = isWatched(movie);
  const seen = iconButton(watched ? "checkCircle" : "circle", watched ? "Gesehen" : "Als gesehen markieren", `secondary${watched ? " on" : ""}`,
    () => { setWatched([movie], !watched); movieView(movie); });
  seen.setAttribute("aria-pressed", String(watched));
  const buttons = [seen, iconButton("download", "Herunterladen", "secondary", () => downloadFile(movie)), iconButton("info", "Infos", "secondary", () => showInfo(movie))];
  if (state.storage?.deletes) buttons.push(iconButton("trash", "Vom Server löschen", "secondary danger-text", () => deleteFromServer([movie], name, () => { location.hash = "#videos/filme"; })));
  if (started) buttons.unshift(iconButton("back", "Von vorne", "secondary", () => { state.progress.set(movie.id, 0); playVideo([movie], 0, "", true); }));
  const name = movie.info?.title || movie.title;
  $("inhalt").replaceChildren(...[backdrop(movie.art), navBar("#videos/filme", "Videos"),
    detailHeader(movie.art, name, [movie.info?.year ? String(movie.info.year) : null, minutes(movie.duration), formatLabel(movie)]),
    wideButton(started ? "Weiterschauen" : "Abspielen", started ? `noch ${minutes(movie.duration - p)}` : null, () => playVideo([movie], 0, "")),
    started ? Object.assign(bar(p / movie.duration), { className: "progress inline wide-progress" }) : null,
    el("div", "button-row", ...buttons),
    description(movie.info?.description, 600),
    el("div", "file-facts", text("h3", "Datei"), text("p", movie.path, "mono"), movie.bytes ? text("p", bytes(movie.bytes), "muted") : null)].filter(Boolean));
  window.scrollTo(0, 0);
  progressOf(movie).then((value) => { if (value !== p && $("inhalt").contains(seen)) movieView(movie); });
}
function formatLabel(item) {
  const suffix = (item.name || item.path || "").split(".").pop();
  return suffix && suffix !== item.name ? suffix.toUpperCase() : null;
}

/// Wie EpisodeRow: Standbild mit Nummer und Zeichen, Fortschritt über dem Titel, „…“ rechts.
function episodeRow(episode, entry, queue) {
  const p = state.progress.get(episode.id) || 0;
  const watched = isWatched(episode);
  const playing = video.queue[video.index]?.id === episode.id && !$("video-ebene").hidden;
  const still = cover(episode.still || episode.art, "still", "");
  const mark = el("span", "still-mark", icon(watched ? "check" : "play"), episode.episode != null ? text("b", String(episode.episode)) : null);
  still.append(mark);
  const name = episodeTitle(episode, entry.name);
  const facts = [episode.episode != null ? `Folge ${episode.episode}` : null, episode.info?.runtime ? `${episode.info.runtime} Min.` : minutes(episode.duration),
    episode.info?.airdate ? day(episode.info.airdate) : null].filter(Boolean).join(" · ");
  const started = !watched && episode.duration && p > 30;
  const play = el("button", "episode-play", still,
    el("div", "episode-text", started ? Object.assign(bar(p / episode.duration), { className: "progress inline episode-progress" }) : null,
      text("strong", name), facts ? text("span", facts, "muted") : null,
      episode.info?.summary ? text("p", plain(episode.info.summary), "summary") : null));
  play.type = "button";
  play.setAttribute("aria-label", `${name} abspielen${watched ? ", gesehen" : ""}`);
  play.addEventListener("click", () => playVideo(queue, queue.indexOf(episode), entry.name));
  const more = moreButton(name, (anchor) => showMenu(anchor, [
    [watched ? "Als nicht gesehen markieren" : "Als gesehen markieren", watched ? "eyeSlash" : "checkCircleOutline", () => setWatched([episode], !watched)],
    ["Abspielen", "play", () => playVideo(queue, queue.indexOf(episode), entry.name)],
    started ? ["Von vorne", "back", () => { state.progress.set(episode.id, 0); playVideo(queue, queue.indexOf(episode), entry.name, true); }] : null,
    null,
    ["Infos", "info", () => showInfo(episode)],
    ["Herunterladen", "download", () => downloadFile(episode)],
    ...deleteEntry([episode], name),
  ]));
  return el("li", `episode${watched ? " seen" : ""}${playing ? " current" : ""}`, play, more);
}

/// Die Folge zum Weiterschauen wie continueEpisode: angefangen, sonst die erste ungesehene nach der zuletzt gesehenen.
function nextEpisode(entry) {
  const episodes = entry.episodes;
  const begun = episodes.find((e) => !isWatched(e) && (state.progress.get(e.id) || 0) > 30);
  if (begun) return begun;
  let last = -1;
  episodes.forEach((e, i) => { if (isWatched(e)) last = i; });
  return episodes.slice(last + 1).find((e) => !isWatched(e)) || null;
}
const seasonOf = (entry, episode) => entry.list.find((s) => s.episodes.includes(episode));
const descendingSeasons = () => storage("local")?.getItem("mediaserver.seasonsDescending") !== "0";

function seriesView(id) {
  const entry = state.seriesById.get(id);
  if (!entry) return [emptyNote("Serie nicht gefunden.")];
  const info = entry.info || {};
  const years = info.premiered ? `${info.premiered.slice(0, 4)}${info.ended ? `–${info.ended.slice(0, 4)}` : info.status === "Running" ? "–heute" : ""}` : null;
  const rating = info.rating ? `★ ${Number(info.rating).toLocaleString("de-DE", { minimumFractionDigits: 1, maximumFractionDigits: 1 })}` : null;
  const counts = `${entry.list.length === 1 ? "1 Staffel" : `${entry.list.length} Staffeln`} · ${entry.episodes.length} Folgen`;
  const seriesButtons = [];
  if (state.storage?.deletes) {
    const more = el("button", "round-button", icon("more"));
    more.type = "button"; more.setAttribute("aria-label", "Serienaktionen"); more.setAttribute("aria-haspopup", "menu");
    more.addEventListener("click", () => showMenu(more, deleteEntry(entry.episodes, entry.name, () => { location.hash = "#videos/serien"; })));
    seriesButtons.push(more);
  }
  const parts = [backdrop(entry.cover), navBar("#videos/serien", "Videos", ...seriesButtons), detailHeader(entry.cover, entry.name, [years, info.network, rating, counts])];
  if (info.genres?.length) parts.push(el("div", "genres", ...info.genres.map((g) => text("span", g))));
  const next = nextEpisode(entry);
  if (next) {
    const season = seasonOf(entry, next);
    const started = entry.episodes.some(isWatched) || (state.progress.get(next.id) || 0) > 30;
    parts.push(wideButton(started ? "Weiterschauen" : "Ansehen",
      [season.number != null ? `Staffel ${season.number}` : season.title, next.episode != null ? `Folge ${next.episode}` : null].filter(Boolean).join(" · "),
      () => playVideo(season.episodes, season.episodes.indexOf(next), entry.name)));
  } else if (entry.episodes.length) parts.push(el("p", "all-seen", icon("checkCircle"), text("span", "Alle Folgen gesehen")));
  parts.push(description(info.description || info.summary));
  const descending = descendingSeasons();
  const sort = iconButton("sort", descending ? "Höchste zuerst" : "Erste zuerst", "link-button sort", () => {
    storage("local")?.setItem("mediaserver.seasonsDescending", descending ? "0" : "1"); render();
  });
  parts.push(el("div", "shelf-head", text("h3", "Staffeln"), sort));
  const ordered = entry.list.map((season, index) => ({ season, index }));
  if (descending) ordered.reverse();
  parts.push(el("div", "season-cards", ...ordered.map(({ season, index }) => seasonCard(entry, season, index))));
  // Positionen nachladen, damit „Weiterschauen“ die angefangene Folge trifft.
  const holder = parts[2];
  loadProgress(entry.episodes.filter((e) => !isWatched(e)).slice(0, 40)).then(() => {
    if ($("inhalt").contains(holder) && nextEpisode(entry) !== next) render();
  });
  return parts;
}
function seasonCard(entry, season, index) {
  const a = el("a", "season-card");
  a.href = `#serien/${encodeURIComponent(entry.id)}/${index}`;
  const seen = season.episodes.filter(isWatched).length;
  const progress = seen ? el("div", "season-progress", el("div", "meter", el("span")), text("small", seen === season.episodes.length ? "Gesehen" : `${seen}/${season.episodes.length}`)) : null;
  if (progress) progress.querySelector(".meter > span").style.width = `${(seen / season.episodes.length) * 100}%`;
  a.append(cover(season.cover || entry.cover, "poster", "▶"), el("div", "season-text", text("strong", season.title), text("span", season.episodes.length === 1 ? "1 Folge" : `${season.episodes.length} Folgen`, "muted"), progress), icon("chevron"));
  a.addEventListener("contextmenu", (event) => {
    event.preventDefault();
    showMenu(a, [["Staffel als gesehen markieren", "checkCircleOutline", () => setWatched(season.episodes, true)],
      ["Staffel als nicht gesehen markieren", "eyeSlash", () => setWatched(season.episodes, false)]], { x: event.clientX, y: event.clientY });
  });
  return a;
}

function seasonView(id, seasonIndex) {
  const entry = state.seriesById.get(id);
  const season = entry?.list[Number(seasonIndex) || 0];
  if (!season) return [emptyNote("Staffel nicht gefunden.")];
  const more = el("button", "round-button", icon("more"));
  more.type = "button"; more.setAttribute("aria-label", "Staffelaktionen"); more.setAttribute("aria-haspopup", "menu");
  more.addEventListener("click", () => showMenu(more, [["Alle als gesehen markieren", "checkCircleOutline", () => setWatched(season.episodes, true)],
    ["Alle als nicht gesehen markieren", "eyeSlash", () => setWatched(season.episodes, false)],
    ...deleteEntry(season.episodes, `${entry.name} · ${season.title}`, () => { location.hash = `#serien/${encodeURIComponent(id)}`; })]));
  const list = el("ul", "episodes", ...season.episodes.map((e) => episodeRow(e, entry, season.episodes)));
  loadProgress(season.episodes).then(() => {
    if ($("video-ebene").hidden && $("inhalt").contains(list)) list.replaceChildren(...season.episodes.map((e) => episodeRow(e, entry, season.episodes)));
  });
  return [navBar(`#serien/${encodeURIComponent(id)}`, entry.name, more), pageTitle(season.title),
    season.episodes.length ? wideButton("Staffel abspielen", null, () => playVideo(season.episodes, 0, entry.name)) : null, list];
}

function render() {
  const raw = location.hash.replace(/^#/, "");
  const [section = "start", sub = section === "musik" ? "alben" : "", ...rest] = raw ? raw.split("/") : ["start"];
  const searching = query().length > 0;
  const view = searching ? views.suche : (views[section] || views.start);
  const tab = ["serien", "filme", "videos"].includes(section) ? "videos" : section;
  for (const a of document.querySelectorAll(".tabbar a")) {
    if (!searching && a.dataset.section === tab) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
  }
  const decodedSub = section === "serien" && sub ? decodeURIComponent(sub) : sub;
  const id = rest.length ? decodeURIComponent(rest.join("/")) : undefined;
  $("inhalt").replaceChildren(...view(decodedSub, id).filter(Boolean));
  markPlaying();
}

// MARK: Musik

const player = { queue: [], index: -1, generation: 0, shuffle: false, repeat: "off", lyricLines: [] };
const audio = () => $("audio");

async function ticketURL(media) {
  const ticket = await json(`/v1/media/${encodeURIComponent(media.id)}/ticket`, { method: "POST" });
  return ticket.path;
}

async function playAudio(queue, index) {
  if (!queue.length) return;
  closeVideo();
  player.queue = queue; player.index = index;
  const generation = ++player.generation;
  const track = queue[index];
  $("player").hidden = false;
  for (const id of ["player-titel", "jetzt-titel"]) $(id).textContent = track.title;
  for (const id of ["player-kuenstler", "jetzt-kuenstler"]) $(id).textContent = [track.artist, track.album].filter(Boolean).join(" · ");
  for (const id of ["player-cover", "jetzt-cover"]) $(id).removeAttribute("src");
  showArt($("player-cover"), track.art);
  showArt($("jetzt-cover"), track.art);
  artURL(track.art).then((url) => {
    const value = url ? `url("${url}")` : "none";
    $("player").style.setProperty("--art", value);
    $("jetzt-hintergrund").style.setProperty("--art", value);
  });
  markPlaying();
  renderQueue();
  updateHeart();
  if (!$("jetzt-text").hidden) loadLyrics(track);
  try {
    const url = await ticketURL(track);
    if (generation !== player.generation) return;
    audio().src = url;
    applyVolume();
    await audio().play();
    recordPlay(track);
  } catch (error) {
    if (generation === player.generation) $("player-kuenstler").textContent = `Konnte nicht abspielen: ${error.message}`;
  }
  updateSession(track);
}
/// Lautstärke angleichen wie in der App: ReplayGain mit 6 dB Reserve, nie lauter als voll.
function applyVolume() {
  const track = player.queue[player.index];
  const gain = track?.gain_db;
  const level = setting("normalize", "1") === "1" && Number.isFinite(gain) ? Math.min(1, Math.max(0.1, 10 ** ((gain + 6) / 20))) : 1;
  audio().volume = Number($("lautstaerke").value) * level;
}

// MARK: Schlaf-Timer

const sleep = { timer: null, deadline: 0, atTrackEnd: false };
function setSleep(minutes, atTrackEnd = false) {
  clearTimeout(sleep.timer);
  sleep.deadline = minutes ? Date.now() + minutes * 60000 : 0;
  sleep.atTrackEnd = atTrackEnd;
  if (minutes) sleep.timer = setTimeout(() => { audio().pause(); setSleep(null); toast("Schlaf-Timer: Wiedergabe angehalten"); }, minutes * 60000);
  const on = Boolean(minutes || atTrackEnd);
  $("jetzt-timer").setAttribute("aria-pressed", String(on));
  $("jetzt-timer").setAttribute("aria-label", on ? (atTrackEnd ? "Schlaf-Timer: am Ende des Titels" : `Schlaf-Timer: ${minutes} Minuten`) : "Schlaf-Timer");
  if (on) toast(atTrackEnd ? "Hält am Ende dieses Titels an" : `Hält in ${minutes} Minuten an`);
}
function sleepMenu(anchor) {
  const entries = [15, 30, 45, 60].map((m) => [`${m} Minuten`, "moon", () => setSleep(m)]);
  entries.push(["Am Ende des Titels", "moon", () => setSleep(null, true)]);
  if (sleep.deadline || sleep.atTrackEnd) {
    const left = sleep.deadline ? ` (noch ${Math.max(1, Math.round((sleep.deadline - Date.now()) / 60000))} Min.)` : "";
    entries.push(null, [`Schlaf-Timer aus${left}`, "close", () => { setSleep(null); toast("Schlaf-Timer aus"); }]);
  }
  showMenu(anchor, entries);
}

function nextTrack() {
  if (player.index + 1 < player.queue.length) playAudio(player.queue, player.index + 1);
  else if (player.repeat === "all" && player.queue.length) playAudio(player.queue, 0);
}
function trackEnded() {
  if (sleep.atTrackEnd) { setSleep(null); toast("Schlaf-Timer: Wiedergabe angehalten"); return; }
  if (player.repeat === "one") { audio().currentTime = 0; audio().play(); } else nextTrack();
}
function cycleRepeat() {
  player.repeat = { off: "all", all: "one", one: "off" }[player.repeat];
  const b = $("jetzt-wiederholen");
  b.setAttribute("aria-pressed", String(player.repeat !== "off"));
  b.setAttribute("aria-label", `Wiederholen: ${{ off: "aus", all: "alle", one: "diesen Titel" }[player.repeat]}`);
  b.dataset.mode = player.repeat;
}
function updateHeart() {
  const track = player.queue[player.index];
  const on = track ? isFavorite(track.id) : false;
  $("jetzt-herz").setAttribute("aria-pressed", String(on));
  $("jetzt-herz").setAttribute("aria-label", on ? "Aus Lieblingssongs entfernen" : "Zu Lieblingssongs hinzufügen");
}

// MARK: Songtext

/// "[01:23.45] Zeile" wird zu {time, text}; Zeilen ohne Zeitmarke fallen weg.
function parseLyrics(synced) {
  const lines = [];
  for (const raw of synced.split(/\r?\n/)) {
    const stamps = [...raw.matchAll(/\[(\d+):(\d+(?:\.\d+)?)\]/g)];
    const words = raw.replace(/\[[^\]]*\]/g, "").trim();
    for (const stamp of stamps) lines.push({ time: Number(stamp[1]) * 60 + Number(stamp[2]), text: words || "♪" });
  }
  return lines.sort((a, b) => a.time - b.time);
}
async function loadLyrics(track) {
  const box = $("jetzt-text");
  box.classList.remove("plain");
  box.replaceChildren(text("p", "Songtext wird geladen …", "source"));
  player.lyricLines = [];
  try {
    const lyrics = await json(`/v1/lyrics/${encodeURIComponent(track.id)}`);
    if (player.queue[player.index]?.id !== track.id) return;
    if (lyrics.instrumental) { box.replaceChildren(text("p", "Instrumental", "source")); return; }
    if (lyrics.synced) {
      player.lyricLines = parseLyrics(lyrics.synced);
      box.replaceChildren(...player.lyricLines.map((line) => {
        const p = text("p", line.text);
        p.addEventListener("click", () => { audio().currentTime = line.time; });
        return p;
      }));
    } else if (lyrics.plain) {
      box.classList.add("plain");
      box.replaceChildren(...lyrics.plain.split(/\n{2,}/).map((part) => text("p", part)));
    } else box.replaceChildren(text("p", "Kein Songtext gefunden.", "source"));
    const sources = { file: "Datei neben dem Song", embedded: "In der Datei", tag: "In der Datei", genius: "Genius", lrclib: "LRCLIB" };
    if (lyrics.source) box.append(text("p", `Quelle: ${sources[String(lyrics.source).toLowerCase()] || lyrics.source}`, "source"));
  } catch { box.replaceChildren(text("p", "Kein Songtext gefunden.", "source")); }
}
function followLyrics(time) {
  const lines = player.lyricLines;
  if (!lines.length || $("jetzt-text").hidden) return;
  let index = -1;
  for (let i = 0; i < lines.length && lines[i].time <= time + 0.3; i++) index = i;
  const nodes = $("jetzt-text").children;
  for (let i = 0; i < lines.length; i++) nodes[i]?.classList.toggle("active", i === index);
  const active = nodes[index];
  if (active && active.dataset.shown !== "1") {
    for (const node of nodes) delete node.dataset.shown;
    active.dataset.shown = "1";
    $("jetzt-text").scrollTo({ top: active.offsetTop - $("jetzt-text").clientHeight * 0.3 });
  }
}
function toggleLyrics() {
  const box = $("jetzt-text");
  box.hidden = !box.hidden;
  $("jetzt").classList.toggle("lyrics-open", !box.hidden);
  $("jetzt-songtext").setAttribute("aria-pressed", String(!box.hidden));
  if (!box.hidden && player.index >= 0) loadLyrics(player.queue[player.index]);
}
function previousTrack() {
  if (audio().currentTime > 3 || player.index === 0) { audio().currentTime = 0; return; }
  playAudio(player.queue, player.index - 1);
}
function toggleAudio() { if (!audio().src) return; if (audio().paused) audio().play(); else audio().pause(); }
function stopAudio() { audio().pause(); audio().removeAttribute("src"); audio().load(); $("player").hidden = true; closeNowPlaying(); player.queue = []; player.index = -1; }
function shuffleRest() {
  if (player.index < 0) return;
  const current = player.queue[player.index];
  const rest = player.queue.filter((_, i) => i !== player.index);
  player.queue = [current, ...shuffled(rest)]; player.index = 0;
  $("jetzt-zufall").setAttribute("aria-pressed", "true");
  renderQueue();
}
/// Wie in der App: direkt nach dem laufenden Titel oder ans Ende; ohne Wiedergabe startet es sofort.
function playNext(...tracks) {
  if (player.index < 0) { playAudio(tracks, 0); return; }
  player.queue = [...player.queue.slice(0, player.index + 1), ...tracks, ...player.queue.slice(player.index + 1)];
  renderQueue();
  toast(tracks.length === 1 ? `„${tracks[0].title}“ spielt als Nächstes` : `${tracks.length} Titel spielen als Nächstes`);
}
function addToQueue(...tracks) {
  if (player.index < 0) { playAudio(tracks, 0); return; }
  player.queue = [...player.queue, ...tracks];
  renderQueue();
  toast(tracks.length === 1 ? `„${tracks[0].title}“ ist in der Warteschlange` : `${tracks.length} Titel sind in der Warteschlange`);
}
function renderQueue() {
  const list = $("jetzt-warteschlange");
  list.replaceChildren(...player.queue.slice(player.index, player.index + 30).map((track, offset) => {
    const b = el("button", "", cover(track.art, "small"), el("span", "", text("strong", track.title), text("small", track.artist || "")));
    b.type = "button";
    b.addEventListener("click", () => playAudio(player.queue, player.index + offset));
    return el("li", offset === 0 ? "current" : "", b);
  }));
}
function openNowPlaying() { if (player.index >= 0) { $("jetzt").hidden = false; document.body.style.overflow = "hidden"; $("jetzt-schliessen").focus(); } }
function closeNowPlaying() { if ($("jetzt").hidden) return; $("jetzt").hidden = true; document.body.style.overflow = ""; $("mini-oeffnen").focus({ preventScroll: true }); }

async function updateSession(track) {
  if (!("mediaSession" in navigator)) return;
  const artwork = [];
  const url = await artURL(track.art);
  if (url) artwork.push({ src: url, sizes: "512x512" });
  navigator.mediaSession.metadata = new MediaMetadata({ title: track.title, artist: track.artist || "", album: track.album || "", artwork });
}

function setupAudio() {
  const a = audio();
  let seeking = false;
  const playing = (on) => {
    for (const id of ["player", "jetzt"]) $(id).classList.toggle("playing", on);
    for (const id of ["abspielen", "jetzt-abspielen"]) $(id).setAttribute("aria-label", on ? "Pausieren" : "Abspielen");
  };
  a.addEventListener("play", () => playing(true));
  a.addEventListener("pause", () => playing(false));
  a.addEventListener("ended", trackEnded);
  a.addEventListener("loadedmetadata", () => { $("position").max = String(a.duration || 0); $("dauer").textContent = `-${clock(a.duration)}`; });
  a.addEventListener("timeupdate", () => {
    if (!seeking) $("position").value = String(a.currentTime);
    $("zeit").textContent = clock(a.currentTime);
    $("dauer").textContent = `-${clock((a.duration || 0) - a.currentTime)}`;
    $("mini-fortschritt").style.width = a.duration ? `${(a.currentTime / a.duration) * 100}%` : "0";
    followLyrics(a.currentTime);
  });
  $("position").addEventListener("input", () => { seeking = true; $("zeit").textContent = clock(Number($("position").value)); });
  $("position").addEventListener("change", () => { a.currentTime = Number($("position").value); seeking = false; });
  $("lautstaerke").addEventListener("input", applyVolume);
  for (const id of ["abspielen", "jetzt-abspielen"]) $(id).addEventListener("click", toggleAudio);
  for (const id of ["weiter", "jetzt-weiter"]) $(id).addEventListener("click", nextTrack);
  for (const id of ["zurueck", "jetzt-zurueck"]) $(id).addEventListener("click", previousTrack);
  $("mini-oeffnen").addEventListener("click", openNowPlaying);
  $("jetzt-schliessen").addEventListener("click", closeNowPlaying);
  $("jetzt-zufall").addEventListener("click", shuffleRest);
  $("jetzt-wiederholen").addEventListener("click", cycleRepeat);
  $("jetzt-songtext").addEventListener("click", toggleLyrics);
  $("jetzt-timer").addEventListener("click", () => sleepMenu($("jetzt-timer")));
  $("jetzt-mehr").addEventListener("click", () => { const t = player.queue[player.index]; if (t) showMenu($("jetzt-mehr"), trackActions(t)); });
  $("jetzt-herz").addEventListener("click", () => {
    const track = player.queue[player.index];
    if (track) { toggleFavorite(track.id); updateHeart(); }
  });
  $("jetzt-liste").addEventListener("click", () => {
    const list = $("jetzt-warteschlange"); list.hidden = !list.hidden;
    $("jetzt-liste").setAttribute("aria-pressed", String(!list.hidden));
  });
  $("jetzt-titel").addEventListener("click", () => {
    const t = player.queue[player.index];
    if (t?.albumId) { closeNowPlaying(); location.hash = `#musik/album/${encodeURIComponent(t.albumId)}`; }
  });
  document.addEventListener("keydown", (event) => { if (event.key === "Escape" && !$("jetzt").hidden) closeNowPlaying(); });
  if ("mediaSession" in navigator) {
    navigator.mediaSession.setActionHandler("play", () => a.play());
    navigator.mediaSession.setActionHandler("pause", () => a.pause());
    navigator.mediaSession.setActionHandler("nexttrack", nextTrack);
    navigator.mediaSession.setActionHandler("previoustrack", previousTrack);
  }
}

// MARK: Video

const video = { queue: [], index: -1, saveTimer: null, subtitleURLs: [], series: "", markedSeen: false };

async function playVideo(queue, index, series = video.series, fromStart = false) {
  audio().pause();
  video.queue = queue; video.index = index; video.series = series; video.markedSeen = false;
  const item = queue[index];
  const element = $("video");
  const code = episodeCode(item);
  $("video-titel").textContent = series ? `${series} · ${code ? `${code} · ` : ""}${episodeTitle(item, series)}` : (item.info?.title || item.title);
  $("naechste-folge").hidden = index + 1 >= queue.length;
  $("video-ebene").hidden = false;
  document.body.style.overflow = "hidden";
  for (const track of element.querySelectorAll("track")) track.remove();
  for (const url of video.subtitleURLs) URL.revokeObjectURL(url);
  video.subtitleURLs = [];
  try {
    const [url, resume] = await Promise.all([ticketURL(item), fromStart ? 0 : progressOf(item)]);
    element.src = url;
    element.addEventListener("loadedmetadata", () => {
      if (resume > 10 && resume < (element.duration || Infinity) * FINISHED) element.currentTime = resume;
    }, { once: true });
    await addSubtitles(item, element);
    await element.play().catch(() => {});
    recordPlay(item);
  } catch (error) {
    $("video-titel").textContent = `Konnte nicht abspielen: ${error.message}`;
  }
  closeNowPlaying();
  $("video-schliessen").focus();
  clearInterval(video.saveTimer);
  video.saveTimer = setInterval(saveVideoPosition, 15000);
}

async function addSubtitles(item, element) {
  for (const subtitle of item.subtitles || []) {
    try {
      const blob = await (await api(`/v1/subtitles/${encodeURIComponent(subtitle.id)}`)).blob();
      const url = URL.createObjectURL(blob);
      video.subtitleURLs.push(url);
      const track = document.createElement("track");
      track.kind = "subtitles"; track.src = url; track.label = subtitle.label || subtitle.language || "Untertitel";
      if (subtitle.language) track.srclang = subtitle.language;
      const wanted = setting("subtitles", "off");
      if (!element.querySelector("track[default]") && !subtitle.forced && (wanted === "auto" || (wanted !== "off" && (subtitle.language || "").startsWith(wanted)))) track.default = true;
      element.append(track);
    } catch { /* ohne diese Untertitel weiter */ }
  }
}

function saveVideoPosition() {
  const item = video.queue[video.index];
  const element = $("video");
  if (!item || !element.src || !Number.isFinite(element.currentTime) || !element.duration) return;
  const finished = element.currentTime >= element.duration * FINISHED;
  const seconds = finished ? 0 : element.currentTime;
  state.progress.set(item.id, seconds);
  send(`/v1/progress/${encodeURIComponent(item.id)}`, "PUT", { seconds }).catch(() => {});
}

function closeVideo() {
  if ($("video-ebene").hidden) return;
  saveVideoPosition();
  clearInterval(video.saveTimer);
  const element = $("video");
  element.pause(); element.removeAttribute("src"); element.load();
  $("video-ebene").hidden = true;
  document.body.style.overflow = "";
  render();
}

function setupVideo() {
  const element = $("video");
  $("video-schliessen").addEventListener("click", closeVideo);
  $("naechste-folge").addEventListener("click", () => { saveVideoPosition(); playVideo(video.queue, video.index + 1); });
  element.addEventListener("pause", saveVideoPosition);
  $("intro").addEventListener("click", () => { const item = video.queue[video.index]; if (item?.intro) element.currentTime = item.intro.end; });
  element.addEventListener("timeupdate", () => {
    const item = video.queue[video.index];
    // Bis eine Sekunde vor dem Ende, damit ein Klick nie hinter dem Vorspann landet.
    $("intro").hidden = !(item?.intro && element.currentTime >= item.intro.start && element.currentTime < item.intro.end - 1);
    if (!video.markedSeen && item && element.duration && element.currentTime >= element.duration * FINISHED) {
      video.markedSeen = true;
      if (!isWatched(item)) {
        const flag = { id: item.id, on: true, at: Date.now() / 1000 };
        state.watched.set(item.id, flag);
        sync({ watched: [flag] });
      }
    }
  });
  element.addEventListener("ended", () => {
    saveVideoPosition();
    if (video.index + 1 < video.queue.length) playVideo(video.queue, video.index + 1, video.series, true);
  });
  document.addEventListener("keydown", (event) => { if (event.key === "Escape" && !$("video-ebene").hidden && !document.fullscreenElement) closeVideo(); });
}

// MARK: Einstellungen im Browser

function setting(key, fallback) { return storage("local")?.getItem(`mediaserver.${key}`) ?? fallback; }
function setSetting(key, value) { storage("local")?.setItem(`mediaserver.${key}`, value); }
function duration(seconds) {
  const s = Math.round(seconds), d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  return d ? `${d} T. ${h} Std.` : h ? `${h} Std. ${m} Min.` : `${Math.max(1, m)} Min.`;
}

// MARK: Infos, Herunterladen, Löschen

function showInfo(item) {
  const rows = [["Titel", item.info?.title || item.info?.name || item.title], ["Interpret", item.artist_credit || item.artist], ["Album", item.album],
    ["Staffel / Folge", item.season != null && item.episode != null ? `${item.season} / ${item.episode}` : null],
    ["Dauer", item.duration ? clock(item.duration) : null], ["Format", formatLabel(item)], ["Größe", item.bytes ? bytes(item.bytes) : null],
    ["Hinzugefügt", item.added ? day(item.added * 1000) : null], ["Lautstärke", Number.isFinite(item.gain_db) ? `${item.gain_db > 0 ? "+" : ""}${item.gain_db.toFixed(1)} dB` : null],
    ["Untertitel", (item.subtitles || []).map((s) => s.label || s.language).join(", ") || null],
    ["Wiedergaben", item.kind === "audio" ? String(state.plays.get(item.id) || 0) : null], ["Pfad", item.path]].filter(([, value]) => value);
  const dialog = el("dialog", "info-sheet", text("h2", "Infos"),
    el("dl", "", ...rows.flatMap(([label, value]) => [text("dt", label), text("dd", String(value))])));
  const close = button("Fertig", "primary wide", () => dialog.close());
  dialog.append(close);
  dialog.addEventListener("close", () => dialog.remove());
  document.body.append(dialog);
  dialog.showModal();
}
/// Speichert die Datei über ein Streaming-Ticket; der Browser lädt sie selbst herunter.
async function downloadFile(item) {
  try {
    const a = el("a"); a.href = await ticketURL(item); a.download = item.name || item.title;
    document.body.append(a); a.click(); a.remove();
    toast(`„${item.title || item.name}“ wird heruntergeladen`);
  } catch (error) { toast(`Herunterladen fehlgeschlagen: ${error.message}`); }
}
async function deleteFromServer(items, name, after) {
  const what = items.length === 1 ? "die Datei" : `${items.length} Dateien`;
  if (!confirm(`„${name}“ vom Server löschen?\n\n${what[0].toUpperCase()}${what.slice(1)} wandert in den Papierkorb des Servers und wird nach 14 Tagen endgültig gelöscht.`)) return;
  try {
    const answer = await (await send("/v1/media/delete", "POST", { ids: items.map((i) => i.id) })).json();
    const failed = answer.failed?.length || 0;
    toast(failed ? `${failed} Dateien ließen sich nicht löschen` : `„${name}“ gelöscht`);
    if (items.some((i) => player.queue[player.index]?.id === i.id)) stopAudio();
    await loadLibrary();
    if (after) after(); else render();
  } catch (error) { toast(`Löschen fehlgeschlagen: ${error.message}`); }
}

/// Einfacher als similarSongs der App: das Album ab diesem Song, dann der Rest des Interpreten.
function similarQueue(song) {
  const album = state.albums.find((a) => a.id === song.albumId);
  const later = album ? album.tracks.slice(album.tracks.indexOf(song) + 1) : [];
  const artist = (song.artist || "").toLowerCase();
  const same = state.songs.filter((t) => t !== song && !later.includes(t) && (t.artist || "").toLowerCase() === artist);
  return [song, ...later, ...shuffled(same)].slice(0, 100);
}

// MARK: Musik finden

const JOB_STATES = { queued: "Wartet", running: "Lädt", done: "Fertig", partial: "Teilweise geladen", failed: "Fehlgeschlagen", cancelled: "Abgebrochen" };
let finderTimer = null;
const finder = { query: "", kind: "song", results: [] };

function finderView(path) {
  clearInterval(finderTimer);
  const [kind, id] = (path || "").split("/");
  if (kind && id) return previewView(kind, id);
  const input = el("input"); input.type = "search"; input.placeholder = "Song oder Album suchen"; input.value = finder.query;
  input.setAttribute("aria-label", "Im iTunes-Katalog suchen");
  const results = el("div");
  const showResults = () => results.replaceChildren(...(finder.results.length ? [el("ul", "tracks", ...finder.results.map(resultRow))] :
    finder.query ? [emptyNote("Nichts gefunden.")] : []));
  const search = async () => {
    finder.query = input.value.trim();
    if (!finder.query) { finder.results = []; showResults(); return; }
    results.replaceChildren(text("p", "Sucht …", "muted"));
    try {
      const answer = await json(`/v1/music/search?q=${encodeURIComponent(finder.query)}&kind=${finder.kind}`);
      finder.results = answer.results || [];
    } catch (error) { results.replaceChildren(emptyNote(error.message.includes("404") ? "„Musik finden“ ist auf diesem Server nicht eingerichtet." : `Suche fehlgeschlagen: ${error.message}`)); return; }
    showResults();
  };
  const form = el("form", "finder-form", input, button("Suchen", "primary", () => {}));
  form.lastChild.type = "submit";
  form.addEventListener("submit", (event) => { event.preventDefault(); search(); });
  const kinds = el("div", "segmented", ...[["song", "Songs"], ["album", "Alben"]].map(([value, label]) => {
    const b = button(label, "", () => { finder.kind = value; for (const other of kinds.children) other.setAttribute("aria-pressed", String(other === b)); search(); });
    b.setAttribute("aria-pressed", String(finder.kind === value));
    return b;
  }));
  const jobs = el("div");
  const refresh = () => loadJobs(jobs);
  refresh();
  finderTimer = setInterval(() => { if (!$("inhalt").contains(jobs)) clearInterval(finderTimer); else refresh(); }, 5000);
  showResults();
  setTimeout(() => input.focus(), 0);
  return [navBar("#musik/alben", "Musik"), pageTitle("Musik finden"),
    text("p", "Sucht im iTunes-Katalog. Was du auswählst, lädt der Server in deine Bibliothek. Nutze das nur für Inhalte, für die du die Rechte hast.", "muted small-note"),
    form, kinds, results, jobs];
}
function resultRow(result) {
  const row = el("button", "track with-cover", catalogCover(result, false),
    el("div", "", text("strong", `${result.title}${result.explicit ? " 🅴" : ""}`), text("span", [result.kind === "album" ? releaseLabel(result) : null, result.artist, result.album, result.year].filter(Boolean).join(" · "))),
    text("span", result.kind === "album" ? (result.track_count ? `${result.track_count} Titel` : "") : (result.seconds ? clock(result.seconds) : ""), "time"));
  row.type = "button";
  row.addEventListener("click", () => { location.hash = `#musik/finden/${result.kind}/${result.id}`; });
  return el("li", "", row);
}
function previewView(kind, id) {
  const holder = el("div", "", text("p", "Lädt …", "muted"));
  json(`/v1/music/preview?kind=${encodeURIComponent(kind)}&id=${encodeURIComponent(id)}`).then((preview) => {
    const item = preview.item;
    const load = iconButton("download", "Auf den Server laden", "primary", async () => {
      load.disabled = true;
      try {
        await send("/v1/music/jobs", "POST", { kind: item.kind, item_id: item.id, title: item.title, artist: item.artist || null, cover: item.cover || null });
        toast(`„${item.title}“ wird geladen`);
        location.hash = "#musik/finden";
      } catch (error) { toast(`Konnte den Auftrag nicht anlegen: ${error.message}`); load.disabled = false; }
    });
    const head = el("div", "detail-head", catalogCover(item, true),
      el("div", "", text("h2", item.title), text("p", [item.artist, releaseLabel(item), item.year].filter(Boolean).join(" · "), "muted")));
    const list = el("ol", "preview-tracks", ...(preview.tracks || []).map((t) => el("li", "", text("span", `${t.title}${t.explicit ? " 🅴" : ""}`),
      text("span", [t.artist !== item.artist ? t.artist : null, t.seconds ? clock(t.seconds) : null].filter(Boolean).join(" · "), "muted"))));
    holder.replaceChildren(head, el("div", "button-row", load), list);
  }).catch((error) => holder.replaceChildren(emptyNote(`Nicht verfügbar: ${error.message}`)));
  return [navBar("#musik/finden", "Musik finden"), holder];
}
let knownDone = new Set();
async function loadJobs(box) {
  try {
    const answer = await json("/v1/music/jobs");
    const jobs = answer.jobs || [];
    const finished = jobs.filter((j) => j.state === "done" || j.state === "partial").map((j) => j.id);
    if (knownDone.size && finished.some((id) => !knownDone.has(id))) loadLibrary().then(() => toast("Neue Musik ist da")).catch(() => {});
    knownDone = new Set(finished);
    if (!jobs.length && answer.service_online !== false) { box.replaceChildren(); return; }
    box.replaceChildren(text("h3", "Aufträge"),
      answer.service_online === false ? text("p", "Der Musik-Dienst auf dem Server antwortet gerade nicht.", "error") : null,
      el("ul", "jobs", ...jobs.map((job) => {
        const stateText = [JOB_STATES[job.state] || job.state, job.total ? `${job.done}/${job.total}` : null, job.current].filter(Boolean).join(" · ");
        const active = job.state === "queued" || job.state === "running";
        const remove = button(active ? "Abbrechen" : "Entfernen", "link-button", async () => {
          try { await api(`/v1/music/jobs/${encodeURIComponent(job.id)}`, { method: "DELETE" }); loadJobs(box); } catch (error) { toast(error.message); }
        });
        return el("li", "", catalogCover(job, false), el("div", "", text("strong", job.title), text("span", stateText, "muted"),
          job.message ? text("small", job.message, "muted") : null), remove);
      })));
  } catch { box.replaceChildren(); }
}

// MARK: Hochladen

const UPLOAD_CHUNK = 8 * 1024 * 1024;
function uploadView() {
  const parts = [navBar("#einstellungen", "Einstellungen"), pageTitle("Hochladen")];
  if (state.storage && !state.storage.uploads) {
    parts.push(text("p", "Uploads sind auf deinem Server noch ausgeschaltet. Auf dem Pi in /etc/miniply/server.env die Zeile MINIPLY_UPLOADS=1 ergänzen und den Dienst neu starten.", "error"));
    return parts;
  }
  const hints = { Musik: "Album, z. B. Linkin Park/Hybrid Theory", Serien: "Serie/Staffel, z. B. Two and a Half Men/Season 1", Filme: "Optionaler Unterordner", Dokumente: "Optionaler Unterordner" };
  let category = setting("uploadCategory", "Musik");
  const folder = el("input"); folder.type = "text"; folder.placeholder = hints[category]; folder.setAttribute("aria-label", "Ordner");
  const categories = el("div", "segmented", ...Object.keys(hints).map((name) => {
    const b = button(name, "", () => { category = name; setSetting("uploadCategory", name); folder.placeholder = hints[name]; for (const other of categories.children) other.setAttribute("aria-pressed", String(other === b)); });
    b.setAttribute("aria-pressed", String(name === category));
    return b;
  }));
  const files = el("input"); files.type = "file"; files.multiple = true; files.hidden = true;
  const directory = el("input"); directory.type = "file"; directory.webkitdirectory = true; directory.hidden = true;
  const list = el("ul", "uploads");
  const target = () => [category, ...folder.value.split("/").map((p) => p.trim()).filter(Boolean)].join("/");
  const start = (chosen, fromFolder) => {
    const base = target();
    for (const file of chosen) {
      const relative = fromFolder && file.webkitRelativePath ? file.webkitRelativePath.split("/").slice(0, -1).join("/") : "";
      if (file.name.startsWith(".")) continue;
      uploadFile(file, [base, relative].filter(Boolean).join("/"), list);
    }
  };
  files.addEventListener("change", () => { start([...files.files], false); files.value = ""; });
  directory.addEventListener("change", () => { start([...directory.files], true); directory.value = ""; });
  parts.push(categories, el("div", "field upload-field", text("label", "Ordner"), folder),
    el("div", "button-row", button("Dateien auswählen", "primary", () => files.click()), button("Ganzen Ordner", "secondary", () => directory.click())), files, directory,
    text("p", "Wählst du einen ganzen Ordner, wird er unter diesem Ziel angelegt. Ein Bild im Ordner wird zum Cover. Neue Dateien erscheinen nach dem Hochladen in der Bibliothek.", "muted small-note"), list);
  return parts;
}
async function uploadFile(file, path, list) {
  const id = crypto.randomUUID();
  const meter = el("div", "meter", el("span"));
  const status = text("span", "Wartet …", "muted");
  list.append(el("li", "", el("div", "", text("strong", file.name), status), meter));
  const query = (offset) => `/v1/uploads/${id}?offset=${offset}&bytes=${file.size}&path=${encodeURIComponent(path)}&name=${encodeURIComponent(file.name)}`;
  let offset = 0;
  try {
    do {
      const end = Math.min(file.size, offset + UPLOAD_CHUNK);
      const response = await fetch(query(offset), { method: "PUT", headers: { Authorization: `Bearer ${state.token}` }, body: file.slice(offset, end) });
      if (response.status === 409) throw new Error("Datei gibt es dort schon");
      if (response.status === 412) { offset = (await json(`/v1/uploads/${id}`)).received || 0; continue; }
      if (!response.ok) throw new Error(`Server antwortet ${response.status}`);
      offset = end;
      meter.firstChild.style.width = `${file.size ? (offset / file.size) * 100 : 100}%`;
      status.textContent = `${bytes(offset)} von ${bytes(file.size)}`;
    } while (offset < file.size);
    status.textContent = `Fertig · ${path}`;
    clearTimeout(uploadFile.reload);
    uploadFile.reload = setTimeout(() => loadLibrary().catch(() => {}), 3000);
  } catch (error) {
    status.textContent = `Fehler: ${error.message}`; status.classList.add("error");
    fetch(`/v1/uploads/${id}`, { method: "DELETE", headers: { Authorization: `Bearer ${state.token}` } }).catch(() => {});
  }
}

// MARK: SSD durchsuchen

function filesView(path) {
  const holder = el("div", "", text("p", "Lädt …", "muted"));
  const up = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
  json(`/v1/files?path=${encodeURIComponent(path)}&limit=500`).then((answer) => {
    const rows = [];
    for (const dir of answer.directories || []) {
      const a = el("a", "file-row", icon("folder"), text("span", dir.split("/").pop()), icon("chevron"));
      a.href = `#dateien/${encodeURIComponent(dir)}`;
      rows.push(el("li", "", a));
    }
    for (const file of answer.files || []) {
      const b = el("button", "file-row", icon(file.kind === "audio" ? "note" : file.kind === "video" ? "film" : "doc"),
        el("span", "", text("strong", file.name), text("small", [bytes(file.bytes), file.duration ? clock(file.duration) : null].filter(Boolean).join(" · "), "muted")));
      b.type = "button";
      b.addEventListener("click", () => {
        const known = state.byId.get(file.id) || file;
        if (known.kind === "audio") playAudio([known], 0);
        else if (known.kind === "video") playVideo([known], 0, "");
        else downloadFile(known);
      });
      rows.push(el("li", "", b, moreButton(file.name, (anchor) => showMenu(anchor, [["Herunterladen", "download", () => downloadFile(file)], ["Infos", "info", () => showInfo(state.byId.get(file.id) || file)],
        ...(file.kind !== "file" ? deleteEntry([file], file.name, () => render()) : [])]))));
    }
    if (answer.total > (answer.files || []).length) rows.push(el("li", "", text("p", `Nur die ersten ${answer.files.length} von ${answer.total} Dateien.`, "muted")));
    holder.replaceChildren(rows.length ? el("ul", "files", ...rows) : emptyNote("Dieser Ordner ist leer."));
  }).catch((error) => {
    // Ein Ordner verschwindet, wenn seine letzte Datei gelöscht wurde: dann eine Ebene höher.
    if (path && error.message.includes("404")) { location.hash = `#dateien/${encodeURIComponent(up)}`; return; }
    holder.replaceChildren(emptyNote(`Ordner nicht lesbar: ${error.message}`));
  });
  return [navBar(path ? `#dateien/${encodeURIComponent(up)}` : "#einstellungen", path ? (up.split("/").pop() || "SSD") : "Einstellungen"), pageTitle(path ? path.split("/").pop() : "SSD"), holder];
}

// MARK: Start

function setupKeys() {
  document.addEventListener("keydown", (event) => {
    const active = document.activeElement;
    // Regler und Häkchen sind kein Textfeld: dort sollen die Kürzel weiter wirken.
    const typing = (active?.tagName === "INPUT" && !["range", "checkbox", "button"].includes(active.type)) || ["TEXTAREA", "SELECT"].includes(active?.tagName) || active?.isContentEditable;
    if (event.key === "/" && !typing) { event.preventDefault(); $("suche").focus(); return; }
    if (typing || !$("video-ebene").hidden) return;
    if (event.key === " ") { event.preventDefault(); toggleAudio(); }
    // ⌘ ← / ⌘ → sind im Browser auch „Zurück“ und „Vorwärts“; das darf nicht zusätzlich die Seite wechseln.
    else if ((event.key === "ArrowRight" || event.key === "ArrowLeft") && (event.metaKey || event.ctrlKey) && !event.altKey && !event.shiftKey) {
      if (player.index < 0) return;
      event.preventDefault();
      if (event.key === "ArrowRight") nextTrack(); else previousTrack();
    }
  });
}

async function start() {
  $("app").hidden = false;
  $("anmelden").hidden = true;
  try {
    await loadLibrary();
    render();
  } catch (error) {
    if (state.token) $("inhalt").replaceChildren(emptyNote(`Die Bibliothek ließ sich nicht laden: ${error.message}`));
  }
}

document.addEventListener("DOMContentLoaded", () => {
  setupAudio(); setupVideo(); setupKeys();
  document.addEventListener("click", (event) => {
    if (!openMenu || openMenu.menu.contains(event.target)) return;
    // Ein zweiter Klick auf denselben „…“-Knopf schließt nur.
    if (openMenu.anchor.contains(event.target)) { event.stopPropagation(); event.preventDefault(); }
    closeMenu();
  }, true);
  document.addEventListener("keydown", (event) => { if (event.key === "Escape" && openMenu) { event.stopImmediatePropagation(); closeMenu(); } }, true);
  window.addEventListener("scroll", closeMenu, { passive: true });
  window.addEventListener("resize", closeMenu);
  window.addEventListener("hashchange", closeMenu);
  window.addEventListener("hashchange", () => {
    if ($("suche").value) $("suche").value = "";
    render(); $("inhalt").focus({ preventScroll: true }); window.scrollTo(0, 0);
  });
  let searchTimer;
  $("suche").addEventListener("input", () => { clearTimeout(searchTimer); searchTimer = setTimeout(render, 150); });
  $("suche").addEventListener("keydown", (event) => { if (event.key === "Escape") { $("suche").value = ""; render(); } });
  // Wer zurückkommt, sieht, was auf anderen Geräten geschaut wurde.
  document.addEventListener("visibilitychange", () => {
    const onOverview = /^#?(start|serien)?(\/|$)/.test(location.hash.replace(/^#/, "")) && !query();
    if (!document.hidden && state.token && $("video-ebene").hidden && onOverview) sync().then(render);
  });
  $("anmeldeformular").addEventListener("submit", async (event) => {
    event.preventDefault();
    $("anmeldefehler").textContent = "";
    const submit = event.submitter; if (submit) submit.disabled = true;
    try { await signIn($("token").value.trim(), $("merken").checked); await start(); }
    catch (error) { $("anmeldefehler").textContent = error.message; }
    finally { if (submit) submit.disabled = false; }
  });
  state.token = storedToken();
  try { state.ownPlays = new Map(JSON.parse(storage("local")?.getItem("mediaserver.webPlays") || "[]")); } catch { state.ownPlays = new Map(); }
  if (state.token) start(); else { $("anmelden").hidden = false; $("token").focus(); }
});
