// The site's history, from CHANGELOG.md: a page with every version (changelog.html) and the last ones on the home page, in place
// of <!-- whats-new -->. Run when the site is deployed (.github/workflows/pages.yml), so the site cannot be behind a release.
//   node tools/site_changelog.mjs <site> <out>
// <out> gets a copy of <site> with the pages made. CHANGELOG.md is Keep a Changelog: "## [x.y.z] - date", "### Added"...,
// "[x.y.z]: url" at the end.

import { cpSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const [site, out] = process.argv.slice(2)
if (!site || !out) { console.error('usage: node tools/site_changelog.mjs <site> <out>'); process.exit(2) }

const OPEN = 6   // versions unfolded on the page
const NEWS = 3   // versions on the home page
const LEADS = 3  // entries of each there

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

// **bold**, `code`, [text](url). Code first: what is in it is not markup.
function inline(text) {
  const code = []
  let s = text.replace(/`([^`]+)`/g, (_, c) => { code.push(`<code>${esc(c)}</code>`); return `\u0001${code.length - 1}\u0002` })
  s = esc(s)
  s = s.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
  s = s.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2">$1</a>')
  return s.replace(/\u0001(\d+)\u0002/g, (_, i) => code[+i])
}

// A version's text as blocks: paragraphs and lists (an entry may span lines; indented "- " are its sub-items).
function blocks(lines) {
  const out = []
  let list = null, item = null, para = null
  for (const raw of lines) {
    const l = raw.trimEnd()
    if (!l.trim()) { list = item = para = null; continue }
    const m = l.match(/^(\s*)- (.*)$/)
    if (m) {
      if (!list) { list = { items: [] }; out.push(list) }
      para = null
      if (m[1].length >= 2 && item) { item.subs.push(m[2]); item.last = 'sub' }
      else { item = { text: m[2], subs: [], last: 'text' }; list.items.push(item) }
    } else if (item) {
      if (item.last === 'sub') item.subs[item.subs.length - 1] += ' ' + l.trim()
      else item.text += ' ' + l.trim()
    } else if (para) {
      para.text += ' ' + l.trim()
    } else {
      para = { text: l.trim() }
      out.push(para)
    }
  }
  return out
}

function parse(text) {
  const lines = text.split(/\r?\n/)
  const links = new Map()
  for (const l of lines) { const m = l.match(/^\[([^\]]+)\]:\s*(\S+)/); if (m) links.set(m[1], m[2]) }
  const releases = []
  let r = null, sec = null
  for (const l of lines) {
    const h = l.match(/^## \[([^\]]+)\](?: - (\S+))?/)
    if (h) {
      r = null
      if (h[1].toLowerCase() !== 'unreleased') { r = { version: h[1], date: h[2] || '', link: links.get(h[1]), intro: [], sections: [] }; releases.push(r) }
      sec = null
      continue
    }
    if (/^## /.test(l)) { r = null; continue }
    if (!r || /^\[[^\]]+\]:/.test(l)) continue
    const c = l.match(/^### (.+)$/)
    if (c) { sec = { name: c[1].trim(), lines: [] }; r.sections.push(sec); continue }
    ;(sec ? sec.lines : r.intro).push(l)
  }
  return releases
}

function renderBlocks(bs) {
  return bs.map((b) => {
    if (!b.items) return `<p>${inline(b.text)}</p>`
    return `<ul>${b.items.map((i) => `<li>${inline(i.text)}${i.subs.length ? `<ul>${i.subs.map((s) => `<li>${inline(s)}</li>`).join('')}</ul>` : ''}</li>`).join('')}</ul>`
  }).join('\n')
}

function entries(r) {
  const out = []
  for (const s of r.sections) for (const b of blocks(s.lines)) if (b.items) out.push(...b.items)
  return out
}

// What an entry is about: its bold start, else its first sentence.
function lead(text) {
  const m = text.match(/^\*\*(.+?)\*\*/)
  if (m) return `<strong>${inline(m[1])}</strong>`
  const first = text.split(/(?<=[.:;])\s/)[0]
  return inline(first.length > 110 ? first.slice(0, 107).replace(/[`*]/g, '') + '…' : first)
}

const release = (r, open) => `<details class="release" id="v${esc(r.version)}"${open ? ' open' : ''}>
<summary><span class="ver">${esc(r.version)}</span><span class="date">${esc(r.date)}</span>${r.link ? `<a class="rel" href="${esc(r.link)}">release</a>` : ''}</summary>
${renderBlocks(blocks(r.intro))}
${r.sections.map((s) => `<h3 class="${esc(s.name.toLowerCase())}">${esc(s.name)}</h3>\n${renderBlocks(blocks(s.lines))}`).join('\n')}
</details>`

const news = (rs) => `<section id="news" class="news">
<h2>What's new</h2>
<div class="grid">
${rs.map((r) => {
    const all = entries(r)
    const more = all.length - LEADS
    return `<article class="card"><h3><a href="changelog.html#v${esc(r.version)}">${esc(r.version)}</a> <span class="date">${esc(r.date)}</span></h3>
<ul>${all.slice(0, LEADS).map((e) => `<li>${lead(e.text)}</li>`).join('')}</ul>${more > 0 ? `<p class="small"><a href="changelog.html#v${esc(r.version)}">and ${more} more</a></p>` : ''}</article>`
  }).join('\n')}
</div>
<p class="all"><a class="btn" href="changelog.html">All versions</a></p>
</section>`

const FILTER = `<script>
  // unfolds what a link points at; the filter keeps the versions whose text has all the words
  const open = () => { const t = location.hash && document.getElementById(location.hash.slice(1)); if (t && t.tagName === 'DETAILS') { t.open = true; t.scrollIntoView() } };
  addEventListener('hashchange', open); open();
  const all = [...document.querySelectorAll('.release')], box = document.getElementById('filter'), count = document.getElementById('count');
  const was = new Map(all.map((d) => [d, d.open]));
  box.addEventListener('input', () => {
    const words = box.value.toLowerCase().split(/\\s+/).filter(Boolean);
    let n = 0;
    for (const d of all) {
      const hit = words.every((w) => d.textContent.toLowerCase().includes(w));
      d.hidden = !hit;
      if (hit) n++;
      d.open = words.length ? hit : was.get(d);
    }
    count.textContent = words.length ? n + ' of ' + all.length + ' versions' : all.length + ' versions';
  });
</script>`

const index = readFileSync(join(site, 'index.html'), 'utf8')
const releases = parse(readFileSync('CHANGELOG.md', 'utf8'))
if (!releases.length) { console.error('no version in CHANGELOG.md'); process.exit(1) }
if (!index.includes('<!-- whats-new -->')) { console.error(`no <!-- whats-new --> in ${site}/index.html`); process.exit(1) }

cpSync(site, out, { recursive: true })
writeFileSync(join(out, 'index.html'), index.replace('<!-- whats-new -->', news(releases.slice(0, NEWS))))

// the page wears the home page's head, bar, footer and script
const take = (re) => (index.match(re) || [''])[0]
const name = take(/<title>[^<]*<\/title>/).replace(/<\/?title>/g, '')
const head = take(/<head>[\s\S]*?<\/head>/).replace(/<title>[^<]*<\/title>/, `<title>Changelog · ${name}</title>`)
  .replace(/<meta name="description"[^>]*>/, `<meta name="description" content="Every version of ${esc(name)}, newest first.">`)
const bar = take(/<header class="bar">[\s\S]*?<\/header>/).replace(/href="#"/g, 'href="index.html"').replace(/href="#(\w+)"/g, 'href="index.html#$1"')
const footer = take(/<footer>[\s\S]*?<\/footer>/)
const script = take(/<script>[\s\S]*?<\/script>/)
writeFileSync(join(out, 'changelog.html'), `<!doctype html>
<html lang="en">
${head}
<body>
${bar}

<main class="changelog">
<h1>Changelog</h1>
<p class="lead">Every version of ${esc(name)}, newest first. The format is <a href="https://keepachangelog.com/en/1.1.0/">Keep a Changelog</a>, the versions follow <a href="https://semver.org">semantic versioning</a>.</p>
<div class="filter"><input id="filter" type="search" placeholder="Filter by a word or a version" aria-label="Filter the versions by a word"><span id="count" class="small">${releases.length} versions</span></div>
${releases.map((r, i) => release(r, i < OPEN)).join('\n')}
</main>

${footer}
${script}
${FILTER}
</body>
</html>
`)
console.log(`${releases.length} versions: ${join(out, 'changelog.html')}, the last ${NEWS} on the home page`)
