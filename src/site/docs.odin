package tk_site

// A documentation site made of a project's Markdown documents: one page per document, in the site's header and footer, with a
// menu of every page (open beside the page on a wide screen, folded under a "Documentation" toggle on a phone, without a
// script), a search box (search.js over search-index.json, no server), collapsible groups, a breadcrumb, the previous and next
// pages, an "On this page" table of contents, and an "Edit this page" link. A project keeps its documents in docs/ and its site
// in site/, at the root of its repository; the pages go to the site's docs/ folder, each page a folder (docs/cdp.md ->
// docs/cdp/index.html, at /docs/cdp/). The output is the same bytes for the same documents, so a check can say it is up to date.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "../ascii"

// What a project says of its documentation site, and what build_docs makes of it.
Docs :: struct {
	source:     string,   // the documents' folder (the repository's docs/); its _nav.txt is the menu (docs/site.md)
	out:        string,   // where the pages go: the docs/ folder of the site
	name:       string,   // the project's name: "<page> · <name> docs"
	site_url:   string,   // where the site is published, with its final "/": the address a moved page names
	repository: string,   // "https://github.com/<owner>/<name>": the "Edit" links, and the links to files the site does not have
	branch:     string,
	note:       string,   // the first line of every page made: a comment that says what made it (it names writer.tool)
	head:       string,   // more of <head>: the icon, the style sheets (root-absolute addresses, like every address given here)
	header:     string,   // the site's top bar
	footer:     proc(d: ^Docs, p: ^Doc_Page) -> string,                  // what follows the page: a footer, scripts
	expand:     proc(d: ^Docs, p: ^Doc_Page, source: string) -> string,  // the project's directives in a document (nil: none)
	rendered:   proc(d: ^Docs, p: ^Doc_Page, body: ^Markdown),           // after each page is written (nil: nothing)
	assets:     []string,          // folders of `source` copied beside the pages, and linked there (pictures)
	languages:  []Code_Language,   // the project's languages of code blocks
	css:        Docs_Css,
	moved:      bool,              // the address a page had before the folders (docs/cdp.html) sends to its folder
	user:       rawptr,            // what the procedures above need
	writer:     Writer,

	// made by build_docs
	nav:        ^Nav,
	pages:      [dynamic]Doc_Page,
	by_rel:     map[string]^Doc_Page,
	search:     [dynamic]Search_Doc,
}

// A page of the documentation.
Doc_Page :: struct {
	rel:     string,   // its document, from docs/: "api/dom.md"
	out_rel: string,   // its file, from the site's docs/: "api/dom/index.html"
	title:   string,   // its first "# " heading, else its menu label, else its file's name
	section: string,   // the menu's section it is in
	source:  string,   // its Markdown
	made:    bool,     // made here, not a document (the list of the pages when docs/ has no index.md): no "Edit" link
}

DOCS_ROOT :: "/docs/"            // the documentation's address on the site
DOCS_NAV  :: "_nav.txt"          // the menu, in the documents' folder
DOCS_SITE :: "site"              // the site's folder in the repository: a link to ../site/x/index.html is the page /x/

// Every page, the style sheet, the search script and its index; the pages at the old addresses when `moved`; then what the
// documents no longer make is removed. False when the documents or the menu cannot be read (it says why).
build_docs :: proc(d: ^Docs) -> bool {
	nav_text, nav_err := os.read_entire_file(file_path({d.source, DOCS_NAV}), context.allocator)
	if nav_err != nil { fmt.eprintfln("%s: cannot read %s/%s", d.writer.tool, d.source, DOCS_NAV); return false }
	files, ok := read_docs_tree(d.source)
	if !ok { fmt.eprintfln("%s: cannot read %s", d.writer.tool, d.source); return false }
	d.nav = build_nav(string(nav_text), files)

	d.pages = make([dynamic]Doc_Page)
	for rel in files {
		data, err := os.read_entire_file(file_path({d.source, rel}), context.allocator)
		if err != nil { fmt.eprintfln("%s: cannot read %s/%s", d.writer.tool, d.source, rel); return false }
		append(&d.pages, Doc_Page{rel = rel, out_rel = docs_out_rel(rel), section = section_of(d.nav, rel), source = string(data)})
	}
	// the title of each page, for the menu, the previous and next links and the search
	for &p in d.pages {
		item := d.nav.by_rel[p.rel]
		p.title = markdown_title(p.source)
		if p.title == "" { p.title = item != nil && item.title != "" ? item.title : title_from_rel(p.rel) }
		if item != nil && item.title == "" { item.title = p.title }
	}
	if !slice.contains(files, "index.md") {
		append(&d.pages, Doc_Page{rel = "index.md", out_rel = "index.html", title = "Documentation", source = docs_listing(d.nav), made = true})
	}
	d.by_rel = make(map[string]^Doc_Page)
	for &p in d.pages { d.by_rel[p.rel] = &p }

	keep := make(map[string]bool, context.temp_allocator)
	d.search = make([dynamic]Search_Doc)
	for &p in d.pages {
		body := render_doc(d, &p)
		html := docs_page_html(d, &p, &body)
		write_generated(&d.writer, file_path({d.out, p.out_rel}), site_relative(html, strings.concatenate({"docs/", p.out_rel}, context.temp_allocator)))
		keep[p.out_rel] = true
		if d.rendered != nil { d.rendered(d, &p, &body) }
	}

	write_generated(&d.writer, file_path({d.out, "docs.css"}), docs_css(d.css))
	write_generated(&d.writer, file_path({d.out, "search.js"}), search_js("search-index.json"))
	write_generated(&d.writer, file_path({d.out, "search-index.json"}), search_index_json(d.search[:]))
	for a in d.assets {
		if !copy_assets(&d.writer, file_path({d.source, a}), file_path({d.out, a})) { return false }
	}

	if d.moved {
		for p in d.pages {
			old := strings.concatenate({p.rel[:len(p.rel) - len(".md")], ".html"})
			if old == p.out_rel { continue }
			keep[old] = true
			name := p.rel[strings.last_index_byte(p.rel, '/') + 1:len(p.rel) - len(".md")]
			canonical := strings.concatenate({d.site_url, docs_page_url(p.out_rel)[1:]})
			write_generated(&d.writer, file_path({d.out, old}), redirect_page(strings.concatenate({name, "/"}), canonical, d.note))
		}
	}
	prune_generated(&d.writer, d.out, keep)
	return true
}

// A document, its directives expanded, as HTML; its plain text goes to the search index (not the list made here).
@(private)
render_doc :: proc(d: ^Docs, p: ^Doc_Page) -> Markdown {
	source := p.source
	if d.expand != nil && !p.made { source = d.expand(d, p, source) }
	rc := Rewrite{d = d, cur = p.rel}
	ctx := Markdown_Context{link = rewrite_link, user = &rc, languages = d.languages}
	body := render_markdown(source, &ctx)
	if !p.made { append(&d.search, Search_Doc{url = docs_page_url(p.out_rel), title = p.title, section = p.section, text = collapse_spaces(body.plain)}) }
	return body
}

// A whole page. Its addresses are root-absolute; build_docs makes them relative to the page (site_relative).
docs_page_html :: proc(d: ^Docs, p: ^Doc_Page, body: ^Markdown) -> string {
	b := strings.builder_make()
	ws := strings.write_string
	if d.note != "" { ws(&b, d.note); ws(&b, "\n") }
	ws(&b, "<!doctype html>\n<html lang=\"en\">\n<head>\n")
	ws(&b, "<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
	ws(&b, "<title>")
	write_escaped(&b, p.title)
	ws(&b, " · ")
	write_escaped(&b, d.name)
	ws(&b, " docs</title>\n")
	ws(&b, "<meta name=\"description\" content=\"")
	write_escaped(&b, docs_description(d, body.plain, p.title), true)
	ws(&b, "\">\n")
	ws(&b, d.head)
	ws(&b, "</head>\n<body class=\"docs\">\n")
	ws(&b, "<a class=\"skip\" href=\"#doc-main\">Skip to content</a>\n")
	ws(&b, d.header)
	ws(&b, "<div class=\"doc-shell\">\n")
	// the menu: a checkbox opens it on a phone, without a script
	ws(&b, "<input class=\"doc-nav-toggle\" type=\"checkbox\" id=\"doc-nav\">\n")
	ws(&b, "<label class=\"doc-nav-open\" for=\"doc-nav\"><span></span><span></span><span></span> Documentation</label>\n")
	ws(&b, "<aside class=\"doc-side\" aria-label=\"Documentation sections\">\n<nav class=\"doc-tree\">\n")
	write_docs_sidebar(&b, d.nav, p.rel)
	ws(&b, "</nav>\n</aside>\n")
	ws(&b, "<main id=\"doc-main\" class=\"doc-main\">\n<article class=\"doc-article\">\n")
	write_docs_breadcrumb(&b, p)
	ws(&b, body.html)
	write_docs_prev_next(&b, d, p)
	write_docs_edit_link(&b, d, p)
	ws(&b, "</article>\n")
	write_docs_toc(&b, body.headings[:])
	ws(&b, "</main>\n</div>\n")
	if d.footer != nil { ws(&b, d.footer(d, p)) }
	ws(&b, "<script src=\"/docs/search.js\" defer></script>\n")
	ws(&b, "</body>\n</html>\n")
	return strings.to_string(b)
}

// The search box, then each section of the menu: its title and its pages; a group is a <details>, open when it holds `current`.
write_docs_sidebar :: proc(b: ^strings.Builder, nav: ^Nav, current: string) {
	ws := strings.write_string
	ws(b, "<form class=\"doc-search\" role=\"search\" onsubmit=\"return false\">\n")
	ws(b, "<input id=\"doc-search-input\" type=\"search\" placeholder=\"Search docs… (press /)\" autocomplete=\"off\" aria-label=\"Search documentation\">\n")
	ws(b, "<div id=\"doc-search-results\" class=\"doc-search-results\" hidden></div>\n")
	ws(b, "</form>\n")
	for sec in nav.roots {
		ws(b, "<div class=\"doc-sec\">\n<p class=\"doc-sec-title\">")
		write_escaped(b, sec.title)
		ws(b, "</p>\n")
		write_nav_items(b, sec.children[:], current)
		ws(b, "</div>\n")
	}
}

@(private)
write_nav_items :: proc(b: ^strings.Builder, items: []^Nav_Item, current: string) {
	ws := strings.write_string
	ws(b, "<ul class=\"doc-links\">\n")
	for it in items {
		if it.rel == "" {
			ws(b, "<li class=\"doc-group\"><details")
			if contains_rel(it, current) { ws(b, " open") }
			ws(b, "><summary>")
			write_escaped(b, it.title)
			ws(b, "</summary>\n")
			write_nav_items(b, it.children[:], current)
			ws(b, "</details></li>\n")
			continue
		}
		ws(b, "<li><a href=\"")
		ws(b, docs_page_url(docs_out_rel(it.rel)))
		ws(b, "\"")
		if it.rel == current { ws(b, " aria-current=\"page\" class=\"active\"") }
		ws(b, ">")
		write_escaped(b, it.title)
		ws(b, "</a></li>\n")
	}
	ws(b, "</ul>\n")
}

write_docs_breadcrumb :: proc(b: ^strings.Builder, p: ^Doc_Page) {
	ws := strings.write_string
	ws(b, "<nav class=\"doc-crumbs\" aria-label=\"Breadcrumb\"><ol>\n")
	ws(b, "<li><a href=\"/docs/\">Docs</a></li>\n")
	if p.section != "" && p.rel != "index.md" {
		ws(b, "<li>")
		write_escaped(b, p.section)
		ws(b, "</li>\n")
	}
	ws(b, "<li aria-current=\"page\">")
	write_escaped(b, p.title)
	ws(b, "</li>\n")
	ws(b, "</ol></nav>\n")
}

// The headings of levels 2 and 3, when there are 2 or more.
write_docs_toc :: proc(b: ^strings.Builder, headings: []Heading) {
	count := 0
	for h in headings { if h.level == 2 || h.level == 3 { count += 1 } }
	if count < 2 { return }
	ws := strings.write_string
	ws(b, "<nav class=\"doc-toc\" aria-label=\"On this page\">\n<p class=\"doc-toc-title\">On this page</p>\n<ul>\n")
	for h in headings {
		if h.level != 2 && h.level != 3 { continue }
		ws(b, h.level == 3 ? "<li class=\"lvl3\"><a href=\"#" : "<li><a href=\"#")
		ws(b, h.id)
		ws(b, "\">")
		write_escaped(b, h.text)
		ws(b, "</a></li>\n")
	}
	ws(b, "</ul>\n</nav>\n")
}

// The pages before and after `p` in the menu's order.
write_docs_prev_next :: proc(b: ^strings.Builder, d: ^Docs, p: ^Doc_Page) {
	idx := -1
	for rel, i in d.nav.order { if rel == p.rel { idx = i; break } }
	if idx < 0 { return }
	ws := strings.write_string
	ws(b, "<nav class=\"doc-seq\" aria-label=\"Previous and next page\">\n")
	if idx > 0 {
		if prev := d.by_rel[d.nav.order[idx - 1]]; prev != nil {
			ws(b, "<a class=\"doc-prev\" href=\"")
			ws(b, docs_page_url(prev.out_rel))
			ws(b, "\"><span>Previous</span><strong>")
			write_escaped(b, prev.title)
			ws(b, "</strong></a>\n")
		}
	}
	if idx < len(d.nav.order) - 1 {
		if next := d.by_rel[d.nav.order[idx + 1]]; next != nil {
			ws(b, "<a class=\"doc-next\" href=\"")
			ws(b, docs_page_url(next.out_rel))
			ws(b, "\"><span>Next</span><strong>")
			write_escaped(b, next.title)
			ws(b, "</strong></a>\n")
		}
	}
	ws(b, "</nav>\n")
}

write_docs_edit_link :: proc(b: ^strings.Builder, d: ^Docs, p: ^Doc_Page) {
	if p.made { return }
	ws := strings.write_string
	ws(b, "<p class=\"doc-edit\"><a href=\"")
	ws(b, d.repository)
	ws(b, "/blob/")
	ws(b, d.branch)
	ws(b, "/docs/")
	ws(b, p.rel)
	ws(b, "\" rel=\"noopener\">Edit this page on GitHub</a></p>\n")
}

// A page's description: the first sentence of its text, 170 bytes at most.
docs_description :: proc(d: ^Docs, plain: string, title: string) -> string {
	t := collapse_spaces(plain)
	if len(t) == 0 { return strings.concatenate({title, " — ", d.name, " documentation."}) }
	limit := min(len(t), 170)
	cut := limit
	for i in 0 ..< limit {
		if t[i] == '.' && i + 1 < len(t) && t[i + 1] == ' ' { cut = i + 1; break }
	}
	return t[:cut]
}

// A page's file from the site's docs/: docs/cdp.md -> cdp/index.html, docs/releases/v1.md -> releases/v1/index.html,
// docs/index.md -> index.html.
docs_out_rel :: proc(rel: string) -> string {
	base := rel[:len(rel) - len(".md")]
	if base == "index" || strings.has_suffix(base, "/index") { return strings.concatenate({base, ".html"}) }
	return strings.concatenate({base, "/index.html"})
}

// A page's root-absolute address, its folder: cdp/index.html -> /docs/cdp/, index.html -> /docs/.
docs_page_url :: proc(out_rel: string) -> string {
	return strings.concatenate({DOCS_ROOT, strings.trim_suffix(out_rel, "index.html")})
}

// The list of the pages, as Markdown, when docs/ has no index.md of its own.
@(private)
docs_listing :: proc(nav: ^Nav) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "# Documentation\n")
	item :: proc(b: ^strings.Builder, it: ^Nav_Item, indent: string) {
		strings.write_string(b, indent)
		if it.rel == "" {
			fmt.sbprintf(b, "- %s\n", it.title)
			for c in it.children { item(b, c, strings.concatenate({indent, "  "}, context.temp_allocator)) }
			return
		}
		fmt.sbprintf(b, "- [%s](%s)\n", it.title, it.rel)
	}
	for sec in nav.roots {
		fmt.sbprintf(&b, "\n## %s\n\n", sec.title)
		for c in sec.children { item(&b, c, "") }
	}
	return strings.to_string(b)
}

@(private)
title_from_rel :: proc(rel: string) -> string {
	base := filepath.base(rel)
	base = base[:len(base) - len(".md")]
	base, _ = strings.replace_all(base, "-", " ")
	if len(base) == 0 { return rel }
	return strings.concatenate({ascii.upper(base[:1]), base[1:]})
}

// `s` with each run of blanks made one space, trimmed.
collapse_spaces :: proc(s: string) -> string {
	b := strings.builder_make()
	space := false
	for i in 0 ..< len(s) {
		c := s[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' { space = true; continue }
		if space && strings.builder_len(b) > 0 { strings.write_byte(&b, ' ') }
		space = false
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// --- the menu ---------------------------------------------------------------
// docs/_nav.txt, line by line: "# ..." a comment (a blank line too); "Section" at the start of the line a section; indented,
// "page.md  Title" a page of it (the title optional: then its first heading), "dir/*  Title" every document of a folder as a
// group (its README.md, _index.md or index.md first as "Overview", the others sorted). A document no line names goes to a
// last section, "More", so none is left out. The order of the file is the menu's.

Nav_Item :: struct {
	rel:      string,   // the document, from docs/; "" for a group
	title:    string,   // its label
	children: [dynamic]^Nav_Item,
}

Nav :: struct {
	roots:  [dynamic]^Nav_Item,      // the sections
	by_rel: map[string]^Nav_Item,
	order:  [dynamic]string,         // every document in the menu's order: previous and next
}

// The menu from its text and the documents there are (paths from docs/). A line that names a missing document is skipped.
build_nav :: proc(nav_text: string, docs: []string) -> ^Nav {
	nav := new(Nav)
	nav.by_rel = make(map[string]^Nav_Item)
	present := make(map[string]bool, context.temp_allocator)
	for doc in docs { present[doc] = true }
	used := make(map[string]bool, context.temp_allocator)

	section: ^Nav_Item
	for raw in strings.split_lines(nav_text, context.temp_allocator) {
		line := strings.trim_right_space(raw)
		if len(strings.trim_space(line)) == 0 || strings.has_prefix(strings.trim_left_space(line), "#") { continue }
		body := strings.trim_left_space(line)
		if len(body) == len(line) {
			section = new_item("", body)
			append(&nav.roots, section)
			continue
		}
		if section == nil { continue }
		path, title := split_nav_entry(body)
		if strings.has_suffix(path, "/*") {
			add_nav_group(nav, section, path[:len(path) - 2], title, present, &used)
		} else if present[path] {
			item := new_item(path, title)
			append(&section.children, item)
			nav.by_rel[path] = item
			used[path] = true
		}
	}

	leftovers := make([dynamic]string, context.temp_allocator)
	for doc in docs { if !used[doc] { append(&leftovers, doc) } }
	if len(leftovers) > 0 {
		slice.sort(leftovers[:])
		more := new_item("", "More")
		for doc in leftovers {
			item := new_item(doc, "")
			append(&more.children, item)
			nav.by_rel[doc] = item
		}
		append(&nav.roots, more)
	}

	nav.order = make([dynamic]string)
	for sec in nav.roots { collect_order(nav, sec) }
	return nav
}

@(private)
new_item :: proc(rel, title: string) -> ^Nav_Item {
	item := new(Nav_Item)
	item^ = {rel = rel, title = title, children = make([dynamic]^Nav_Item)}
	return item
}

@(private)
add_nav_group :: proc(nav: ^Nav, section: ^Nav_Item, dir: string, title: string, present: map[string]bool, used: ^map[string]bool) {
	members := make([dynamic]string, context.temp_allocator)
	prefix := strings.concatenate({dir, "/"}, context.temp_allocator)
	for doc in present {
		if strings.has_prefix(doc, prefix) && !used[doc] { append(&members, doc) }
	}
	if len(members) == 0 { return }
	slice.sort(members[:])
	group := new_item("", title != "" ? title : dir)
	append(&section.children, group)
	lead := ""
	for name in ([?]string{"README.md", "_index.md", "index.md"}) {
		candidate := strings.concatenate({prefix, name}, context.temp_allocator)
		if present[candidate] { lead = candidate; break }
	}
	if lead != "" {
		item := new_item(strings.clone(lead), "Overview")
		append(&group.children, item)
		nav.by_rel[item.rel] = item
		used[item.rel] = true
	}
	for m in members {
		if m == lead { continue }
		item := new_item(m, "")
		append(&group.children, item)
		nav.by_rel[m] = item
		used[m] = true
	}
}

@(private)
collect_order :: proc(nav: ^Nav, item: ^Nav_Item) {
	if item.rel != "" { append(&nav.order, item.rel) }
	for c in item.children { collect_order(nav, c) }
}

// "page.md  Title": the path is the first word, the title the rest.
@(private)
split_nav_entry :: proc(body: string) -> (path, title: string) {
	i := 0
	for i < len(body) && body[i] != ' ' && body[i] != '\t' { i += 1 }
	return body[:i], strings.trim_space(body[i:])
}

@(private)
section_of :: proc(nav: ^Nav, rel: string) -> string {
	for sec in nav.roots { if contains_rel(sec, rel) { return sec.title } }
	return ""
}

@(private)
contains_rel :: proc(item: ^Nav_Item, rel: string) -> bool {
	if item.rel == rel { return true }
	for c in item.children { if contains_rel(c, rel) { return true } }
	return false
}

// Every .md under `dir`, as paths from it with "/", sorted; a path that starts with "_" (_nav.txt's neighbours, a _drafts/
// folder) is not a document.
read_docs_tree :: proc(dir: string) -> (docs: []string, ok: bool) {
	out := make([dynamic]string)
	walk :: proc(dir, prefix: string, out: ^[dynamic]string) -> bool {
		infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil { return false }
		for fi in infos {
			if fi.type == .Directory {
				if !walk(fi.fullpath, prefix, out) { return false }
				continue
			}
			if !strings.has_suffix(fi.name, ".md") { continue }
			full, _ := strings.replace_all(fi.fullpath, "\\", "/")
			rel := strings.trim_prefix(strings.trim_prefix(full, prefix), "/")
			if rel != "" && !strings.has_prefix(rel, "_") { append(out, rel) }
		}
		return true
	}
	if !walk(dir, abs_forward(dir), &out) { return nil, false }
	slice.sort(out[:])
	return out[:], true
}

// The absolute path of `p` with "/", as the paths a directory listing gives.
@(private)
abs_forward :: proc(p: string) -> string {
	ap, err := os.get_absolute_path(p, context.temp_allocator)
	if err != nil { ap = p }
	f, _ := strings.replace_all(ap, "\\", "/")
	return f
}

// --- the addresses ----------------------------------------------------------

@(private)
Rewrite :: struct {
	d:   ^Docs,
	cur: string,   // the document, from docs/
}

// A link of a document, resolved from its folder (Markdown_Context.link):
//   web.md (from api/dom.md) -> /docs/api/web/ ; ../remote.md -> /docs/remote/ ; ../site/pricing/index.html -> /pricing/
//   a file of an asset folder (screenshots/a.png) -> /docs/screenshots/a.png
// Any other file of the repository is not on the site: its page on GitHub (a folder's tree). The fragment stays. An address
// with a scheme, a fragment alone or a root-absolute one is left as it is ("").
@(private)
rewrite_link :: proc(href: string, user: rawptr) -> string {
	rc := (^Rewrite)(user)
	if href == "" || is_external(href) || strings.has_prefix(href, "#") || strings.has_prefix(href, "/") { return "" }
	path, frag := href, ""
	if h := strings.index_byte(href, '#'); h >= 0 { path, frag = href[:h], href[h:] }
	normalized := path_normalize(path_join(path_dir(rc.cur), path))
	if strings.has_suffix(path, "/") && normalized != "" { normalized = strings.concatenate({normalized, "/"}) }
	inside := !strings.has_prefix(normalized, "../")

	if inside && strings.has_suffix(normalized, ".md") { return strings.concatenate({docs_page_url(docs_out_rel(normalized)), frag}) }
	if inside {
		for a in rc.d.assets {
			if strings.has_prefix(normalized, a) && strings.has_prefix(normalized[len(a):], "/") { return strings.concatenate({DOCS_ROOT, normalized, frag}) }
		}
	}
	site_prefix := "../" + DOCS_SITE + "/"
	if strings.has_prefix(normalized, site_prefix) {
		return strings.concatenate({strings.trim_suffix(normalized[len(site_prefix) - 1:], "index.html"), frag})
	}
	rel := inside ? strings.concatenate({"docs/", normalized}) : normalized[len("../"):]
	kind := strings.has_suffix(rel, "/") ? "/tree/" : "/blob/"
	return strings.concatenate({rc.d.repository, kind, rc.d.branch, "/", strings.trim_suffix(rel, "/"), frag})
}

@(private)
path_dir :: proc(p: string) -> string {
	i := strings.last_index_byte(p, '/')
	return i < 0 ? "" : p[:i]
}

@(private)
path_join :: proc(dir, rel: string) -> string {
	return dir == "" ? rel : strings.concatenate({dir, "/", rel})
}

// "a/./b" -> "a/b", "a/b/../c" -> "a/c"; a leading run of ".." stays (it leaves the folder).
@(private)
path_normalize :: proc(p: string) -> string {
	out := make([dynamic]string, context.temp_allocator)
	for part in strings.split(p, "/", context.temp_allocator) {
		switch part {
		case "", ".":
		case "..":
			if len(out) > 0 && out[len(out) - 1] != ".." { pop(&out) } else { append(&out, "..") }
		case:
			append(&out, part)
		}
	}
	return strings.join(out[:], "/")
}

// The site lives under a path of its own (https://<owner>.github.io/<name>/), where an address that starts with "/" leaves it:
// every root-absolute href and src of `html` is made relative to the root, from the page's depth (`page`, its path from the
// root: "docs/cdp/index.html"). The root itself, from a page there, is "./".
site_relative :: proc(html, page: string) -> string {
	root := strings.builder_make(context.temp_allocator)
	for c in page { if c == '/' { strings.write_string(&root, "../") } }
	prefix := strings.to_string(root)
	b := strings.builder_make()
	i := 0
	scan: for i < len(html) {
		for attr in ([?]string{"href=\"/", "src=\"/"}) {
			if strings.has_prefix(html[i:], attr) && !strings.has_prefix(html[i + len(attr):], "/") {
				strings.write_string(&b, attr[:len(attr) - 1])
				strings.write_string(&b, prefix)
				if prefix == "" && strings.has_prefix(html[i + len(attr):], "\"") { strings.write_string(&b, "./") }
				i += len(attr)
				continue scan
			}
		}
		strings.write_byte(&b, html[i])
		i += 1
	}
	return strings.to_string(b)
}

// The relative href and src of a piece of a page in the folder `dir` (from the root) made root-absolute: "../img/x.webp"
// from "gallery" -> "/img/x.webp", "./" -> "/". An address with a scheme, a fragment alone or a root-absolute one stays.
rooted :: proc(html, dir: string) -> string {
	b := strings.builder_make()
	i := 0
	scan: for i < len(html) {
		for attr in ([?]string{" href=\"", " src=\""}) {
			if !strings.has_prefix(html[i:], attr) { continue }
			v0 := i + len(attr)
			v1 := strings.index_byte(html[v0:], '"')
			if v1 < 0 { break scan }
			strings.write_string(&b, html[i:v0])
			strings.write_string(&b, root_of(html[v0:v0 + v1], dir))
			i = v0 + v1
			continue scan
		}
		strings.write_byte(&b, html[i])
		i += 1
	}
	strings.write_string(&b, html[i:])
	return strings.to_string(b)
}

@(private)
root_of :: proc(href, dir: string) -> string {
	if href == "" || strings.has_prefix(href, "#") || strings.has_prefix(href, "/") || has_scheme(href) { return href }
	target, frag := href, ""
	if h := strings.index_byte(href, '#'); h >= 0 { target, frag = href[:h], href[h:] }
	path := path_normalize(path_join(dir, target))
	folder := target == "." || target == ".." || strings.has_suffix(target, "/") || strings.has_suffix(target, "/..")
	if folder && path != "" { path = strings.concatenate({path, "/"}) }
	return strings.concatenate({"/", path, frag})
}

// "https:", "mailto:", "data:"...: a ':' before any '/', '?' or '#'.
@(private)
has_scheme :: proc(href: string) -> bool {
	colon := strings.index_byte(href, ':')
	return colon > 0 && strings.index_any(href[:colon], "/?#") < 0
}

// A page left at an old address: it sends the reader on to `to` (relative to it), the query and the fragment kept, with a
// refresh for a reader without scripts and a link for one without either. `note`: its first line ("": none).
redirect_page :: proc(to, canonical, note: string) -> string {
	b := strings.builder_make()
	ws := strings.write_string
	if note != "" { ws(&b, note); ws(&b, "\n") }
	ws(&b, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Moved</title>\n")
	ws(&b, "<meta name=\"robots\" content=\"noindex\">\n")
	ws(&b, "<link rel=\"canonical\" href=\"")
	ws(&b, canonical)
	ws(&b, "\">\n<meta http-equiv=\"refresh\" content=\"0; url=")
	ws(&b, to)
	ws(&b, "\">\n<script>location.replace(\"")
	ws(&b, to)
	ws(&b, "\" + location.search + location.hash)</script>\n</head>\n<body>\n<p>This page has moved: <a href=\"")
	ws(&b, to)
	ws(&b, "\">")
	ws(&b, canonical)
	ws(&b, "</a></p>\n</body>\n</html>\n")
	return strings.to_string(b)
}

// --- writing ----------------------------------------------------------------

// Writes generated files only when their bytes change. With `check`, it writes nothing and counts each file that is missing or
// differs: a check that the committed output is up to date.
Writer :: struct {
	tool:     string,   // the generator's name: its messages start with it, and the pages it made hold it in their first 300 bytes
	check:    bool,
	problems: int,      // files out of date (check), or not written
	written:  int,      // files written or removed
}

write_generated :: proc(w: ^Writer, path, text: string) {
	old, err := os.read_entire_file(path, context.temp_allocator)
	if err == nil && string(old) == text { return }
	if w.check {
		fmt.eprintfln("%s: %s is %s", w.tool, path, err == nil ? "out of date" : "missing")
		w.problems += 1
		return
	}
	_ = os.make_directory_all(filepath.dir(path))
	if werr := os.write_entire_file(path, transmute([]u8)text); werr != nil {
		fmt.eprintfln("%s: cannot write %s: %v", w.tool, path, werr)
		w.problems += 1
		return
	}
	w.written += 1
}

// Removes each .html under `dir` that this tool made (its name in the first 300 bytes) and `keep` does not name (paths from
// `dir`, with "/"). With `check`, counts them instead.
prune_generated :: proc(w: ^Writer, dir: string, keep: map[string]bool) {
	walk :: proc(w: ^Writer, dir, prefix: string, keep: map[string]bool) {
		infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil { return }
		for fi in infos {
			if fi.type == .Directory { walk(w, fi.fullpath, prefix, keep); continue }
			if !strings.has_suffix(fi.name, ".html") { continue }
			full, _ := strings.replace_all(fi.fullpath, "\\", "/", context.temp_allocator)
			rel := strings.trim_prefix(strings.trim_prefix(full, prefix), "/")
			if rel in keep { continue }
			data, derr := os.read_entire_file(fi.fullpath, context.temp_allocator)
			if derr != nil || !strings.contains(string(data[:min(len(data), 300)]), w.tool) { continue }
			if w.check {
				fmt.eprintfln("%s: %s is generated but nothing makes it any more", w.tool, fi.fullpath)
				w.problems += 1
				continue
			}
			_ = os.remove(fi.fullpath)
			w.written += 1
		}
	}
	walk(w, dir, abs_forward(dir), keep)
}

// The files of the folder `from` (not its subfolders) into `to`, through the writer.
@(private)
copy_assets :: proc(w: ^Writer, from, to: string) -> bool {
	files, err := os.read_all_directory_by_path(from, context.temp_allocator)
	if err != nil { fmt.eprintfln("%s: cannot read %s", w.tool, from); return false }
	for f in files {
		if f.type == .Directory { continue }
		data, rerr := os.read_entire_file(f.fullpath, context.temp_allocator)
		if rerr != nil { fmt.eprintfln("%s: cannot read %s", w.tool, f.fullpath); return false }
		write_generated(w, file_path({to, f.name}), string(data))
	}
	return true
}

@(private)
file_path :: proc(parts: []string) -> string {
	p, _ := filepath.join(parts, context.temp_allocator)
	return p
}
