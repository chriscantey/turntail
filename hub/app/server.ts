// Turntail hub app. Bind 127.0.0.1 only: the Tailscale identity headers are trusted because only Serve reaches it.

const PORT = Number(process.env.APP_PORT ?? 8080);
const ICECAST = process.env.ICECAST_URL ?? "http://127.0.0.1:8000";
const HUB_FQDN = process.env.HUB_FQDN ?? "turntail";
const SLOT_MS = Number(process.env.SLOT_MINUTES ?? 60) * 60_000;
const STATIONS_FILE = process.env.STATIONS_FILE ?? "/etc/turntail/stations.json";
const DATA_DIR = process.env.DATA_DIR ?? "./data";
const CAP = "turntail.internal/cap/role";
const OFFLINE_GRACE_MS = 60_000;
const MIN_REMAIN_MS = Number(process.env.MIN_REMAIN_MINUTES ?? 10) * 60_000;
const GRACE_MS = Number(process.env.GRACE_MINUTES ?? 2) * 60_000;
const WARN_MS = Number(process.env.WARN_MINUTES ?? 5) * 60_000;
const DISCOGS_TOKEN = process.env.DISCOGS_TOKEN ?? "";
const basic = (user: string, pw = "") => "Basic " + btoa(`${user}:${pw}`);
const ICECAST_ADMIN = basic("admin", process.env.ICECAST_ADMIN_PW);
const ICECAST_READER = basic("turntail", process.env.ICECAST_READER_PW);
const UA = "Turntail/0.1 (+https://github.com/chriscantey/turntail)";

type Station = { mount: string; name: string; avatar?: string };
type Live = { mount: string; since: number; until: number | null; endBy?: "queue" | "wrap" | "admin"; title: string; cover?: string };
type Queued = { mount: string; login: string; at: number };
type State = { live: Live | null; queue: Queued[]; house: boolean };
type Identity = { login: string; name: string; pic: string; admin: boolean; mounts: string[] };
type Listener = { login: string; name: string; pic: string; mount: string; since: number };

const statePath = `${DATA_DIR}/state.json`;
let state: State = { live: null, queue: [], house: true };
try { state = { ...state, ...JSON.parse(await Bun.file(statePath).text()) }; } catch {}
const HOUSE_MOUNT = process.env.HOUSE_MOUNT ?? "house";
const DEMO_MOUNT = process.env.DEMO_MOUNT ?? "demo";
const HUB_SOURCES = new Set([HOUSE_MOUNT, DEMO_MOUNT]);
const MUSIC_DIR = process.env.MUSIC_DIR ?? "/var/lib/turntail/music";
async function save() { await Bun.write(statePath, JSON.stringify(state, null, 2)); }

async function stations(): Promise<Station[]> {
  try {
    const raw = JSON.parse(await Bun.file(STATIONS_FILE).text()) as any[];
    return raw.map(s => ({ mount: String(s.mount), name: String(s.name ?? s.mount), avatar: s.avatar ? String(s.avatar) : undefined }));
  } catch { return []; }
}

function identity(req: Request): Identity | null {
  const login = req.headers.get("tailscale-user-login");
  if (!login) return null;
  let admin = false; const mounts: string[] = [];
  const caps = req.headers.get("tailscale-app-capabilities");
  if (caps) {
    try {
      const mine = JSON.parse(caps)[CAP];
      if (Array.isArray(mine)) for (const c of mine) {
        if (c?.role === "admin") admin = true;
        if (c?.role === "streamer" && typeof c.mount === "string") mounts.push(c.mount);
      }
    } catch {}
  }
  return { login, name: req.headers.get("tailscale-user-name") ?? login, pic: req.headers.get("tailscale-user-profile-pic") ?? "", admin, mounts };
}
const mayRun = (id: Identity, mount: string) => id.admin || id.mounts.includes(mount);

let mountsCache: { at: number; mounts: string[] } = { at: 0, mounts: [] };
async function icecastMounts(): Promise<string[]> {
  if (Date.now() - mountsCache.at < 2000) return mountsCache.mounts;
  let mounts: string[] = [];
  try {
    const r = await fetch(`${ICECAST}/admin/listmounts`, { headers: { authorization: ICECAST_ADMIN } });
    if (r.ok) mounts = [...(await r.text()).matchAll(/<source mount="\/([^"]+)"/g)].map(m => m[1]);
    else console.error("icecast listmounts", r.status);
  } catch (e) { console.error("icecast listmounts", String(e)); }
  mountsCache = { at: Date.now(), mounts };
  return mounts;
}

const listeners = new Map<string, Listener>();

let offlineSince: number | null = null;
async function tick() {
  const mounts = await icecastMounts();
  const now = Date.now();
  if (!state.live) return;
  const hasSource = mounts.includes(state.live.mount);
  if (!hasSource) { offlineSince ??= now; if (now - offlineSince > OFFLINE_GRACE_MS) { await handoff("source went away"); return; } }
  else offlineSince = null;
  if (state.queue.length && state.live.until == null) {
    const left = Math.min(SLOT_MS, Math.max(MIN_REMAIN_MS, SLOT_MS - (now - state.live.since)));
    state.live.until = now + left; state.live.endBy = "queue"; await save();
  }
  if (state.live.until != null && now >= state.live.until + GRACE_MS) { await handoff(state.live.endBy === "wrap" ? "streamer wrapped up" : "slot ended"); return; }
  if (!state.queue.length && state.live.until != null && state.live.endBy === "queue") { state.live.until = null; state.live.endBy = undefined; await save(); }
}
async function handoff(reason: string) {
  const ended = state.live?.mount ?? null;
  state.live = null; offlineSince = null;
  const next = state.queue.shift();
  if (next) state.live = { mount: next.mount, since: Date.now(), until: null, title: "" };
  await save();
  console.log(JSON.stringify({ t: new Date().toISOString(), ev: "handoff", reason, ended, next: next?.mount ?? null }));
}
setInterval(() => tick().catch(e => console.error("tick", e)), 5000);

const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
const deny = (why: string, status = 403) => json({ error: why }, status);

async function streamProxy(mount: string, id: Identity, req: Request) {
  const key = crypto.randomUUID();
  const upstream = await fetch(`${ICECAST}/${mount}`, { headers: { "icy-metadata": "0", authorization: ICECAST_READER }, signal: req.signal });
  if (!upstream.ok || !upstream.body) {
    if (upstream.status !== 404) console.error("icecast stream", mount, upstream.status);
    return deny("no source on that mount", 404);
  }
  listeners.set(key, { login: id.login, name: id.name, pic: id.pic, mount, since: Date.now() });
  const cleanup = () => listeners.delete(key);
  req.signal.addEventListener("abort", cleanup);
  const body = upstream.body.pipeThrough(new TransformStream({ flush: cleanup, cancel: cleanup }));
  return new Response(body, { headers: { "content-type": upstream.headers.get("content-type") ?? "audio/mpeg", "cache-control": "no-store, no-transform", "x-accel-buffering": "no" } });
}

// Music credits come from the file names (Pixabay: <creator>-<title words>-<id>.mp3), overridden by MUSIC_DIR/credits.json.
const CREDITS = JSON.parse(await Bun.file(new URL("./credits.json", import.meta.url).pathname).text());
let creditsCache: { at: number; body: any } | null = null;
async function credits() {
  if (creditsCache && Date.now() - creditsCache.at < 60_000) return creditsCache.body;
  const { readdir } = await import("node:fs/promises");
  let files: string[] = [];
  try { files = (await readdir(MUSIC_DIR)).filter(f => /\.(mp3|flac|m4a|ogg)$/i.test(f)).sort(); } catch {}
  let overrides: any[] = [];
  try { overrides = JSON.parse(await Bun.file(`${MUSIC_DIR}/credits.json`).text()); } catch {}
  const px = CREDITS.musicSources.pixabay;
  const music = files.map(f => {
    const o = overrides.find(x => x.file === f);
    const base = f.replace(/\.[^.]+$/, "");
    const m = base.match(/^(.+?)-(.+)-(\d+)$/);
    const guess = m ? { title: m[2].split("-").map(w => w ? w[0].toUpperCase() + w.slice(1) : w).join(" "), artist: m[1], url: px.trackUrl.replace("{id}", m[3]), source: px.name, license: px.license } : { title: base, artist: "", url: "", source: "", license: "" };
    return { file: f, ...guess, ...(o || {}) };
  });
  creditsCache = { at: Date.now(), body: { software: CREDITS.software, data: CREDITS.data, fonts: CREDITS.fonts ?? [], music, musicSource: px } };
  return creditsCache.body;
}

type Hit = { title: string; year?: string; format?: string; thumb?: string; source: string };
const lookupCache = new Map<string, { at: number; hits: Hit[] }>();
const coverCache = new Map<string, { body: Uint8Array; type: string }>();
// MusicBrainz allows one request per second. Newest query wins.
let mbLast = 0; let mbPending: { q: string; resolve: (h: Hit[]) => void } | null = null; let mbTimer: ReturnType<typeof setTimeout> | null = null;
function mbQueue(q: string, run: (q: string) => Promise<Hit[]>): Promise<Hit[]> {
  return new Promise(resolve => {
    if (mbPending) mbPending.resolve([]);
    mbPending = { q, resolve };
    if (mbTimer) clearTimeout(mbTimer);
    const wait = Math.max(0, 1100 - (Date.now() - mbLast));
    mbTimer = setTimeout(async () => { const job = mbPending; mbPending = null; mbTimer = null; if (!job) return; mbLast = Date.now(); job.resolve(await run(job.q)); }, wait);
  });
}
async function lookup(q: string): Promise<Hit[]> {
  const key = q.toLowerCase(); const c = lookupCache.get(key);
  if (c && Date.now() - c.at < 600_000) return c.hits;
  const songs = new Promise<Hit[]>(r => r([])).then(() => mbQueue(q, async (q): Promise<Hit[]> => {
    try {
      const r = await fetch(`https://musicbrainz.org/ws/2/recording/?fmt=json&limit=6&query=${encodeURIComponent(q)}`, { headers: { "User-Agent": UA }, signal: AbortSignal.timeout(7000) });
      if (!r.ok) return [];
      const j = await r.json();
      const seen = new Set<string>();
      return (j.recordings ?? []).map((x: any) => {
        const artist = x["artist-credit"]?.map((a: any) => a.name).join(", ") ?? "";
        const title = `${artist}${artist ? " - " : ""}${x.title ?? ""}`;
        const rel = x.releases?.[0];
        return { title, year: x["first-release-date"] ? String(x["first-release-date"]).slice(0, 4) : undefined, format: rel?.title ? `song, ${String(rel.title).slice(0, 28)}` : "song", source: "musicbrainz" } as Hit;
      }).filter((h: Hit) => h.title && !seen.has(h.title.toLowerCase()) && seen.add(h.title.toLowerCase()));
    } catch (e) { console.error("lookup songs", String(e)); return []; }
  }));
  const records = (async (): Promise<Hit[]> => {
    try {
      if (!DISCOGS_TOKEN) return [];
      const r = await fetch(`https://api.discogs.com/database/search?type=release&format=Vinyl&per_page=6&q=${encodeURIComponent(q)}`, { headers: { "User-Agent": UA, Authorization: `Discogs token=${DISCOGS_TOKEN}` }, signal: AbortSignal.timeout(4000) });
      if (!r.ok) return [];
      const j = await r.json();
      const seen = new Set<string>();
      return (j.results ?? []).map((x: any) => ({ title: String(x.title ?? ""), year: x.year ? String(x.year) : undefined, format: Array.isArray(x.format) ? x.format.slice(0, 2).join(", ") : "LP", thumb: x.thumb || undefined, source: "discogs" }))
        .filter((h: Hit) => h.title && !seen.has(h.title.toLowerCase()) && seen.add(h.title.toLowerCase()));
    } catch (e) { console.error("lookup records", String(e)); return []; }
  })();
  const b = await records;
  const hits = (b.length ? b.slice(0, 6) : (await songs).slice(0, 5)).map(h => ({ ...h, title: h.title.slice(0, 120) }));
  if (lookupCache.size > 500) lookupCache.delete(lookupCache.keys().next().value!);
  lookupCache.set(key, { at: Date.now(), hits });
  return hits;
}

const pub = new URL("./public/", import.meta.url).pathname;

Bun.serve({
  hostname: "127.0.0.1",
  port: PORT,
  idleTimeout: 0,
  async fetch(req) {
    const path = new URL(req.url).pathname;

    if (path === "/healthz") return new Response("ok");
    if (path === "/") return new Response(await Bun.file(pub + "index.html").text(), { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "content-security-policy": "frame-ancestors 'none'", "x-content-type-options": "nosniff" } });
    if (path === "/favicon.svg" || path === "/og.jpg" || path === "/icon-180.png") {
      const f = Bun.file(pub + path.slice(1)); const ct = path.endsWith(".svg") ? "image/svg+xml" : path.endsWith(".jpg") ? "image/jpeg" : "image/png";
      return (await f.exists()) ? new Response(f, { headers: { "content-type": ct, "cache-control": "public, max-age=86400" } }) : new Response("", { status: 404 });
    }
    if (path.startsWith("/fonts/") && /^\/fonts\/[a-z0-9-]+\.woff2$/.test(path)) {
      const f = Bun.file(pub + path.slice(1));
      return (await f.exists()) ? new Response(f, { headers: { "content-type": "font/woff2", "cache-control": "public, max-age=31536000, immutable" } }) : new Response("", { status: 404 });
    }

    const id = identity(req);
    if (!id) return deny("no Tailscale identity on this request. Open the page through Tailscale.");

    if (req.method === "GET" && path.startsWith("/stream/")) {
      const want = path.slice("/stream/".length);
      if (!/^[a-z0-9-]{1,32}$/.test(want)) return deny("bad mount", 404);
      let mount = want;
      if (want === "live") {
        if (state.live) mount = state.live.mount;
        else if (state.house && (await icecastMounts()).includes(HOUSE_MOUNT)) mount = HOUSE_MOUNT;
        else return deny("nobody is live", 404);
      }
      else if (!mayRun(id, want)) return deny("only that station's streamer or an admin can listen to a specific mount");
      if (!(await stations()).some(s => s.mount === mount)) return deny("unknown station", 404);
      return streamProxy(mount, id, req);
    }

    if (req.method === "GET" && path === "/api/state") {
      let [st, mounts] = await Promise.all([stations(), icecastMounts()]);
      const fresh = st.filter(x => id.mounts.includes(x.mount) && (x.name === x.mount || (!x.avatar && id.pic)));
      if (fresh.length) {
        try {
          const raw = JSON.parse(await Bun.file(STATIONS_FILE).text()) as any[];
          for (const x of raw) if (fresh.some(f => f.mount === x.mount)) { if (x.name === x.mount) x.name = id.name; if (!x.avatar && id.pic) x.avatar = id.pic; }
          await Bun.write(STATIONS_FILE, JSON.stringify(raw, null, 2) + "\n"); st = await stations();
        } catch (e) { console.error("station defaults", String(e)); }
      }
      return json({
        hub: HUB_FQDN, now: Date.now(), slotMinutes: SLOT_MS / 60_000, graceMs: GRACE_MS, warnMs: WARN_MS, minRemainMs: MIN_REMAIN_MS,
        me: { login: id.login, name: id.name, pic: id.pic, admin: id.admin, mounts: id.mounts },
        live: state.live, queue: state.queue.map(({ mount, at }) => ({ mount, at })),
        house: { enabled: state.house, mount: HOUSE_MOUNT, source: mounts.includes(HOUSE_MOUNT), playing: !state.live && state.house && mounts.includes(HOUSE_MOUNT) },
        clock: { mount: DEMO_MOUNT, source: mounts.includes(DEMO_MOUNT), live: state.live?.mount === DEMO_MOUNT },
        stations: st.filter(s => !HUB_SOURCES.has(s.mount)).map(s => ({ mount: s.mount, name: s.name, avatar: s.avatar, mine: mayRun(id, s.mount), source: mounts.includes(s.mount) })),
        listeners: [...listeners.values()].map(l => ({ login: l.login, name: l.name, pic: l.pic, since: l.since })),
      });
    }

    if (req.method === "GET" && path === "/api/cover") {
      const u = new URL(req.url).searchParams.get("u") ?? "";
      if (!/^https:\/\/(i\.discogs\.com|avatars\.githubusercontent\.com|lh3\.googleusercontent\.com|[a-z0-9.-]+\.gravatar\.com)\/[A-Za-z0-9_\-./=%?&:,]*$/.test(u)) return deny("not an allowed image host", 400);
      const c = coverCache.get(u); if (c) return new Response(c.body, { headers: { "content-type": c.type, "cache-control": "public, max-age=86400", "x-content-type-options": "nosniff" } });
      try { const r = await fetch(u, { headers: { "User-Agent": UA }, redirect: "error", signal: AbortSignal.timeout(5000) }); if (!r.ok) return deny("cover fetch failed", 502);
        const type = (r.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
        if (!/^image\/(jpeg|png|webp|gif)$/.test(type)) return deny("not an image", 502);
        const body = new Uint8Array(await r.arrayBuffer());
        if (body.length > 400_000) return deny("cover too large", 502);
        if (coverCache.size > 300) coverCache.delete(coverCache.keys().next().value!); coverCache.set(u, { body, type });
        return new Response(body, { headers: { "content-type": type, "cache-control": "public, max-age=86400", "x-content-type-options": "nosniff" } }); } catch { return deny("cover fetch failed", 502); }
    }
    if (req.method === "GET" && path === "/api/credits") return json(await credits());

    if (req.method === "GET" && path === "/api/lookup") {
      if (!id.admin && !id.mounts.length) return deny("streamers only");
      const q = (new URL(req.url).searchParams.get("q") ?? "").trim().slice(0, 80);
      if (q.length < 3) return json({ results: [] });
      return json({ results: await lookup(q) });
    }

    if (req.method !== "POST") return deny("not found", 404);
    if (req.headers.get("content-type")?.split(";")[0].trim() !== "application/json") return deny("json only", 415);
    const body = await req.json().catch(() => ({}));
    const audit = (ev: string, extra: Record<string, unknown> = {}) => console.log(JSON.stringify({ t: new Date().toISOString(), ev, who: id.login, admin: id.admin, ...extra }));

    if (path === "/api/golive") {
      const mount = String(body.mount ?? "");
      if (!(await stations()).some(s => s.mount === mount)) return deny("unknown station", 404);
      if (!mayRun(id, mount)) return deny("that is not your station");
      if (!(await icecastMounts()).includes(mount)) return deny("that station has no source connected yet. Check the station with sudo turntail-station status on the Pi, then go live.", 409);
      if (state.live?.mount === mount) return json({ ok: true, live: true });
      if (state.queue.some(q => q.mount === mount)) return json({ ok: true, queued: true });
      if (!state.live) { state.live = { mount, since: Date.now(), until: null, title: "" }; await save(); audit("golive", { mount }); return json({ ok: true, live: true }); }
      state.queue.push({ mount, login: id.login, at: Date.now() }); await save(); audit("queued", { mount });
      return json({ ok: true, queued: true, position: state.queue.length });
    }
    if (path === "/api/leave") {
      const mine = (await stations()).map(s => s.mount).filter(m => mayRun(id, m));
      if (state.live && mine.includes(state.live.mount)) { audit("leave-live", { mount: state.live.mount }); await handoff("streamer left"); }
      state.queue = state.queue.filter(q => !mine.includes(q.mount)); await save();
      return json({ ok: true });
    }
    if (path === "/api/wrap") {
      if (!state.live || !mayRun(id, state.live.mount)) return deny("you are not live");
      const minutes = Number(body.minutes);
      if (![0, 5, 15, 30].includes(minutes)) return deny("minutes must be 0, 5, 15 or 30", 400);
      if (minutes === 0) { audit("wrap-now", { mount: state.live.mount }); await handoff("streamer ended"); return json({ ok: true }); }
      const at = Date.now() + minutes * 60_000;
      if (state.live.until != null && state.live.until <= at) return json({ ok: true, until: state.live.until, unchanged: true });
      state.live.until = at; state.live.endBy = "wrap"; await save(); audit("wrap", { mount: state.live.mount, minutes });
      return json({ ok: true, until: at });
    }
    if (path === "/api/station") {
      const mount = String(body.mount ?? ""); const name = String(body.name ?? "").trim().replace(/\s+/g, " ").slice(0, 40);
      if (!mayRun(id, mount)) return deny("that is not your station");
      if (name.length < 1) return deny("name is empty", 400);
      try {
        const raw = JSON.parse(await Bun.file(STATIONS_FILE).text()) as any[];
        const st = raw.find(x => x.mount === mount); if (!st) return deny("unknown station", 404);
        st.name = name; await Bun.write(STATIONS_FILE, JSON.stringify(raw, null, 2) + "\n");
      } catch (e) { console.error("station rename", String(e)); return deny("could not save the name", 500); }
      audit("station-rename", { mount, name });
      return json({ ok: true, name });
    }
    if (path === "/api/title") {
      if (!state.live || !mayRun(id, state.live.mount)) return deny("you are not live");
      state.live.title = String(body.title ?? "").slice(0, 120);
      const cover = String(body.cover ?? ""); state.live.cover = /^https:\/\/i\.discogs\.com\//.test(cover) ? cover : undefined; await save();
      return json({ ok: true });
    }
    if (path.startsWith("/api/admin/")) {
      if (!id.admin) return deny("admins only");
      const action = path.slice("/api/admin/".length);
      if (action === "skip") { audit("admin-skip", { mount: state.live?.mount }); await handoff("admin skipped"); return json({ ok: true }); }
      if (action === "extend") { if (!state.live) return deny("nobody is live", 409); state.live.until = (state.live.until ?? Date.now()) + SLOT_MS; state.live.endBy = "admin"; await save(); audit("admin-extend"); return json({ ok: true, until: state.live.until }); }
      if (action === "clock") {
        const on = !!body.enabled;
        if (on) { if (state.live?.mount === DEMO_MOUNT) return json({ ok: true }); if (!(await icecastMounts()).includes(DEMO_MOUNT)) return deny("the clock source is not running on the hub", 409);
          if (state.live) return deny("someone is on the air, skip them first", 409); state.live = { mount: DEMO_MOUNT, since: Date.now(), until: null, title: "" }; await save(); audit("admin-clock", { enabled: true }); return json({ ok: true }); }
        if (state.live?.mount === DEMO_MOUNT) { audit("admin-clock", { enabled: false }); await handoff("clock off"); }
        return json({ ok: true });
      }
      if (action === "house") { state.house = !!body.enabled; await save(); audit("admin-house", { enabled: state.house }); return json({ ok: true, house: state.house }); }
      if (action === "kick") { const mount = String(body.mount ?? ""); audit("admin-kick", { mount }); if (state.live?.mount === mount) await handoff("admin kicked"); state.queue = state.queue.filter(q => q.mount !== mount); await save(); return json({ ok: true }); }
    }
    return deny("not found", 404);
  },
});
console.log(JSON.stringify({ t: new Date().toISOString(), ev: "start", port: PORT, icecast: ICECAST, hub: HUB_FQDN }));
