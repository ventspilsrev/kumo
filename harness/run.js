// PC test harness: loads a REAL Paperback 0.8 extension bundle from a
// repository URL and runs home, search, details, chapters and pages against
// the live site.
//
// Usage:  node harness/run.js <repoURL> <SourceId> [search words]
// Example: node harness/run.js https://thenetsky.github.io/netskys-extensions/0.8 MangaKatana one piece
//
// The extension runs in an empty `vm` context that only contains
// runtime/prelude.js plus the `__host` bridge below. That mirrors the
// JavaScriptCore context on the iPad (no Node globals, no file access).
'use strict';
const vm = require('vm');
const fs = require('fs');
const path = require('path');

const [repoArg, sourceId, ...queryWords] = process.argv.slice(2);
if (!repoArg || !sourceId) {
  console.error('Usage: node harness/run.js <repoURL> <SourceId> [search words]');
  process.exit(2);
}
const repo = repoArg.replace(/\/+$/, '');
const query = queryWords.join(' ') || 'one piece';

// Same shape as the iPad's Safari 15 user agent. On the device this value
// comes from the real web view.
const USER_AGENT = 'Mozilla/5.0 (iPad; CPU OS 15_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6 Mobile/15E148 Safari/604.1';

const stats = { requests: 0, reused: 0, hosts: new Set(), events: [] };
const recent = new Map(); // recently answered GET requests
const cookies = []; // {name,value,domain,path,expires}
const state = new Map();

function cookieHeaderFor(url) {
  const h = new URL(url).hostname;
  const now = Date.now();
  return cookies
    .filter(c => (c.expires == null || c.expires > now) && (h === c.domain || h.endsWith('.' + c.domain)))
    .map(c => `${c.name}=${c.value}`).join('; ');
}
function storeSetCookies(url, list) {
  const h = new URL(url).hostname;
  for (const line of list) {
    const [pair, ...attrs] = line.split(';');
    const eq = pair.indexOf('=');
    if (eq < 1) continue;
    const c = { name: pair.slice(0, eq).trim(), value: pair.slice(eq + 1).trim(), domain: h, path: '/', expires: null };
    for (const a of attrs) {
      const [k, v = ''] = a.trim().split('=');
      if (/^domain$/i.test(k) && v) c.domain = v.replace(/^\./, '');
      if (/^path$/i.test(k) && v) c.path = v;
      if (/^expires$/i.test(k)) { const t = Date.parse(a.trim().slice(8)); if (!isNaN(t)) c.expires = t; }
      if (/^max-age$/i.test(k)) c.expires = Date.now() + Number(v) * 1000;
    }
    const i = cookies.findIndex(x => x.name === c.name && x.domain === c.domain);
    if (i >= 0) cookies.splice(i, 1);
    cookies.push(c);
  }
}

const host = {
  log(level, message) { console.log(`    [source ${level}] ${message}`); },
  setTimeout(fn, ms) { return setTimeout(fn, ms); },
  clearTimeout(id) { clearTimeout(id); },
  userAgent() { return USER_AGENT; },
  fetch(req, resolve, reject) {
    (async () => {
      const u = new URL(req.url);
      // Same rule as the app: http is upgraded to https, never used as is.
      if (u.protocol === 'http:') { u.protocol = 'https:'; req = { ...req, url: u.toString() }; }
      if (u.protocol !== 'https:') throw new Error(`Blocked non-HTTPS request to ${u.host}`);
      const headers = { ...req.headers };
      // Same rule as the app: an identical GET within 5 seconds is answered from memory.
      const recentKey = req.method === 'GET' && req.body == null
        ? u.toString() + '|' + Object.keys(headers).sort().map(k => `${k}=${headers[k]}`).join('&') : null;
      const hit = recentKey && recent.get(recentKey);
      if (hit && Date.now() - hit.time < 5000) { stats.reused++; return hit.answer; }
      stats.requests++;
      stats.hosts.add(u.host);
      const jar = cookieHeaderFor(req.url);
      if (jar && !Object.keys(headers).some(k => k.toLowerCase() === 'cookie')) headers.Cookie = jar;
      const res = await fetch(req.url, {
        method: req.method, headers, body: req.body ?? undefined,
        redirect: 'follow', signal: AbortSignal.timeout(req.timeoutMs)
      });
      storeSetCookies(req.url, res.headers.getSetCookie());
      const bytes = await res.arrayBuffer();
      const outHeaders = {};
      res.headers.forEach((v, k) => { outHeaders[k] = v; });
      const type = outHeaders['content-type'] || '';
      // Only decode text for text-like bodies; images stay bytes only.
      const text = /^image\/|octet-stream/i.test(type) ? '' : new TextDecoder('utf-8').decode(bytes);
      const answer = { status: res.status, headers: outHeaders, bytes, text };
      if (recentKey && text && res.status === 200 && bytes.byteLength < 300000) recent.set(recentKey, { time: Date.now(), answer });
      return answer;
    })().then(resolve, err => reject(`${err.name}: ${err.message} (${req.url})`));
  },
  cookiesGet() { return cookies.map(c => ({ ...c })); },
  cookieSet(c) {
    const i = cookies.findIndex(x => x.name === c.name && x.domain === c.domain);
    if (i >= 0) cookies.splice(i, 1);
    cookies.push({ ...c });
  },
  cookieRemove(c) {
    const i = cookies.findIndex(x => x.name === c.name && x.domain === c.domain);
    if (i >= 0) cookies.splice(i, 1);
  },
  stateGet(key) { return state.has(key) ? state.get(key) : null; },
  stateSet(key, json) { if (json == null) state.delete(key); else state.set(key, json); },
  event(name, payload) { stats.events.push({ name, payload }); }
};

function sniff(bytes) {
  const b = new Uint8Array(bytes.buffer ? bytes.buffer : bytes, bytes.byteOffset || 0, Math.min(12, bytes.byteLength));
  const hex = Buffer.from(b).toString('hex');
  if (hex.startsWith('ffd8ff')) return 'JPEG';
  if (hex.startsWith('89504e47')) return 'PNG';
  if (hex.startsWith('52494646') && hex.slice(16, 24) === '57454250') return 'WebP';
  if (hex.startsWith('47494638')) return 'GIF';
  if (hex.slice(8, 16) === '66747970') return 'AVIF/HEIF (not supported on iOS 15)';
  return `unknown (starts ${hex.slice(0, 16)})`;
}

const results = [];
async function step(name, fn) {
  const t = Date.now();
  try {
    const detail = await fn();
    results.push({ name, ok: true });
    console.log(`PASS  ${name}  (${Date.now() - t} ms)`);
    for (const line of [].concat(detail || [])) console.log(`      ${line}`);
  } catch (err) {
    results.push({ name, ok: false });
    console.log(`FAIL  ${name}  (${Date.now() - t} ms)`);
    console.log(`      ${err && err.message ? err.message : err}`);
    throw err;
  }
}

async function main() {
  console.log(`Repository: ${repo}`);
  console.log(`Source:     ${sourceId}\n`);

  // ---- repository index
  let entry;
  await step('repo: versioning.json loads and lists the source', async () => {
    if (!repo.startsWith('https://')) throw new Error('Repository URL must be https');
    const res = await fetch(`${repo}/versioning.json`, { signal: AbortSignal.timeout(20000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const index = await res.json();
    if (!Array.isArray(index.sources)) throw new Error('versioning.json has no "sources" list');
    entry = index.sources.find(s => s.id === sourceId);
    if (!entry) throw new Error(`"${sourceId}" not in repo. Available: ${index.sources.map(s => s.id).join(', ')}`);
    const types = index.builtWith && index.builtWith.types;
    if (!types || !String(types).startsWith('0.8')) throw new Error(`Incompatible: built with types "${types}" (need 0.8.x)`);
    return [`${entry.name} ${entry.version} by ${entry.author}, rating ${entry.contentRating}, intents ${entry.intents}, types ${types}`];
  });

  // ---- bundle
  let ctx;
  await step('bundle: source.js downloads and evaluates in an empty context', async () => {
    const res = await fetch(`${repo}/${sourceId}/source.js`, { signal: AbortSignal.timeout(60000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const code = await res.text();
    ctx = vm.createContext({ __host: host });
    const prelude = fs.readFileSync(path.join(__dirname, '..', 'runtime', 'prelude.js'), 'utf8');
    vm.runInContext(prelude, ctx, { filename: 'prelude.js' });
    vm.runInContext(code, ctx, { filename: `${sourceId}/source.js`, timeout: 10000 });
    const info = JSON.parse(ctx.__pb.info(sourceId));
    return [`${(code.length / 1024).toFixed(0)} KB, declares: ${info ? `${info.name} ${info.version}` : 'no Info object'}`];
  });

  const call = (method, args, onSection) => new Promise((resolve, reject) => {
    ctx.__pb.call(sourceId, method, JSON.stringify(args || []), json => resolve(JSON.parse(json)), msg => reject(new Error(msg)), onSection);
  });

  // ---- home
  await step('home: getHomePageSections', async () => {
    const sections = [];
    await call('getHomePageSections', [], json => sections.push(JSON.parse(json)));
    if (!sections.length) throw new Error('no sections returned');
    if (!sections.some(s => s.items && s.items.length)) throw new Error('all sections are empty');
    return sections.map(s => `"${s.title}": ${s.items.length} items${s.items[0] ? `, first: ${s.items[0].title}` : ''}`);
  });

  // ---- tags
  await step('filters: getSearchTags', async () => {
    const tags = await call('getSearchTags');
    if (!tags || !tags.length) throw new Error('no tag sections');
    return tags.map(s => `"${s.label}": ${s.tags.length} tags (${s.tags.slice(0, 5).map(t => t.label).join(', ')}...)`);
  });

  // ---- search
  let manga;
  await step(`search: getSearchResults("${query}")`, async () => {
    const page = await call('getSearchResults', [{ title: query, includedTags: [], excludedTags: [], parameters: {} }, null]);
    if (!page.results.length) throw new Error('no results');
    manga = page.results[0];
    return [`${page.results.length} results, next page: ${page.metadata ? JSON.stringify(page.metadata) : 'none'}`,
      ...page.results.slice(0, 3).map(r => `- ${r.title}  [id ${r.mangaId}]  ${r.subtitle || ''}`),
      `cover: ${manga.image}`];
  });

  // ---- details
  await step(`details: getMangaDetails("${manga.mangaId}")`, async () => {
    const d = await call('getMangaDetails', [manga.mangaId]);
    const i = d.mangaInfo;
    if (!i || !i.titles || !i.titles[0]) throw new Error('no title in details');
    const tags = (i.tags || []).flatMap(s => s.tags.map(t => t.label));
    return [`title: ${i.titles[0]}`, `status: ${i.status}, author: ${i.author}`,
      `tags: ${tags.slice(0, 8).join(', ')}`, `description: ${(i.desc || '').slice(0, 110)}...`];
  });

  // ---- chapters
  let chapter;
  await step('chapters: getChapters', async () => {
    const chapters = await call('getChapters', [manga.mangaId]);
    if (!chapters.length) throw new Error('no chapters');
    chapter = chapters[chapters.length - 1]; // oldest listed = usually chapter 1
    const c0 = chapters[0];
    return [`${chapters.length} chapters`, `newest: #${c0.chapNum} "${c0.name}" (${c0.time})`,
      `oldest: #${chapter.chapNum} "${chapter.name}" [id ${chapter.id}]`];
  });

  // ---- pages
  let pages;
  await step(`pages: getChapterDetails("${chapter.id}")`, async () => {
    const d = await call('getChapterDetails', [manga.mangaId, chapter.id]);
    pages = d.pages || [];
    if (!pages.length) throw new Error('chapter has no pages');
    if (pages.some(p => !/^https:\/\//.test(p))) throw new Error('a page URL is not https');
    return [`${pages.length} pages`, `first: ${pages[0]}`];
  });

  // ---- image
  await step('images: pages download through the source request manager', async () => {
    // First, second and middle page. One page alone can be a tiny cover or
    // credit image, so at least one of them must be a real-sized page.
    const picks = [...new Set([0, 1, Math.floor(pages.length / 2)])].filter(i => i < pages.length);
    const lines = [];
    let biggest = 0;
    for (const i of picks) {
      const img = await new Promise((resolve, reject) => ctx.__pb.image(sourceId, pages[i], resolve, m => reject(new Error(m))));
      if (img.status !== 200) throw new Error(`page ${i + 1}: HTTP ${img.status}`);
      const kind = sniff(img.bytes);
      if (/unknown/.test(kind)) throw new Error(`page ${i + 1} is not an image: ${kind}`);
      biggest = Math.max(biggest, img.bytes.byteLength);
      lines.push(`page ${i + 1}: HTTP 200, ${(img.bytes.byteLength / 1024).toFixed(0)} KB, ${kind}`);
    }
    if (biggest < 20 * 1024) throw new Error(`all sampled pages are under 20 KB, probably placeholders:\n      ${lines.join('\n      ')}`);
    return lines;
  });
}

main().catch(() => {}).finally(() => {
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed} passed, ${failed} failed. ` +
    `${stats.requests} requests (${stats.reused} repeats answered from memory) to: ${[...stats.hosts].join(', ') || 'none'}`);
  if (stats.events.length) console.log(`Events: ${JSON.stringify(stats.events)}`);
  process.exit(failed ? 1 : 0);
});
