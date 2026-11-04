// The site's history, from CHANGELOG.md: a page with every version (changelog.html) and the last ones on the home page, in place
// of <!-- whats-new -->. Run when the site is deployed (.github/workflows/pages.yml), so the site cannot be behind a release.
// It also makes the site's classic presentation, classic/ (a line of plain links, a column of text with the news beside it,
// site/classic/classic.css), from the same sources: the home page's sections and the versions, their links moved into classic/.
// Each modern page's footer links its classic page ("Classic version"), each classic page the modern one ("Modern version").
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
const CLASSIC = 'classic'                                    // the classic pages' folder in the site
const CLASSIC_LINK = '<a href="classic/">Classic version</a>' // in the home page's footer
const PAGES = ['index.html', 'changelog.html']               // the modern pages, each with a classic one of the same name
const SECTION_PAGES = { features: 'features.html' }          // the home's sections that are pages of their own in classic/

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


const take = (re, s = index) => (s.match(re) || [''])[0]
const inner = (html) => html.trim().replace(/^<[^>]*>/, '').replace(/<\/[^>]*>$/, '').trim()
const text = (html) => html.replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim()
const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
const name = inner(take(/<title>[^<]*<\/title>/))
const footer = take(/<footer>[\s\S]*?<\/footer>/)
if (!footer.includes(CLASSIC_LINK)) { console.error(`no ${CLASSIC_LINK} in the footer of ${site}/index.html`); process.exit(1) }

const changelogIntro = `<p class="lead">Every version of ${esc(name)}, newest first. The format is <a href="https://keepachangelog.com/en/1.1.0/">Keep a Changelog</a>, the versions follow <a href="https://semver.org">semantic versioning</a>.</p>
<div class="filter"><input id="filter" type="search" placeholder="Filter by a word or a version" aria-label="Filter the versions by a word"><span id="count" class="small">${releases.length} versions</span></div>
${releases.map((r, i) => release(r, i < OPEN)).join('\n')}`

// the page wears the home page's head, bar, footer and script
const head = take(/<head>[\s\S]*?<\/head>/).replace(/<title>[^<]*<\/title>/, `<title>Changelog · ${name}</title>`)
  .replace(/<meta name="description"[^>]*>/, `<meta name="description" content="Every version of ${esc(name)}, newest first.">`)
const bar = take(/<header class="bar">[\s\S]*?<\/header>/).replace(/href="#"/g, 'href="index.html"').replace(/href="#(\w+)"/g, 'href="index.html#$1"')
const script = take(/<script>[\s\S]*?<\/script>/)
writeFileSync(join(out, 'changelog.html'), `<!doctype html>
<html lang="en">
${head}
<body>
${bar}

<main class="changelog">
<h1>Changelog</h1>
${changelogIntro}
</main>

${footer.replace(CLASSIC_LINK, `<a href="${CLASSIC}/changelog.html">Classic version</a>`)}
${script}
${FILTER}
</body>
</html>
`)
console.log(`${releases.length} versions: ${join(out, 'changelog.html')}, the last ${NEWS} on the home page`)

// The classic pages. A link of the home page, moved into classic/: a page keeps its name (its classic one), a section of the
// home is its classic page or the classic home's, a file stays the site's ("img/x.png" -> "../img/x.png").
function classicLink(href) {
  if (/^[a-z]+:/i.test(href)) return href
  const [path, id] = href.split('#')
  if (!path) return id ? SECTION_PAGES[id] ?? `index.html#${id}` : 'index.html'
  return PAGES.includes(path) ? href : `../${href}`
}
const classic = (html) => html.replace(/\b(href|src)="([^"]*)"/g, (_, attr, v) => `${attr}="${classicLink(v)}"`)

const hero = take(/<section class="hero">[\s\S]*?<\/section>/)
const title = inner(take(/<h1>[\s\S]*?<\/h1>/, hero))
const logo = take(/<img class="mark" src="[^"]*"/, hero).replace(/.*src="/, '').slice(0, -1)
const description = take(/<meta name="description" content="[^"]*">/).replace(/.*content="/, '').slice(0, -2)
const wide = take(/<figure class="shot wide">[\s\S]*?<\/figure>/)
const gallery = take(/<section class="gallery">[\s\S]*?<\/section>/)
const download = take(/<section id="\w+" class="download">[\s\S]*?<\/section>/)
const cards = [...take(/<section id="features"[\s\S]*?<\/section>/).matchAll(/<article class="card">\s*<h3>([\s\S]*?)<\/h3>([\s\S]*?)<\/article>/g)]
  .map(([, h, body]) => ({ title: h, body: body.trim(), id: slug(text(h)), summary: text(body).split(/(?<=[.;:])\s/)[0].replace(/[.;:]$/, '') }))
for (const [what, part] of Object.entries({ hero, title, logo, wide, gallery, download, features: cards.length })) {
  if (!part) { console.error(`no ${what} in ${site}/index.html for the classic pages`); process.exit(1) }
}

// the nav line: the home, the modern bar's links, the screenshots after the features
const nav = [['index.html', 'home'], ...[...take(/<nav id="nav">[\s\S]*?<\/nav>/).matchAll(/<a href="([^"]*)">([^<]*)<\/a>/g)].map(([, h, l]) => [classicLink(h), l.toLowerCase()])]
const after = nav.findIndex(([h]) => h === SECTION_PAGES.features)
nav.splice(after < 0 ? nav.length : after + 1, 0, ['screenshots.html', 'screenshots'])

const [footBefore, footAfter] = inner(footer).split(CLASSIC_LINK)
const classicPage = (file, { title: t, description: d, modern, main, scripts = '' }) => writeFileSync(join(out, CLASSIC, file), `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>${t}</title>
<meta name="description" content="${d}">
${classic(take(/<link rel="icon"[^>]*>/))}
<link rel="stylesheet" href="classic.css">
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<div class="page">
<header class="masthead">
<img src="${classicLink(logo)}" alt="" width="48" height="48">
<a class="name" href="index.html">${title}</a>
<span class="tagline">${description}</span>
</header>
<nav class="site" aria-label="Site">
${nav.map(([h, l], i) => `${i ? '<span class="sep" aria-hidden="true">-</span>' : ''}<a href="${h}"${h === file ? ' aria-current="page"' : ''}>${l}</a>`).join('\n')}
</nav>
${main}
<footer class="foot">
${classic(footBefore)}<a href="${modern}">Modern version</a>${classic(footAfter)}
</footer>
</div>
${scripts}</body>
</html>
`)

const newsItem = (r) => `<div class="item">
${r.date ? `<time class="date" datetime="${esc(r.date)}">${esc(r.date)}</time>: ` : ''}<a href="changelog.html#v${esc(r.version)}">${esc(name)} ${esc(r.version)}</a> released.
<ul>${entries(r).slice(0, LEADS).map((e) => `<li>${lead(e.text)}</li>`).join('')}</ul>
</div>`

classicPage('index.html', {
  title: name, description, modern: '../', main: `<div class="columns">
<main id="main">
<h1>Welcome to ${title}</h1>
<p>${classic(inner(take(/<p class="lead">[\s\S]*?<\/p>/, hero)))}</p>
<p class="download">${[...take(/<div class="actions">[\s\S]*?<\/div>/, hero).matchAll(/<a [^>]*?href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/g)].map(([, h, l]) => `<a href="${classicLink(h)}">${l}</a>`).join(' - ')}
<br><span class="small">${inner(take(/<p class="small">[\s\S]*?<\/p>/, hero))}</span></p>
<h2>Features</h2>
<ul class="features">
${cards.map((c) => `<li><a href="${SECTION_PAGES.features}#${c.id}">${c.title}</a>: ${c.summary}</li>`).join('\n')}
</ul>
${classic(download)}
</main>
<aside aria-labelledby="news">
<h2 id="news">News</h2>
${releases.slice(0, NEWS).map(newsItem).join('\n')}
<p><a class="all" href="changelog.html">- all news -</a></p>
</aside>
</div>`,
})
classicPage(SECTION_PAGES.features, {
  title: `Features · ${name}`, description: `What ${esc(name)} does.`, modern: '../#features', main: `<main id="main">
<h1>Features</h1>
${cards.map((c) => `<article class="card" id="${c.id}">\n<h2>${c.title}</h2>\n${classic(c.body)}\n</article>`).join('\n')}
</main>`,
})
classicPage('screenshots.html', {
  title: `Screenshots · ${name}`, description: `Screenshots of ${esc(name)}.`, modern: '../', main: `<main id="main">
<h1>Screenshots</h1>
${classic(wide)}
${classic(gallery)}
</main>`,
  scripts: `${classic(take(/<script src="[^"]*"[^>]*><\/script>/))}\n`,
})
classicPage('changelog.html', {
  title: `Changelog · ${name}`, description: `Every version of ${esc(name)}, newest first.`, modern: '../changelog.html', main: `<main id="main" class="changelog">
<h1>Changelog</h1>
${changelogIntro}
</main>`,
  scripts: `${FILTER}\n`,
})
console.log(`the classic pages: ${join(out, CLASSIC)}`)
