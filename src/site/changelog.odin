package tk_site

// The history of a site, from its CHANGELOG.md (Keep a Changelog: "## [x.y.z] - date", "### Added"..., "[x.y.z]: url" at the end):
// a page with every version (changelog/) and the last ones on the home page, in place of <!-- whats-new -->. It also makes the
// site's classic presentation, classic/ (a line of plain links, a column of text with the news beside it, classic/classic.css of the
// site), from the same sources: the home page's sections and the versions, their links moved into classic/. Each modern page's
// footer links its classic page ("Classic version"), each classic page the modern one ("Modern version").
// The home page is the project's own template: its head, bar, hero, features, gallery, download section and footer are what the
// other pages wear (docs/site.md says which).
// Every page is a folder and its index.html, and every link names the folder ("changelog/", "../"): the address a reader sees
// and shares is the one the canonical tag gives (build_meta).

import "core:fmt"
import "core:os"
import "core:strings"

HOME_PAGE         :: "index.html"
CHANGELOG         :: "changelog"                         // the changelog's folder
CHANGELOG_ADDRESS :: CHANGELOG + "/"                     // its address, from the root
CHANGELOG_PAGE    :: CHANGELOG + "/" + HOME_PAGE         // its file
FEATURES_ID       :: "features"                          // the home's section that is a page of its own in classic/
SCREENSHOTS       :: "screenshots"                       // the classic page of the pictures
CLASSIC           :: "classic"                           // the classic pages' folder in the site
CLASSIC_LINK      :: `<a href="classic/">Classic version</a>`   // in the home page's footer
WHATS_NEW         :: "<!-- whats-new -->"
VERSIONS_OPEN     :: 6                     // versions unfolded on the page
NEWS_VERSIONS     :: 3                     // versions on the home page
NEWS_LEADS        :: 3                     // entries of each there
LEAD_LONGEST      :: 110                   // in UTF-16 units, as a JS string counts
LEAD_CUT          :: 107
@(private) SUB_ITEM_INDENT :: 2

Changelog_Options :: struct {
	changes:      string,   // the CHANGELOG.md
	// In the home page, this text is the last version ("": none): its download links can name the files of that release, a
	// download at once rather than a page of GitHub (a site deployed with each release cannot name a file not there yet).
	version_mark: string,
	// The systems of the home page's download, the first shown when the reader's is not known (download.odin): in place
	// of its <!-- download --> and <!-- download-others --> marks.
	downloads:    []Download,
	// The site's Meta: its name titles the pages, its links fill the home page's <!-- site-nav --> and <!-- site-footer -->
	// (frame.odin), its shop (Meta.shop) adds the shop's pages. A home page without the marks needs only the name ("": the
	// home page's title).
	meta:         Meta,
}

Item :: struct {
	text:   string,
	subs:   [dynamic]string,
	in_sub: bool,   // the last line went to a sub-item
}

Block :: struct {
	text:    string,          // a paragraph
	items:   [dynamic]^Item,  // a list
	is_list: bool,
}

// /^(\s*)- (.*)$/: the indentation counts characters, as a JS string does.
list_line :: proc(l: string) -> (indent: int, text: string, ok: bool) {
	start := len(l)
	for r, i in l {
		if !is_js_space(r) { start = i; break }
		indent += 1
	}
	rest := l[start:]
	if !strings.has_prefix(rest, "- ") || has_line_end(rest) { return 0, "", false }
	return indent, rest[len("- "):], true
}

// /^### (.+)$/
section_line :: proc(l: string) -> (name: string, ok: bool) {
	if !strings.has_prefix(l, "### ") { return }
	name = l[len("### "):]
	return name, name != "" && !has_line_end(name)
}

// A version's text as blocks: paragraphs and lists (an entry may span lines; indented "- " are its sub-items).
blocks :: proc(lines: []string) -> []^Block {
	out := make([dynamic]^Block, context.temp_allocator)
	list, para: ^Block
	item: ^Item
	for raw in lines {
		l := strings.trim_right_proc(raw, is_js_space)
		if js_trim(l) == "" {
			list, para, item = nil, nil, nil
			continue
		}
		if indent, text, ok := list_line(l); ok {
			if list == nil {
				list = new(Block, context.temp_allocator)
				list.is_list = true
				list.items = make([dynamic]^Item, context.temp_allocator)
				append(&out, list)
			}
			para = nil
			if indent >= SUB_ITEM_INDENT && item != nil {
				append(&item.subs, text)
				item.in_sub = true
			} else {
				item = new(Item, context.temp_allocator)
				item.text = text
				item.subs = make([dynamic]string, context.temp_allocator)
				append(&list.items, item)
			}
		} else if item != nil {
			if item.in_sub {
				last := &item.subs[len(item.subs) - 1]
				last^ = cat(last^, " ", js_trim(l))
			} else {
				item.text = cat(item.text, " ", js_trim(l))
			}
		} else if para != nil {
			para.text = cat(para.text, " ", js_trim(l))
		} else {
			para = new(Block, context.temp_allocator)
			para.text = js_trim(l)
			append(&out, para)
		}
	}
	return out[:]
}

Section :: struct {
	name:  string,
	lines: [dynamic]string,
}

Release :: struct {
	version, date, link: string,
	intro:               [dynamic]string,
	sections:            [dynamic]^Section,
}

// /^## \[([^\]]+)\]/: the version, and what follows it on the line.
version_heading :: proc(l: string) -> (version, rest: string, ok: bool) {
	if !strings.has_prefix(l, "## ") { return }
	return bracket(l[len("## "):])
}

// What starts a text and is not a blank: \S+.
first_word :: proc(s: string) -> string {
	for r, i in s {
		if is_js_space(r) { return s[:i] }
	}
	return s
}

parse_changelog :: proc(text: string) -> []^Release {
	lines := split_lines(text)
	links := make(map[string]string, context.temp_allocator)
	for l in lines {
		name, rest, ok := bracket(l)
		if !ok || !strings.has_prefix(rest, ":") { continue }
		url := first_word(strings.trim_left_proc(rest[1:], is_js_space))
		if url != "" { links[name] = url }
	}
	releases := make([dynamic]^Release, context.temp_allocator)
	r: ^Release
	sec: ^Section
	for l in lines {
		if version, rest, ok := version_heading(l); ok {
			r, sec = nil, nil
			if js_lower(version) != "unreleased" {
				r = new(Release, context.temp_allocator)
				r.version = version
				if strings.has_prefix(rest, " - ") { r.date = first_word(rest[len(" - "):]) }
				r.link = links[version]
				r.intro = make([dynamic]string, context.temp_allocator)
				r.sections = make([dynamic]^Section, context.temp_allocator)
				append(&releases, r)
			}
			continue
		}
		if strings.has_prefix(l, "## ") { r = nil; continue }
		if r == nil { continue }
		if _, rest, ok := bracket(l); ok && strings.has_prefix(rest, ":") { continue }
		if name, ok := section_line(l); ok {
			sec = new(Section, context.temp_allocator)
			sec.name = js_trim(name)
			sec.lines = make([dynamic]string, context.temp_allocator)
			append(&r.sections, sec)
			continue
		}
		append(sec != nil ? &sec.lines : &r.intro, l)
	}
	return releases[:]
}

render_blocks :: proc(bs: []^Block) -> string {
	b := strings.builder_make(context.temp_allocator)
	for block, i in bs {
		if i > 0 { strings.write_byte(&b, '\n') }
		if !block.is_list {
			put(&b, "<p>", inline(block.text), "</p>")
			continue
		}
		strings.write_string(&b, "<ul>")
		for item in block.items {
			put(&b, "<li>", inline(item.text))
			if len(item.subs) > 0 {
				strings.write_string(&b, "<ul>")
				for sub in item.subs { put(&b, "<li>", inline(sub), "</li>") }
				strings.write_string(&b, "</ul>")
			}
			strings.write_string(&b, "</li>")
		}
		strings.write_string(&b, "</ul>")
	}
	return strings.to_string(b)
}

entries :: proc(r: ^Release) -> []^Item {
	out := make([dynamic]^Item, context.temp_allocator)
	for s in r.sections {
		for block in blocks(s.lines[:]) {
			if block.is_list { append(&out, ..block.items[:]) }
		}
	}
	return out[:]
}

// What an entry is about: its bold start, else its first sentence.
lead :: proc(text: string) -> string {
	if bold, _, ok := match_bold(text, 0); ok { return cat("<strong>", inline(bold), "</strong>") }
	first := first_sentence(text)
	if utf16_length(first) <= LEAD_LONGEST { return inline(first) }
	cut, _ := strings.replace_all(utf16_prefix(first, LEAD_CUT), "`", "", context.temp_allocator)
	cut, _ = strings.replace_all(cut, "*", "", context.temp_allocator)
	return inline(cat(cut, "…"))
}

leads :: proc(all: []^Item) -> string {
	b := strings.builder_make(context.temp_allocator)
	for e in all[:min(NEWS_LEADS, len(all))] { put(&b, "<li>", lead(e.text), "</li>") }
	return strings.to_string(b)
}

release_html :: proc(r: ^Release, open: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, `<details class="release" id="v`, esc(r.version), `"`, open ? " open" : "", ">\n")
	put(&b, `<summary><span class="ver">`, esc(r.version), `</span><span class="date">`, esc(r.date), "</span>")
	if r.link != "" { put(&b, `<a class="rel" href="`, esc(r.link), `">release</a>`) }
	put(&b, "</summary>\n", render_blocks(blocks(r.intro[:])), "\n")
	for s, i in r.sections {
		if i > 0 { strings.write_byte(&b, '\n') }
		put(&b, `<h3 class="`, esc(js_lower(s.name)), `">`, esc(s.name), "</h3>\n", render_blocks(blocks(s.lines[:])))
	}
	put(&b, "\n</details>")
	return strings.to_string(b)
}

news_html :: proc(rs: []^Release) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, `<section id="news" class="news">
<h2>What's new</h2>
<div class="grid">
`)
	for r, i in rs {
		if i > 0 { strings.write_byte(&b, '\n') }
		all := entries(r)
		anchor := cat(`<a href="`, CHANGELOG_ADDRESS, `#v`, esc(r.version), `">`)
		put(&b, `<article class="card"><h3>`, anchor, esc(r.version), `</a> <span class="date">`, esc(r.date), "</span></h3>\n<ul>", leads(all), "</ul>")
		if more := len(all) - NEWS_LEADS; more > 0 { put(&b, `<p class="small">`, anchor, "and ", fmt.tprint(more), " more</a></p>") }
		strings.write_string(&b, "</article>")
	}
	put(&b, `
</div>
<p class="all"><a class="btn" href="`, CHANGELOG_ADDRESS, `">All versions</a></p>
</section>`)
	return strings.to_string(b)
}

FILTER :: `<script>
  // unfolds what a link points at; the filter keeps the versions whose text has all the words
  const open = () => { const t = location.hash && document.getElementById(location.hash.slice(1)); if (t && t.tagName === 'DETAILS') { t.open = true; t.scrollIntoView() } };
  addEventListener('hashchange', open); open();
  const all = [...document.querySelectorAll('.release')], box = document.getElementById('filter'), count = document.getElementById('count');
  const was = new Map(all.map((d) => [d, d.open]));
  box.addEventListener('input', () => {
    const words = box.value.toLowerCase().split(/\s+/).filter(Boolean);
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

// A link of the home page, as the classic pages point it, root-absolute (relative_links makes it relative to each page): the
// home and the changelog are their classic pages, the features section is the classic features page, another section is
// the classic home's, a file or another page stays the site's ("img/x.png" -> "/img/x.png").
classic_link :: proc(href: string) -> string {
	if has_scheme(href) || strings.has_prefix(href, "/") { return href }
	path, id := href, ""
	if hash := strings.index_byte(href, '#'); hash >= 0 { path, id = href[:hash], href[hash + 1:] }
	if path == "" || path == "." || path == "./" {
		if id == "" { return cat("/", CLASSIC, "/") }
		return id == FEATURES_ID ? cat("/", CLASSIC, "/", FEATURES_ID, "/") : cat("/", CLASSIC, "/#", id)
	}
	if path == CHANGELOG_ADDRESS { return cat("/", CLASSIC, "/", href) }
	return root_of(href, "")
}

// A piece of the home page for a page at `page` (its file, from the root: "changelog/index.html"): every link made relative
// to that page, a section of the home ("#features") the home's.
from_home :: proc(html, page: string) -> string {
	s := rooted(html, "")
	s, _ = strings.replace_all(s, ` href="#"`, ` href="/"`, context.temp_allocator)
	s, _ = strings.replace_all(s, ` href="#`, ` href="/#`, context.temp_allocator)
	return relative_links(s, page)
}

// The root-absolute href and src of `html` made relative to the page `page` (its file, from the root) by the shortest way:
// from "classic/index.html", "/classic/features/" is "features/" and "/classic/" is "./"; from "changelog/index.html", "/"
// is "../". (site_relative climbs to the root every time: "../classic/features/".)
relative_links :: proc(html, page: string) -> string {
	from := strings.split(path_dir(page), "/", context.temp_allocator)
	if path_dir(page) == "" { from = nil }
	b := strings.builder_make(context.temp_allocator)
	i := 0
	scan: for i < len(html) {
		for attr in ([?]string{`href="/`, `src="/`}) {
			if !strings.has_prefix(html[i:], attr) || strings.has_prefix(html[i + len(attr):], "/") { continue }
			v0 := i + len(attr) - 1
			v1 := strings.index_byte(html[v0:], '"')
			if v1 < 0 { break scan }
			strings.write_string(&b, attr[:len(attr) - 1])
			strings.write_string(&b, relative_address(html[v0:v0 + v1], from))
			i = v0 + v1
			continue scan
		}
		strings.write_byte(&b, html[i])
		i += 1
	}
	strings.write_string(&b, html[i:])
	return strings.to_string(b)
}

// A root-absolute address ("/classic/features/#x") from the folder `from` (its parts: {"classic"}).
@(private)
relative_address :: proc(address: string, from: []string) -> string {
	path, rest := address, ""
	if at := strings.index_any(address, "#?"); at >= 0 { path, rest = address[:at], address[at:] }
	path = path[1:]
	file := path[strings.last_index_byte(path, '/') + 1:]
	folders := strings.split(path[:len(path) - len(file)], "/", context.temp_allocator)
	folders = folders[:len(folders) - 1]   // (the empty part after the last "/")
	common := 0
	for common < len(from) && common < len(folders) && from[common] == folders[common] { common += 1 }
	b := strings.builder_make(context.temp_allocator)
	for _ in common ..< len(from) { strings.write_string(&b, "../") }
	for f in folders[common:] { put(&b, f, "/") }
	strings.write_string(&b, file)
	if strings.builder_len(b) == 0 { strings.write_string(&b, "./") }
	strings.write_string(&b, rest)
	return strings.to_string(b)
}

// Every /\b(href|src)="([^"]*)"/ of a piece of HTML, moved into classic/ (root-absolute: classic_link).
classic_html :: proc(html: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(html); {
		attribute := ""
		if strings.has_prefix(html[i:], `href="`) { attribute = "href" } else if strings.has_prefix(html[i:], `src="`) { attribute = "src" }
		if attribute != "" && (i == 0 || !is_word_byte(html[i - 1])) {
			body := i + len(attribute) + len(`="`)
			if close := strings.index_byte(html[body:], '"'); close >= 0 {
				put(&b, attribute, `="`, classic_link(html[body:body + close]), `"`)
				i = body + close + 1
				continue
			}
		}
		strings.write_byte(&b, html[i])
		i += 1
	}
	return strings.to_string(b)
}

Card :: struct {
	title, body, id, summary: string,
}

// /<article class="card">\s*<h3>([\s\S]*?)<\/h3>([\s\S]*?)<\/article>/g
feature_cards :: proc(section: string) -> []Card {
	OPEN :: `<article class="card">`
	out := make([dynamic]Card, context.temp_allocator)
	from := 0
	for {
		at := strings.index(section[from:], OPEN)
		if at < 0 { break }
		from += at + len(OPEN)
		h := strings.trim_left_proc(section[from:], is_js_space)
		if !strings.has_prefix(h, "<h3>") { continue }
		h = h[len("<h3>"):]
		title_end := strings.index(h, "</h3>")
		if title_end < 0 { break }
		rest := h[title_end + len("</h3>"):]
		body_end := strings.index(rest, "</article>")
		if body_end < 0 { break }
		title, body := h[:title_end], rest[:body_end]
		summary := first_sentence(plain_text(body))
		if summary != "" && strings.index_byte(".;:", summary[len(summary) - 1]) >= 0 { summary = summary[:len(summary) - 1] }
		append(&out, Card{title = title, body = js_trim(body), id = slug(plain_text(title)), summary = summary})
		from = len(section) - len(rest) + body_end + len("</article>")
	}
	return out[:]
}

Link :: struct {
	href, label: string,
}

// /<a href="([^"]*)"[^>]*>([^<]*)<\/a>/g: the href first, other attributes after it (the nav's "Buy license" has a class)
nav_links :: proc(nav: string) -> []Link {
	OPEN :: `<a href="`
	out := make([dynamic]Link, context.temp_allocator)
	from := 0
	for {
		at := strings.index(nav[from:], OPEN)
		if at < 0 { break }
		body := from + at + len(OPEN)
		from = body
		quote := strings.index_byte(nav[body:], '"')
		if quote < 0 { break }
		close := strings.index_byte(nav[body + quote:], '>')
		if close < 0 { break }
		text := body + quote + close + 1
		stop := strings.index_byte(nav[text:], '<')
		if stop < 0 { break }
		if !strings.has_prefix(nav[text + stop:], "</a>") { continue }
		append(&out, Link{nav[body:body + quote], nav[text:text + stop]})
		from = text + stop + len("</a>")
	}
	return out[:]
}

// /<a [^>]*?href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/g
action_links :: proc(html: string) -> []Link {
	OPEN :: "<a "
	HREF :: `href="`
	out := make([dynamic]Link, context.temp_allocator)
	from := 0
	next: for {
		at := strings.index(html[from:], OPEN)
		if at < 0 { break }
		start := from + at + len(OPEN)
		from = start
		tag_end := strings.index_byte(html[start:], '>')
		if tag_end < 0 { tag_end = len(html) - start }
		// (the first href that the rest of the expression can follow: a lazy match stops at the first that works)
		for p := start; p <= start + tag_end; p += 1 {
			if !strings.has_prefix(html[p:], HREF) { continue }
			body := p + len(HREF)
			quote := strings.index_byte(html[body:], '"')
			if quote < 0 { continue }
			close := strings.index_byte(html[body + quote:], '>')
			if close < 0 { continue }
			label := body + quote + close + 1
			stop := strings.index(html[label:], "</a>")
			if stop < 0 { continue }
			append(&out, Link{html[body:body + quote], html[label:label + stop]})
			from = label + stop + len("</a>")
			continue next
		}
	}
	return out[:]
}

// The text of a link's content: its markup gone (a button's logo, the spans of its lines), a space where a tag was, one space
// between words. A download button says what it does (its get-main): the files are the download section's, as plain links.
plain_label :: proc(label: string) -> string {
	html := label
	MAIN :: `class="get-main"`
	if at := strings.index(html, MAIN); at >= 0 {
		open := strings.index_byte(html[at:], '>')
		close := open < 0 ? -1 : strings.index(html[at + open:], "</span>")
		if close >= 0 { html = html[at + open + 1:at + open + close] }
	}
	b := strings.builder_make(context.temp_allocator)
	space := false
	for i := 0; i < len(html); i += 1 {
		c := html[i]
		if c == '<' {
			if close := strings.index_byte(html[i:], '>'); close >= 0 { i += close; space = true; continue }
		}
		if c == ' ' || c == '\n' || c == '\t' || c == '\r' { space = true; continue }
		if space && strings.builder_len(b) > 0 { strings.write_byte(&b, ' ') }
		space = false
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

Classic_Frame :: struct {
	icon, logo, title, tagline: string,
	nav:                        []Link,
	foot_before, foot_after:    string,
}

// A classic page. Its addresses are root-absolute ("/classic/features/"): the page is made relative to `file` at the end.
Classic_Page :: struct {
	file:    string,   // from the root: "classic/features/index.html"
	address: string,   // its own, root-absolute: "/classic/features/" (the nav marks it current)
	title, description, modern, main, scripts: string,
}

// The address of a classic page, root-absolute ("": the classic home), and its file.
@(private)
classic_address :: proc(name: string) -> string { return name == "" ? cat("/", CLASSIC, "/") : cat("/", CLASSIC, "/", name, "/") }
@(private)
classic_file :: proc(name: string) -> string { return name == "" ? cat(CLASSIC, "/", HOME_PAGE) : cat(CLASSIC, "/", name, "/", HOME_PAGE) }

classic_page :: proc(frame: Classic_Frame, p: Classic_Page) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>`, p.title, `</title>
<meta name="description" content="`, p.description, `">
`, classic_html(frame.icon), `
<link rel="stylesheet" href="/`, CLASSIC, `/classic.css">
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<div class="page">
<header class="masthead">
<img src="`, classic_link(frame.logo), `" alt="" width="48" height="48">
<a class="name" href="/`, CLASSIC, `/">`, frame.title, `</a>
<span class="tagline">`, frame.tagline, `</span>
</header>
<nav class="site" aria-label="Site">
`)
	for link, i in frame.nav {
		if i > 0 { strings.write_string(&b, "\n<span class=\"sep\" aria-hidden=\"true\">-</span>") }
		put(&b, `<a href="`, link.href, `"`, link.href == p.address ? ` aria-current="page"` : "", ">", link.label, "</a>")
	}
	put(&b, `
</nav>
`, p.main, `
<footer class="foot">
`, classic_html(frame.foot_before), `<a href="`, p.modern, `">Modern version</a>`, classic_html(frame.foot_after), `
</footer>
</div>
`, p.scripts, `</body>
</html>
`)
	return relative_links(strings.to_string(b), p.file)
}

news_item :: proc(r: ^Release, name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<div class=\"item\">\n")
	if r.date != "" { put(&b, `<time class="date" datetime="`, esc(r.date), `">`, esc(r.date), "</time>: ") }
	put(&b, `<a href="`, classic_address(CHANGELOG), `#v`, esc(r.version), `">`, esc(name), " ", esc(r.version), "</a> released.\n<ul>", leads(entries(r)), "</ul>\n</div>")
	return strings.to_string(b)
}

Page :: struct {
	path, text: string,   // the path is the site's
}

// Every page this step makes, from the home page and the versions. `site_name` titles them ("": the home page's title).
// why: what the home page lacks.
make_pages :: proc(index: string, releases: []^Release, site_name := "") -> (pages: []Page, why: string) {
	if !strings.contains(index, WHATS_NEW) { return nil, cat("no ", WHATS_NEW) }
	shown := releases[:min(NEWS_VERSIONS, len(releases))]
	out := make([dynamic]Page, context.temp_allocator)
	append(&out, Page{HOME_PAGE, replace_text(index, WHATS_NEW, news_html(shown))})

	title_at, title_end, has_title := title_span(index)
	name := site_name != "" ? site_name : (has_title ? inner(index[title_at:title_end]) : "")
	footer := between(index, "<footer>", "</footer>")
	if !strings.contains(footer, CLASSIC_LINK) { return nil, cat("no ", CLASSIC_LINK, " in the footer") }

	versions := strings.builder_make(context.temp_allocator)
	put(&versions, `<p class="lead">Every version of `, esc(name), ", newest first. The format is ", `<a href="https://keepachangelog.com/en/1.1.0/">Keep a Changelog</a>, the versions follow <a href="https://semver.org">semantic versioning</a>.</p>
<div class="filter"><input id="filter" type="search" placeholder="Filter by a word or a version" aria-label="Filter the versions by a word"><span id="count" class="small">`, fmt.tprint(len(releases)), " versions</span></div>\n")
	for r, i in releases {
		if i > 0 { strings.write_byte(&versions, '\n') }
		strings.write_string(&versions, release_html(r, i < VERSIONS_OPEN))
	}
	changelog_intro := strings.to_string(versions)

	// the page wears the home page's head, bar, footer and script
	head := between(index, "<head>", "</head>")
	if at, end, ok := title_span(head); ok { head = replace_span(head, cat("<title>Changelog · ", esc(name), "</title>"), at, end) }
	if at, end, ok := tag_span(head, `<meta name="description"`); ok {
		head = replace_span(head, cat(`<meta name="description" content="Every version of `, esc(name), `, newest first.">`), at, end)
	}
	bar := between(index, `<header class="bar">`, "</header>")
	script := between(index, "<script>", "</script>")
	modern_foot := replace_text(footer, CLASSIC_LINK, cat(`<a href="`, CLASSIC, "/", CHANGELOG_ADDRESS, `">Classic version</a>`))
	append(&out, Page{CHANGELOG_PAGE, from_home(cat(`<!doctype html>
<html lang="en">
`, head, `
<body>
`, bar, `

<main class="changelog">
<h1>Changelog</h1>
`, changelog_intro, `
</main>

`, modern_foot, `
`, script, `
`, FILTER, `
</body>
</html>
`), CHANGELOG_PAGE)})

	hero := between(index, `<section class="hero">`, "</section>")
	title := inner(between(hero, "<h1>", "</h1>"))
	logo, _ := quoted_value(hero, `<img class="mark" src="`, "")
	description, _ := quoted_value(index, `<meta name="description" content="`, ">")
	wide := between(index, `<figure class="shot wide">`, "</figure>")
	gallery := between(index, `<section class="gallery">`, "</section>")
	download := download_section(index)
	cards := feature_cards(between(index, `<section id="features"`, "</section>"))
	parts := [?]struct {what, part: string}{{"hero", hero}, {"title", title}, {"logo", logo}, {"wide", wide}, {"gallery", gallery}, {"download", download}}
	for p in parts {
		if p.part == "" { return nil, cat("no ", p.what, " for the classic pages") }
	}
	if len(cards) == 0 { return nil, "no features for the classic pages" }

	// the nav line: the home, the modern bar's links, the screenshots after the features
	nav := make([dynamic]Link, context.temp_allocator)
	append(&nav, Link{classic_address(""), "home"})
	for link in nav_links(between(index, `<nav id="nav">`, "</nav>")) { append(&nav, Link{classic_link(link.href), js_lower(link.label)}) }
	after := len(nav)
	for link, i in nav {
		if link.href == classic_address(FEATURES_ID) { after = i + 1; break }
	}
	inject_at(&nav, after, Link{classic_address(SCREENSHOTS), "screenshots"})

	icon := ""
	if at, end, ok := tag_span(index, `<link rel="icon"`); ok { icon = index[at:end] }
	foot := strings.split(inner(footer), CLASSIC_LINK, context.temp_allocator)
	frame := Classic_Frame{icon = icon, logo = logo, title = title, tagline = description, nav = nav[:], foot_before = foot[0], foot_after = foot[1]}

	home_main := strings.builder_make(context.temp_allocator)
	put(&home_main, `<div class="columns">
<main id="main">
<h1>Welcome to `, title, `</h1>
<p>`, classic_html(inner(between(hero, `<p class="lead">`, "</p>"))), `</p>
<p class="download">`)
	for link, i in action_links(between(hero, `<div class="actions">`, "</div>")) {
		if i > 0 { strings.write_string(&home_main, " - ") }
		put(&home_main, `<a href="`, classic_link(link.href), `">`, plain_label(link.label), "</a>")
	}
	put(&home_main, `
<br><span class="small">`, classic_html(inner(between(hero, `<p class="small">`, "</p>"))), `</span></p>
<h2>Features</h2>
<ul class="features">
`)
	for c, i in cards {
		if i > 0 { strings.write_byte(&home_main, '\n') }
		put(&home_main, `<li><a href="`, classic_address(FEATURES_ID), "#", c.id, `">`, c.title, "</a>: ", c.summary, "</li>")
	}
	put(&home_main, `
</ul>
`, classic_html(download), `
</main>
<aside aria-labelledby="news">
<h2 id="news">News</h2>
`)
	for r, i in shown {
		if i > 0 { strings.write_byte(&home_main, '\n') }
		strings.write_string(&home_main, news_item(r, name))
	}
	put(&home_main, `
<p><a class="all" href="`, classic_address(CHANGELOG), `">- all news -</a></p>
</aside>
</div>`)
	append(&out, Page{classic_file(""), classic_page(frame, {
		file = classic_file(""), address = classic_address(""), title = esc(name), description = description, modern = "/",
		main = strings.to_string(home_main),
	})})

	features_main := strings.builder_make(context.temp_allocator)
	strings.write_string(&features_main, "<main id=\"main\">\n<h1>Features</h1>\n")
	for c, i in cards {
		if i > 0 { strings.write_byte(&features_main, '\n') }
		put(&features_main, `<article class="card" id="`, c.id, "\">\n<h2>", c.title, "</h2>\n", classic_html(c.body), "\n</article>")
	}
	strings.write_string(&features_main, "\n</main>")
	append(&out, Page{classic_file(FEATURES_ID), classic_page(frame, {
		file = classic_file(FEATURES_ID), address = classic_address(FEATURES_ID), title = cat("Features · ", esc(name)),
		description = cat("What ", esc(name), " does."), modern = cat("/#", FEATURES_ID),
		main = strings.to_string(features_main),
	})})

	append(&out, Page{classic_file(SCREENSHOTS), classic_page(frame, {
		file = classic_file(SCREENSHOTS), address = classic_address(SCREENSHOTS), title = cat("Screenshots · ", esc(name)),
		description = cat("Screenshots of ", esc(name), "."), modern = "/",
		main = cat("<main id=\"main\">\n<h1>Screenshots</h1>\n", classic_html(wide), "\n", classic_html(gallery), "\n</main>"),
		scripts = cat(classic_html(script_with_src(index)), "\n"),
	})})

	append(&out, Page{classic_file(CHANGELOG), classic_page(frame, {
		file = classic_file(CHANGELOG), address = classic_address(CHANGELOG), title = cat("Changelog · ", esc(name)),
		description = cat("Every version of ", esc(name), ", newest first."), modern = cat("/", CHANGELOG_ADDRESS), main = cat("<main id=\"main\" class=\"changelog\">\n<h1>Changelog</h1>\n", changelog_intro, "\n</main>"),
		scripts = cat(FILTER, "\n"),
	})})
	return out[:], ""
}

// The home page with the last version where it says `mark` ("": as it is).
with_version :: proc(index, version, mark: string) -> string {
	if mark == "" { return index }
	s, _ := strings.replace_all(index, mark, version, context.temp_allocator)
	return s
}

// <out> gets a copy of <site> with the pages made. What it had besides stays.
build_changelog :: proc(site, out: string, o: Changelog_Options) -> bool {
	index, has_index := read_utf8(cat(site, "/", HOME_PAGE))
	changes, has_changes := read_utf8(o.changes)
	if !has_index || !has_changes { return false }
	releases := parse_changelog(changes)
	if len(releases) == 0 { fmt.eprintfln("site: no version in %s", o.changes); return false }
	home, dl_why := with_downloads(index, o.downloads)
	if dl_why != "" { fmt.eprintfln("site: %s/%s: %s", site, HOME_PAGE, dl_why); return false }
	framed, frame_why := with_frame(home, o.meta)
	if frame_why != "" { fmt.eprintfln("site: %s/%s: %s", site, HOME_PAGE, frame_why); return false }
	made, why := make_pages(with_version(framed, releases[0].version, o.version_mark), releases, o.meta.name)
	if why != "" { fmt.eprintfln("site: %s/%s: %s", site, HOME_PAGE, why); return false }
	pages := make([dynamic]Page, context.temp_allocator)
	append(&pages, ..made)
	// (the shop's pages are pages of the site like the others: build_meta then gives them their canonical address)
	if shop, sells := o.meta.shop.?; sells { append(&pages, ..licence_pages(shop)) }
	if !copy_site(site, out) { return false }
	for page in pages {
		// (every page is a folder of its own: classic/features/index.html)
		path := cat(out, "/", page.path)
		folder := path[:strings.last_index_byte(path, '/')]
		if err := os.make_directory_all(folder); err != nil && err != .Exist { fmt.eprintfln("site: %s: %v", folder, err); return false }
		if !write_text(path, page.text) { return false }
	}
	fmt.printfln("%d versions: %s/%s, the last %d on the home page", len(releases), out, CHANGELOG_PAGE, NEWS_VERSIONS)
	fmt.printfln("the classic pages: %s/%s", out, CLASSIC)
	return true
}
