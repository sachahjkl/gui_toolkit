package tk_site

// What a page says when it is shared, and the files around the pages. Every page of <out> (a copy of <site>, or <site> itself) gets
// its canonical address, Open Graph and Twitter tags, from its own title and description; the home page its structured data. A
// redirect or a page marked noindex is left alone. Writes feed.xml (Atom, from CHANGELOG.md), sitemap.xml, site.webmanifest,
// llms.txt and a 404.html if there is none; on a domain of its own, robots.txt and favicon.ico. The sharing card (img/card.png)
// is drawn once, by hand (draw_card), and kept in the repository.

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import "../ascii"

// What a project says of itself: the one place for its address, names and colours.
Meta :: struct {
	url:          string,   // where the site is published, with its final "/"
	name:         string,
	repository:   string,
	tagline:      string,
	changes:      string,   // the CHANGELOG.md
	card:         string,   // the sharing card, in the site ("img/card.png")
	logo:         string,   // the logo, in the site ("img/logo.png")
	logo_file:    string,   // the logo in the repository, for the card ("site/img/logo.png")
	theme:        string,   // the background colour, "#111111"
	accent:       string,
	author:       string,
	author_url:   string,
	publisher:    string,
	ld_type:      string,        // the home's structured data: its schema.org type
	ld_fields:    [][2]string,   // and what it says besides the names (after "image", before "author")
	root_domain:  bool,     // a domain of its own answers for /robots.txt and /favicon.ico; github.io does not
	ico:          string,   // its favicon.ico in the repository ("": none)
	card_title:   string,   // the card's title, HTML
	card_size:    int,      // its font size, px
	card_logo:    int,      // the logo's size on it, px
	card_font:    string,   // its font-family
	changelog_page: string,                      // the changelog's page in the site ("": CHANGELOG_PAGE)
	version_anchor: proc(version: string) -> string,   // a version's anchor in it (nil: "v" and the version: "v1.2.3")
}

// Where a version is told: the changelog's page and the version's anchor in it.
@(private)
version_address :: proc(m: Meta, version: string) -> string {
	page := m.changelog_page != "" ? m.changelog_page : CHANGELOG_PAGE
	anchor := m.version_anchor != nil ? m.version_anchor(version) : cat("v", version)
	return cat(m.url, page, "#", anchor)
}

@(private) NOT_LISTED :: "404.html"
FEED_FILE :: "feed.xml"
FEED_VERSIONS :: 30
@(private) FEED_DATE_LENGTH :: len("2026-11-06")
@(private) PNG_WIDTH_AT :: 16
@(private) PNG_HEIGHT_AT :: 20
@(private) CARD_BROWSERS :: [?]string{
	"C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
	"C:/Program Files/Google/Chrome/Application/chrome.exe",
	"/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser",
}

// file:// for a path, what a browser opens.
file_url :: proc(path: string) -> string {
	abs, err := os.get_absolute_path(path, context.temp_allocator)
	if err != nil { abs = path }
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "file://")
	if !strings.has_prefix(abs, "/") && !strings.has_prefix(abs, "\\") { strings.write_byte(&b, '/') }
	for i in 0 ..< len(abs) {
		c := abs[i]
		switch {
		case c == '\\':
			strings.write_byte(&b, '/')
		case is_word_byte(c), strings.index_byte("/:.-~", c) >= 0:
			strings.write_byte(&b, c)
		case:
			fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}

card_html :: proc(m: Meta, logo_url: string) -> string {
	return fmt.tprintf(`<!doctype html><meta charset="utf-8"><style>

html, body {{ margin: 0; width: 1200px; height: 630px; overflow: hidden; background: #111; color: #f2f2f2; }}
main {{ box-sizing: border-box; width: 1200px; height: 630px; padding: 0 72px 68px; display: flex; flex-direction: column; justify-content: flex-end;
  font-family: %s; }}
img {{ display: block; width: %dpx; height: %dpx; margin: 0 0 18px -6px; }}
h1 {{ margin: 0; font-size: %dpx; line-height: 1.02; font-weight: 700; letter-spacing: -0.035em; }}
h1 span {{ color: #8a8a8a; }} h1 em {{ font-style: normal; color: %s; }}
p {{ margin: 22px 0 0; font-size: 42px; line-height: 1.2; font-weight: 400; color: #a3a3a3; }}
</style><main><img src="%s" alt=""><h1>%s</h1><p>%s</p></main>`, m.card_font, m.card_logo, m.card_logo, m.card_size, m.accent, logo_url, m.card_title, m.tagline)
}

// The card (site/<card>), in a local Chromium, once: the site only carries the picture. It is one call with no page to drive, so
// no DevTools. `site`: the repository's site folder.
draw_card :: proc(m: Meta, site: string) -> bool {
	browser := os.get_env("CHROME", context.temp_allocator)
	if browser == "" || !os.exists(browser) {
		browser = ""
		browsers := CARD_BROWSERS
		for b in browsers {
			if os.exists(b) { browser = b; break }
		}
	}
	if browser == "" { fmt.eprintln("site: no Chromium found: set CHROME"); return false }
	dir, err := os.make_directory_temp("", "site-card-*", context.temp_allocator)
	if err != nil { fmt.eprintfln("site: no temporary folder: %v", err); return false }
	defer os.remove_all(dir)
	page := cat(dir, "/card.html")
	picture := cat(dir, "/out.png")
	if !write_text(page, card_html(m, file_url(m.logo_file))) { return false }
	state, _, _, run_err := os.process_exec({command = {browser, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files", cat("--user-data-dir=", dir, "/profile"),
		"--virtual-time-budget=5000", "--force-device-scale-factor=1", "--window-size=1200,630", cat("--screenshot=", picture), file_url(page)}}, context.temp_allocator)
	if run_err != nil || !state.exited || state.exit_code != 0 || !os.exists(picture) { fmt.eprintfln("site: %s drew nothing", browser); return false }
	to := cat(site, "/", m.card)
	if copy_err := os.copy_file(to, picture); copy_err != nil { fmt.eprintfln("site: %s: %v", to, copy_err); return false }
	fmt.println(to)
	return true
}

Feed_Version :: struct {
	version, date: string,
	lines:         [dynamic]string,
}

// /(?: - (\d{4}-\d{2}-\d{2}))?/ after a version: a heading with no date is no version of the feed.
heading_date :: proc(rest: string) -> string {
	if !strings.has_prefix(rest, " - ") || len(rest) < len(" - ") + FEED_DATE_LENGTH { return "" }
	date := rest[len(" - "):][:FEED_DATE_LENGTH]
	for i in 0 ..< len(date) {
		dash := i == 4 || i == 7
		if dash ? date[i] != '-' : !(date[i] >= '0' && date[i] <= '9') { return "" }
	}
	return date
}

// CHANGELOG.md: "## [x.y.z] - date", then its text.
feed_versions :: proc(text: string) -> []^Feed_Version {
	out := make([dynamic]^Feed_Version, context.temp_allocator)
	r: ^Feed_Version
	for l in split_lines(text) {
		if version, rest, ok := version_heading(l); ok {
			r = nil
			if date := heading_date(rest); date != "" {
				r = new(Feed_Version, context.temp_allocator)
				r.version, r.date = version, date
				r.lines = make([dynamic]string, context.temp_allocator)
				append(&out, r)
			}
			continue
		}
		_, after, bracketed := bracket(l)
		if strings.has_prefix(l, "## ") || (bracketed && strings.has_prefix(after, ":")) { r = nil; continue }
		if r != nil { append(&r.lines, l) }
	}
	return out[:]
}

// Where /<li>.*?<\/li>/ at `at` ends. -1: it is not there.
@(private)
list_item_end :: proc(s: string, at: int) -> int {
	if !strings.has_prefix(s[at:], "<li>") { return -1 }
	body := at + len("<li>")
	close := strings.index(s[body:], "</li>")
	if close < 0 || has_line_end(s[body:body + close]) { return -1 }
	return body + close + len("</li>")
}

// A version's text as HTML: its headings and its entries, an entry possibly on several lines.
feed_body :: proc(lines: []string) -> string {
	flat := strings.builder_make(context.temp_allocator)
	item := ""
	has_item := false
	flush :: proc(b: ^strings.Builder, item: string, has_item: ^bool) {
		if has_item^ { put(b, "<li>", inline(item), "</li>") }
		has_item^ = false
	}
	for raw in lines {
		l := js_trim(raw)
		if name, ok := section_line(l); ok {
			flush(&flat, item, &has_item)
			put(&flat, "<h3>", esc(name), "</h3>")
		} else if strings.has_prefix(l, "- ") && !has_line_end(l) {
			flush(&flat, item, &has_item)
			item, has_item = l[len("- "):], true
		} else if l == "" {
			flush(&flat, item, &has_item)
		} else if has_item {
			item = cat(item, " ", l)
		} else {
			put(&flat, "<p>", inline(l), "</p>")
		}
	}
	flush(&flat, item, &has_item)

	s := strings.to_string(flat)
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); {
		end := list_item_end(s, i)
		if end < 0 {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		for {
			next := list_item_end(s, end)
			if next < 0 { break }
			end = next
		}
		put(&b, "<ul>", s[i:end], "</ul>")
		i = end
	}
	return strings.to_string(b)
}

feed_xml :: proc(m: Meta, rs: []^Feed_Version) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>`, m.url, `</id>
  <title>`, esc(m.name), `: releases</title>
  <subtitle>`, esc(m.tagline), `</subtitle>
  <link rel="self" type="application/atom+xml" href="`, m.url, FEED_FILE, `"/>
  <link rel="alternate" type="text/html" href="`, m.url, `"/>
  <icon>`, m.url, m.logo, `</icon>
  <author><name>`, m.author, `</name><uri>`, m.author_url, `</uri></author>
  <updated>`, rs[0].date, "T00:00:00Z</updated>\n")
	for r, i in rs {
		if i > 0 { strings.write_byte(&b, '\n') }
		address := version_address(m, r.version)
		put(&b, `  <entry>
    <id>`, address, `</id>
    <title>`, esc(m.name), " ", esc(r.version), `</title>
    <link rel="alternate" type="text/html" href="`, address, `"/>
    <updated>`, r.date, `T00:00:00Z</updated>
    <content type="html">`, esc(feed_body(r.lines[:])), `</content>
  </entry>`)
	}
	strings.write_string(&b, "\n</feed>\n")
	return strings.to_string(b)
}

// A JSON string, as JSON.stringify writes it.
@(private)
json_string :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\r': strings.write_string(&b, `\r`)
		case '\t': strings.write_string(&b, `\t`)
		case '\b': strings.write_string(&b, `\b`)
		case '\f': strings.write_string(&b, `\f`)
		case:
			if r < 0x20 { fmt.sbprintf(&b, `\u%04x`, r) } else { strings.write_rune(&b, r) }
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// The home's data, as JSON.stringify(..., null, 2) writes it.
structured_data :: proc(m: Meta) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, "{\n  \"@context\": \"https://schema.org\",\n  \"@type\": ", json_string(m.ld_type), ",\n  \"name\": ", json_string(m.name),
		",\n  \"description\": ", json_string(m.tagline), ",\n  \"url\": ", json_string(m.url), ",\n  \"image\": ", json_string(cat(m.url, m.card)))
	for f in m.ld_fields { put(&b, ",\n  ", json_string(f[0]), ": ", json_string(f[1])) }
	put(&b, ",\n  \"author\": {\n    \"@type\": \"Person\",\n    \"name\": ", json_string(m.author), ",\n    \"url\": ", json_string(m.author_url),
		"\n  },\n  \"publisher\": {\n    \"@type\": \"Organization\",\n    \"name\": ", json_string(m.publisher), ",\n    \"url\": ", json_string(m.author_url), "\n  }\n}")
	return strings.to_string(b)
}

web_manifest :: proc(m: Meta, logo_size: string) -> string {
	return cat("{\n  \"name\": ", json_string(m.name), ",\n  \"short_name\": ", json_string(m.name), ",\n  \"description\": ", json_string(m.tagline), `,
  "lang": "en",
  "start_url": "./",
  "scope": "./",
  "display": "browser",
  "background_color": `, json_string(m.theme), ",\n  \"theme_color\": ", json_string(m.theme), `,
  "icons": [
    {
      "src": `, json_string(m.logo), ",\n      \"sizes\": ", json_string(logo_size), `,
      "type": "image/png"
    }
  ]
}
`)
}

// What goes before a page's </head>. The title and the description are the page's own, already escaped.
page_tags :: proc(m: Meta, html, address: string, home: bool) -> string {
	title := m.name
	if at, end, ok := title_span(html); ok { title = html[at + len("<title>"):end - len("</title>")] }
	description, described := quoted_value(html, `<meta name="description" content="`, "")
	if !described { description = esc(m.tagline) }
	alt := esc(cat(m.name, ": ", m.tagline))
	image := cat(m.url, m.card)
	b := strings.builder_make(context.temp_allocator)
	if !strings.contains(html, `rel="canonical"`) { put(&b, `<link rel="canonical" href="`, address, "\">\n") }
	put(&b, `<meta name="author" content="`, m.author, `">
<meta name="theme-color" content="`, m.theme, `">
<link rel="alternate" type="application/atom+xml" title="`, esc(m.name), `: releases" href="`, m.url, FEED_FILE, `">
<link rel="apple-touch-icon" href="`, m.url, m.logo, `">
<link rel="manifest" href="`, m.url, `site.webmanifest">
<meta property="og:type" content="`, home ? "website" : "article", `">
<meta property="og:site_name" content="`, esc(m.name), `">
<meta property="og:locale" content="en_US">
<meta property="og:title" content="`, title, `">
<meta property="og:description" content="`, description, `">
<meta property="og:url" content="`, address, `">
<meta property="og:image" content="`, image, `">
<meta property="og:image:secure_url" content="`, image, `">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="`, alt, `">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="`, title, `">
<meta name="twitter:description" content="`, description, `">
<meta name="twitter:image" content="`, image, `">
<meta name="twitter:image:alt" content="`, alt, `">`)
	if home { put(&b, "\n<script type=\"application/ld+json\">\n", structured_data(m), "\n</script>") }
	return strings.to_string(b)
}

// A redirect or a page marked noindex: /<meta name="robots" content="noindex|http-equiv="refresh"/i
not_a_page :: proc(html: string) -> bool {
	lower := ascii.lower(html)
	return strings.contains(lower, `<meta name="robots" content="noindex`) || strings.contains(lower, `http-equiv="refresh"`)
}

// The address of a page of the site: a folder for its index.html.
page_address :: proc(m: Meta, page: string) -> string {
	if page == HOME_PAGE { return m.url }
	if strings.has_suffix(page, cat("/", HOME_PAGE)) { return cat(m.url, page[:len(page) - len(HOME_PAGE)]) }
	return cat(m.url, page)
}

// sort() compares UTF-16 units: past U+FFFF a character is a surrogate, which comes before U+E000 and what follows it.
utf16_less :: proc(a, b: string) -> bool {
	unit :: proc(r: rune) -> rune { return r >= 0x10000 ? 0xD800 + (r - 0x10000) >> 10 : r }
	x, y := a, b
	for x != "" && y != "" {
		r, r_width := utf8.decode_rune_in_string(x)
		o, o_width := utf8.decode_rune_in_string(y)
		if r != o { return unit(r) != unit(o) ? unit(r) < unit(o) : r < o }
		x, y = x[r_width:], y[o_width:]
	}
	return x == "" && y != ""
}

// Every .html of a folder but the 404, as paths of the site.
html_pages :: proc(root: string) -> (pages: []string, ok: bool) {
	abs, err := os.get_absolute_path(root, context.temp_allocator)
	if err != nil { fmt.eprintfln("site: %s: %v", root, err); return nil, false }
	out := make([dynamic]string, context.temp_allocator)
	w: os.Walker
	os.walker_init_path(&w, abs)
	defer os.walker_destroy(&w)
	for info in os.walker_walk(&w) {
		if path, walk_err := os.walker_error(&w); walk_err != nil { fmt.eprintfln("site: %s: %v", path, walk_err); return nil, false }
		if info.type == .Directory { continue }
		// (the walker's path lasts until its next step)
		page := strings.clone(info.fullpath[len(abs) + 1:], context.temp_allocator)
		page, _ = strings.replace_all(page, "\\", "/", context.temp_allocator)
		if strings.has_suffix(page, ".html") && page != NOT_LISTED { append(&out, page) }
	}
	return out[:], true
}

sitemap_xml :: proc(listed: []string) -> string {
	sorted := slice.clone(listed, context.temp_allocator)
	slice.sort_by(sorted, utf16_less)
	b := strings.builder_make(context.temp_allocator)
	put(&b, `<?xml version="1.0" encoding="utf-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
`)
	for a, i in sorted {
		if i > 0 { strings.write_byte(&b, '\n') }
		put(&b, "  <url><loc>", a, "</loc></url>")
	}
	strings.write_string(&b, "\n</urlset>\n")
	return strings.to_string(b)
}

llms_txt :: proc(m: Meta) -> string {
	return cat("# ", m.name, "\n\n> ", m.tagline, "\n\n## Pages\n\n- [", m.name, "](", m.url, "): the home page.\n- [Changelog](", m.url, m.changelog_page != "" ? m.changelog_page : CHANGELOG_PAGE,
		"): every version.\n- [Releases feed](", m.url, FEED_FILE, "): new versions, in Atom.\n- [Source](", m.repository, "): the repository.\n")
}

not_found_html :: proc(m: Meta) -> string {
	return cat(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<meta name="color-scheme" content="dark">
<title>Not found · `, esc(m.name), `</title>
<link rel="icon" href="`, m.url, m.logo, `">
<style>
html { background: `, m.theme, `; color: #e6e6e6; font: 18px/1.5 system-ui, sans-serif; }
body { margin: 18vh auto 0; padding: 0 24px; max-width: 34rem; }
img { display: block; width: 72px; height: 72px; }
h1 { margin: 20px 0 8px; font-size: 2.2rem; }
a { color: `, m.accent, `; }
</style>
</head>
<body>
<img src="`, m.url, m.logo, `" alt="">
<h1>Not found</h1>
<p>This page does not exist. <a href="`, m.url, `">`, esc(m.name), `</a></p>
</body>
</html>
`)
}

robots_txt :: proc(m: Meta) -> string { return cat("User-agent: *\nAllow: /\n\nSitemap: ", m.url, "sitemap.xml\n") }

png_size :: proc(path: string) -> (size: string, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { fmt.eprintfln("site: %s: %v", path, err); return "", false }
	if len(data) < PNG_HEIGHT_AT + size_of(u32) { fmt.eprintfln("site: %s is no PNG", path); return "", false }
	width, _ := endian.get_u32(data[PNG_WIDTH_AT:], .Big)
	height, _ := endian.get_u32(data[PNG_HEIGHT_AT:], .Big)
	return fmt.tprintf("%dx%d", width, height), true
}

same_folder :: proc(a, b: string) -> bool {
	x, x_err := os.get_absolute_path(a, context.temp_allocator)
	y, y_err := os.get_absolute_path(b, context.temp_allocator)
	return x_err == nil && y_err == nil && strings.trim_right(x, "/\\") == strings.trim_right(y, "/\\")
}

// <out> (a copy of <from>, or <from> itself) with what its pages say when shared, and the files around them.
build_meta :: proc(m: Meta, from, out: string) -> bool {
	if !same_folder(from, out) && !copy_site(from, out) { return false }
	if !os.exists(cat(out, "/", m.card)) { fmt.eprintfln("site: no %s: draw it (draw_card) first", m.card); return false }

	pages, found := html_pages(out)
	if !found { return false }
	listed := make([dynamic]string, context.temp_allocator)
	for page in pages {
		path := cat(out, "/", page)
		html, readable := read_utf8(path)
		if !readable { return false }
		head := strings.index(html, "</head>")
		if head < 0 || not_a_page(html) { continue }
		address := page_address(m, page)
		if !write_text(path, cat(html[:head], page_tags(m, html, address, page == HOME_PAGE), "\n", html[head:])) { return false }
		append(&listed, address)
	}

	changes, has_changes := read_utf8(m.changes)
	if !has_changes { return false }
	rs := feed_versions(changes)
	if len(rs) == 0 { fmt.eprintfln("site: no version in %s", m.changes); return false }
	logo_size, has_logo := png_size(cat(out, "/", m.logo))
	if !has_logo { return false }
	shown := rs[:min(FEED_VERSIONS, len(rs))]
	if !write_text(cat(out, "/", FEED_FILE), feed_xml(m, shown)) { return false }
	if !write_text(cat(out, "/sitemap.xml"), sitemap_xml(listed[:])) { return false }
	if !write_text(cat(out, "/site.webmanifest"), web_manifest(m, logo_size)) { return false }
	if !write_text(cat(out, "/llms.txt"), llms_txt(m)) { return false }
	if !os.exists(cat(out, "/", NOT_LISTED)) && !write_text(cat(out, "/", NOT_LISTED), not_found_html(m)) { return false }
	if m.root_domain {
		if !write_text(cat(out, "/robots.txt"), robots_txt(m)) { return false }
		if m.ico != "" {
			if err := os.copy_file(cat(out, "/favicon.ico"), m.ico); err != nil { fmt.eprintfln("site: %s: %v", m.ico, err); return false }
		}
	}
	fmt.printfln("%d pages, %d versions in the feed: %s", len(listed), len(shown), out)
	return true
}
