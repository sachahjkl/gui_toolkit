package tk

import "core:fmt"
import "core:os"
import "core:path/slashpath"
import "core:slice"
import "core:strings"
import tk_site "../../src/site"

// site_docs <site> <out>: every docs/*.md as <out>/docs/<name>.html, with the site's look, and <out>/docs/index.html that lists them.
// The Markdown becomes HTML in src/site (tk_site.markdown_html); a link becomes another document's page or a file's page on GitHub.

GITHUB_BLOB :: "https://github.com/sachahjkl/gui_toolkit/blob/master/"

Doc_Group :: struct {
	title: string,
	names: []string,
}

// The index's order. A document that no group names goes into "Other", so a new document is never left out of the site.
DOC_GROUPS := []Doc_Group {
	{"Start", {"getting-started"}},
	{"Drawing and text", {"draw", "canvas", "text", "font-backend", "slug-small-text", "shaders", "rendering", "webgpu"}},
	{"Widgets and layout", {"docking", "panes", "modals", "autoscroll", "dragdrop", "accessibility", "i18n"}},
	{"Platform and system", {"platform", "clipboard", "dialogs", "tray", "dbus", "fsx", "instance", "update", "desktop", "process", "config"}},
	{"Frames and threads", {"pacing", "frame_gate", "post", "locks", "arena", "flate"}},
	{"Tools and tests", {"testing", "testkit", "devtools", "cdp", "site"}},
}

Doc :: struct {
	name, title, body: string,
}

run_site_docs :: proc(a: ^Args) -> string {
	return build_docs(join({toolkit_root(), "docs"}), a.positionals[0], a.positionals[1])
}

// Reads `docs_dir`'s *.md and the page of the site (`site`/index.html, for the header and the menu script), writes `out`/docs/.
build_docs :: proc(docs_dir, site, out: string) -> string {
	index, ok := read_text(join({site, "index.html"}))
	if !ok { return fmt.tprintf("%s/index.html cannot be read", site) }
	// The header and the menu script come from the home page, so a change there reaches the docs without a second copy.
	header := between(index, "<header class=\"bar\">", "</header>")
	script := between(index, "<script>", "</script>")
	if header == "" || script == "" { return fmt.tprintf("%s/index.html has no header or no script", site) }
	header = strings.concatenate({"<header class=\"bar\">", up_links(header), "</header>"}, context.temp_allocator)

	entries, err := os.read_all_directory_by_path(docs_dir, context.temp_allocator)
	if err != nil { return fmt.tprintf("%s cannot be read", docs_dir) }
	docs := make([dynamic]Doc, context.temp_allocator)
	for e in entries {
		if !strings.has_suffix(e.name, ".md") { continue }
		text, read_ok := read_text(join({docs_dir, e.name}))
		if !read_ok { return fmt.tprintf("%s cannot be read", e.name) }
		name := e.name[:len(e.name) - 3]
		append(&docs, Doc{name, tk_site.markdown_title(text), tk_site.markdown_html(text, doc_link)})
	}
	slice.sort_by(docs[:], proc(x, y: Doc) -> bool { return x.name < y.name })

	dir := join({out, "docs"})
	_ = os.make_directory_all(dir) // already there on a second run
	if !os.exists(dir) { return fmt.tprintf("%s cannot be made", dir) }
	for d in docs {
		page := docs_page(header, script, docs[:], d.name, d.title, d.body)
		if os.write_entire_file(join({dir, fmt.tprintf("%s.html", d.name)}), page) != nil { return fmt.tprintf("%s.html cannot be written", d.name) }
	}
	listing := strings.concatenate({"<h1>Documentation</h1>\n", docs_listing(docs[:])}, context.temp_allocator)
	if os.write_entire_file(join({dir, "index.html"}), docs_page(header, script, docs[:], "", "Documentation", listing)) != nil { return "index.html cannot be written" }
	return copy_pictures(join({docs_dir, "screenshots"}), join({dir, "screenshots"}))
}

// The pictures the documents show (`![...](screenshots/x.png)`) keep their relative address, so they go beside the pages.
copy_pictures :: proc(from, to: string) -> string {
	if !os.exists(from) { return "" }
	_ = os.make_directory_all(to)
	if !os.exists(to) { return fmt.tprintf("%s cannot be made", to) }
	files, _ := os.read_all_directory_by_path(from, context.temp_allocator)
	for f in files {
		if f.type == .Directory { continue }
		if os.copy_file(join({to, f.name}), join({from, f.name})) != nil { return fmt.tprintf("%s cannot be copied", f.name) }
	}
	return ""
}

// The text of `s` between the first `open` and the next `close`.
between :: proc(s, open, close: string) -> string {
	i := strings.index(s, open)
	if i < 0 { return "" }
	rest := s[i + len(open):]
	j := strings.index(rest, close)
	return j < 0 ? "" : rest[:j]
}

// The home page's links, for a page one folder down: "#x" is the home's, "img/x.png" is "../img/x.png". Addresses with a scheme stay.
up_links :: proc(html: string) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	rest := html
	for {
		at := strings.index(rest, "=\"")
		if at < 0 { break }
		attr_end := at
		start := attr_end
		for start > 0 && rest[start - 1] != ' ' { start -= 1 }
		attr := rest[start:attr_end]
		value_start := at + 2
		value_end := strings.index_byte(rest[value_start:], '"')
		if value_end < 0 { break }
		value := rest[value_start:][:value_end]
		strings.write_string(&b, rest[:value_start])
		if attr == "href" || attr == "src" {
			switch {
			case strings.contains(value, ":"):
				strings.write_string(&b, value)
			case strings.has_prefix(value, "#"):
				strings.write_string(&b, "../index.html")
				strings.write_string(&b, value)
			case:
				strings.write_string(&b, "../")
				strings.write_string(&b, value)
			}
		} else {
			strings.write_string(&b, value)
		}
		rest = rest[value_start + value_end:]
	}
	strings.write_string(&b, rest)
	return strings.to_string(b)
}

// A page: the home's header, the menu of every document, `body`. `current` is the document's name ("" for the index).
docs_page :: proc(header, script: string, docs: []Doc, current, title, body: string) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	fmt.sbprintf(&b, `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s · gui_toolkit</title>
<link rel="icon" href="../img/logo.png">
<link rel="stylesheet" href="../style.css">
</head>
<body>
%s
<div class="docs">
<nav class="docs-nav" aria-label="Documentation">
<a href="index.html"%s>All documents</a>
`, tk_site.esc(title), header, current == "" ? ` aria-current="page"` : "")
	for g in doc_groups(docs) {
		fmt.sbprintf(&b, "<h2>%s</h2>\n", tk_site.esc(g.title))
		for d in g.docs {
			fmt.sbprintf(&b, "<a href=\"%s.html\"%s>%s</a>\n", d.name, d.name == current ? ` aria-current="page"` : "", tk_site.esc(short_title(d.title)))
		}
	}
	fmt.sbprintf(&b, `</nav>
<main class="doc">
%s
%s</main>
</div>
<footer>
<p>gui_toolkit, MIT licence. These pages are the Markdown files of <a href="https://github.com/sachahjkl/gui_toolkit/tree/master/docs">docs/</a>.</p>
</footer>
<script>%s</script>
</body>
</html>
`, body, current == "" ? "" : fmt.tprintf("<p class=\"small\"><a href=\"%sdocs/%s.md\">Edit on GitHub</a></p>\n", GITHUB_BLOB, current), script)
	return strings.to_string(b)
}

Listed_Group :: struct {
	title: string,
	docs:  [dynamic]Doc,
}

// A title without its parenthesis (the files it covers): the menu's width is small.
short_title :: proc(title: string) -> string {
	i := strings.index(title, " (")
	return i > 0 ? title[:i] : title
}

// The documents in the order of DOC_GROUPS, then those no group names.
doc_groups :: proc(docs: []Doc) -> []Listed_Group {
	out := make([dynamic]Listed_Group, context.temp_allocator)
	named := make(map[string]bool, context.temp_allocator)
	for g in DOC_GROUPS {
		listed := Listed_Group{title = g.title, docs = make([dynamic]Doc, context.temp_allocator)}
		for name in g.names {
			for d in docs { if d.name == name { append(&listed.docs, d); named[name] = true } }
		}
		if len(listed.docs) > 0 { append(&out, listed) }
	}
	other := Listed_Group{title = "Other", docs = make([dynamic]Doc, context.temp_allocator)}
	for d in docs { if !named[d.name] { append(&other.docs, d) } }
	if len(other.docs) > 0 { append(&out, other) }
	return out[:]
}

docs_listing :: proc(docs: []Doc) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for g in doc_groups(docs) {
		fmt.sbprintf(&b, "<h2>%s</h2>\n<ul>\n", tk_site.esc(g.title))
		for d in g.docs { fmt.sbprintf(&b, "<li><a href=\"%s.html\">%s</a></li>\n", d.name, tk_site.esc(d.title)) }
		strings.write_string(&b, "</ul>\n")
	}
	return strings.to_string(b)
}

// The address of a link of a document (they are in docs/): another document is its page, another file of the repository is its page
// on GitHub, an address with a scheme or an anchor stays. Odd addresses (outside the repository) stay as they are.
doc_link :: proc(url: string) -> string {
	if url == "" || url[0] == '#' { return url }
	colon, slash := strings.index_byte(url, ':'), strings.index_byte(url, '/')
	if colon >= 0 && (slash < 0 || colon < slash) { return url }
	path, anchor := url, ""
	if hash := strings.index_byte(url, '#'); hash >= 0 { path, anchor = url[:hash], url[hash:] }
	resolved := slashpath.join({"docs", path}, context.temp_allocator)
	if strings.has_prefix(resolved, "../") { return url }
	if slashpath.dir(resolved, context.temp_allocator) == "docs" && strings.has_suffix(resolved, ".md") {
		return fmt.tprintf("%s.html%s", resolved[5:len(resolved) - 3], anchor)
	}
	return fmt.tprintf("%s%s%s", GITHUB_BLOB, resolved, anchor)
}
