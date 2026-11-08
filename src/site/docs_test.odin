package tk_site

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file") has :: proc(t: ^testing.T, text, part: string, loc := #caller_location) {
	testing.expect(t, strings.contains(text, part), fmt.tprintf("%q is not in the page", part), loc = loc)
}

@(private = "file") put_file :: proc(t: ^testing.T, root, path, text: string, loc := #caller_location) {
	full := fmt.tprintf("%s/%s", root, path)
	_ = os.make_directory_all(full[:strings.last_index_byte(full, '/')])
	testing.expect(t, os.write_entire_file(full, transmute([]byte)text) == nil, full, loc = loc)
}

@(private = "file") get_file :: proc(root, path: string) -> string {
	data, err := os.read_entire_file(fmt.tprintf("%s/%s", root, path), context.temp_allocator)
	return err == nil ? string(data) : ""
}

@(private = "file")
NAV :: "# the menu\nStart\n  a.md   Alpha\n  b.md\n  gone.md  Not there\nAPI\n  api/*  The API\n"

@(private = "file")
A_MD :: "# A page\n\nSee [b](b.md#two), [x](api/x.md), [readme](../README.md), [src](../src/), [pricing](../site/pricing/index.html) and ![p](shots/p.png).\n\n## One\n\n| a | b |\n|---|---|\n| `1|2` | 3 |\n\n## Two\n\n```odin\nx := 1\n```\n"

@(private = "file")
test_docs :: proc(root: string, assets: []string) -> Docs {
	return {
		source     = fmt.tprintf("%s/docs", root),
		out        = fmt.tprintf("%s/site/docs", root),
		name       = "Proj",
		site_url   = "https://proj.example/",
		repository = "https://github.com/o/proj",
		branch     = "main",
		note       = "<!-- made by docs_test -->",
		head       = "<link rel=\"stylesheet\" href=\"/docs/docs.css\">\n",
		header     = "<header><a href=\"/\">Home</a></header>\n",
		footer     = proc(d: ^Docs, p: ^Doc_Page) -> string { return fmt.tprintf("<footer>%s</footer>\n", p.rel) },
		assets     = assets,
		css        = {note = "/* made by docs_test */", bar = 50},
		moved      = true,
		writer     = {tool = "docs_test"},
	}
}

// A small documentation site made end to end in a scratch folder, checked, made again, and its links read back.
@(test)
a_docs_site_is_made_whole :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root, err := os.make_directory_temp("", "tk_site_docs_*", context.temp_allocator)
	testing.expect(t, err == nil, "a scratch folder")
	defer os.remove_all(root)
	put_file(t, root, "docs/_nav.txt", NAV)
	put_file(t, root, "docs/a.md", A_MD)
	put_file(t, root, "docs/b.md", "# B\n\n## Two\n\ntext\n")
	put_file(t, root, "docs/api/README.md", "# The API\n")
	put_file(t, root, "docs/api/x.md", "# Module x_y\n")
	put_file(t, root, "docs/extra.md", "no heading\n")
	put_file(t, root, "docs/_draft.md", "# Not a page\n")
	put_file(t, root, "docs/shots/p.png", "PNG")
	put_file(t, root, "site/index.html", "<p>home</p>")
	put_file(t, root, "site/pricing/index.html", "<p>pricing</p>")
	put_file(t, root, "site/docs/old/index.html", "<!-- made by docs_test -->\n<p>stale</p>")
	put_file(t, root, "site/docs/mine.html", "<p>not made here</p>")

	assets := []string{"shots"}
	d := test_docs(root, assets)
	testing.expect(t, build_docs(&d), "the site is made")
	testing.expect_value(t, d.writer.problems, 0)

	a := get_file(root, "site/docs/a/index.html")
	testing.expect(t, strings.has_prefix(a, "<!-- made by docs_test -->\n<!doctype html>"), "the note first")
	has(t, a, "<title>A page · Proj docs</title>")
	has(t, a, `<link rel="stylesheet" href="../../docs/docs.css">`)
	has(t, a, `<header><a href="../../">Home</a></header>`)
	// the menu, closed on a phone behind its toggle, the search, the groups, the page marked
	has(t, a, `<input class="doc-nav-toggle" type="checkbox" id="doc-nav">`)
	has(t, a, `<label class="doc-nav-open" for="doc-nav"><span></span><span></span><span></span> Documentation</label>`)
	has(t, a, `<input id="doc-search-input" type="search"`)
	has(t, a, `<li><a href="../../docs/a/" aria-current="page" class="active">Alpha</a></li>`)
	has(t, a, `<li><a href="../../docs/b/">B</a></li>`)
	has(t, a, "<li class=\"doc-group\"><details><summary>The API</summary>")
	has(t, a, `<li><a href="../../docs/api/README/">Overview</a></li>`)
	has(t, a, `<li><a href="../../docs/api/x/">Module x_y</a></li>`)
	has(t, a, "<p class=\"doc-sec-title\">More</p>\n<ul class=\"doc-links\">\n<li><a href=\"../../docs/extra/\">Extra</a></li>")
	testing.expect(t, !strings.contains(a, "gone") && !strings.contains(a, "draft"), "a missing or private document is not in the menu")
	// the breadcrumb, the links of the document, the next page, the table of contents, the edit link
	has(t, a, "<li><a href=\"../../docs/\">Docs</a></li>\n<li>Start</li>\n<li aria-current=\"page\">A page</li>")
	has(t, a, `<a href="../../docs/b/#two">b</a>`)
	has(t, a, `<a href="../../docs/api/x/">x</a>`)
	has(t, a, `<a href="https://github.com/o/proj/blob/main/README.md">readme</a>`)
	has(t, a, `<a href="https://github.com/o/proj/tree/main/src">src</a>`)
	has(t, a, `<a href="../../pricing/">pricing</a>`)
	has(t, a, `<img src="../../docs/shots/p.png" alt="p" loading="lazy">`)
	has(t, a, "<td><code>1|2</code></td>")
	has(t, a, "<div class=\"file\">Odin</div><pre><code>x := <span class=\"t\">1</span>")
	testing.expect(t, !strings.contains(a, "doc-prev"), "the first page has no previous one")
	has(t, a, `<a class="doc-next" href="../../docs/b/"><span>Next</span><strong>B</strong></a>`)
	has(t, a, "<p class=\"doc-toc-title\">On this page</p>\n<ul>\n<li><a href=\"#one\">One</a></li>\n<li><a href=\"#two\">Two</a></li>")
	has(t, a, `<a href="https://github.com/o/proj/blob/main/docs/a.md" rel="noopener">Edit this page on GitHub</a>`)
	has(t, a, "<footer>a.md</footer>\n<script src=\"../../docs/search.js\" defer></script>")

	// an open group, the previous page across sections
	x := get_file(root, "site/docs/api/x/index.html")
	has(t, x, "<li class=\"doc-group\"><details open><summary>The API</summary>")
	has(t, x, `<a class="doc-prev" href="../../../docs/api/README/"><span>Previous</span><strong>The API</strong></a>`)

	// no index.md: the documentation's home lists the pages
	index := get_file(root, "site/docs/index.html")
	has(t, index, "<title>Documentation · Proj docs</title>")
	has(t, index, `<li><a href="../docs/a/">Alpha</a></li>`)
	has(t, index, "<li><p>The API</p>\n<ul>")
	testing.expect(t, !strings.contains(index, "Edit this page"), "a made page has nothing to edit")

	// the style sheet, the search, the pictures, the old addresses, what is no longer made
	css := get_file(root, "site/docs/docs.css")
	testing.expect(t, strings.has_prefix(css, "/* made by docs_test */\n\n:root {"), "the style sheet's note first")
	has(t, css, "top: 50px;")
	has(t, css, ".doc-toc { position: sticky; top: 66px;")
	search := get_file(root, "site/docs/search-index.json")
	has(t, search, `{"u":"/docs/a/","t":"A page","s":"Start","b":"A page See b, x, readme`)
	testing.expect(t, !strings.contains(search, `"t":"Documentation"`), "the list of the pages is not searched")
	has(t, get_file(root, "site/docs/search.js"), "fetch(base+'search-index.json')")
	testing.expect_value(t, get_file(root, "site/docs/shots/p.png"), "PNG")
	moved := get_file(root, "site/docs/api/x.html")
	has(t, moved, `<link rel="canonical" href="https://proj.example/docs/api/x/">`)
	has(t, moved, `<meta http-equiv="refresh" content="0; url=x/">`)
	testing.expect(t, !os.exists(fmt.tprintf("%s/site/docs/old/index.html", root)), "a page no document makes is removed")
	testing.expect(t, os.exists(fmt.tprintf("%s/site/docs/mine.html", root)), "a page the tool did not make stays")

	// the links of the whole site resolve
	dead, pages := check_links(fmt.tprintf("%s/site", root), {folders = true})
	testing.expect_value(t, len(dead), 0)
	for line in dead { fmt.eprintln(line) }
	testing.expect(t, pages > 8, "every page is read")

	// made again: the same bytes, nothing to write; a document changed: the check says so
	again := test_docs(root, assets)
	again.writer.check = true
	testing.expect(t, build_docs(&again), "made again")
	testing.expect_value(t, again.writer.problems, 0)
	put_file(t, root, "docs/b.md", "# B changed\n")
	stale := test_docs(root, assets)
	stale.writer.check = true
	testing.expect(t, build_docs(&stale), "made with a change")
	testing.expect(t, stale.writer.problems > 0, "the check sees the change")
}

// What the link check finds wrong: a missing page, file or anchor, a link that leaves the site, a page linked by its .html.
@(test)
the_link_check_finds_dead_links :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root, err := os.make_directory_temp("", "tk_site_links_*", context.temp_allocator)
	testing.expect(t, err == nil, "a scratch folder")
	defer os.remove_all(root)
	put_file(t, root, "index.html", `<p id="top"><a href="a/">a</a> <a href="a/#here">here</a> <a href="#top">top</a> <img src="i.png"> <a href="wren-https://x">x</a> <a href="https://x.y/">out</a></p>`)
	put_file(t, root, "a/index.html", `<h1 id="here">A</h1><a href="../">up</a><a href="../b/">b</a><a href="#nope">nope</a><a href="/abs">abs</a><a href="../../up">far</a><a href="../index.html">html</a><img src="gone.png"><script>var s = '<a href="/script">'</script>`)
	put_file(t, root, "i.png", "PNG")
	dead, pages := check_links(root, {not_files = {"wren-"}, folders = true})
	testing.expect_value(t, pages, 2)
	got := strings.join(dead, "\n")
	testing.expect_value(t, got, strings.join({
		"a/index.html: ../../up climbs out of the site",
		"a/index.html: ../index.html names a .html: link the page's folder",
		"a/index.html: /abs starts with / and leaves the site (it lives under a path of its own): make it relative",
		"a/index.html: link to missing anchor #nope",
		"a/index.html: link to missing file gone.png",
		"a/index.html: link to missing page ../b/",
	}, "\n"))
	html_ok, _ := check_links(root, {not_files = {"wren-"}})
	testing.expect_value(t, len(html_ok), 5)
}

// The addresses of a page: root-absolute ones made relative to it, relative ones made root-absolute.
@(test)
addresses_move_between_relative_and_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, site_relative(`<a href="/docs/x/">x</a><img src="/img/a.png"><a href="//cdn/x">c</a><a href="/">r</a>`, "docs/x/index.html"), `<a href="../../docs/x/">x</a><img src="../../img/a.png"><a href="//cdn/x">c</a><a href="../../">r</a>`)
	testing.expect_value(t, site_relative(`<a href="/">r</a>`, "index.html"), `<a href="./">r</a>`)
	testing.expect_value(t, rooted(`<a href="../img/x.webp">i</a> <a href="./">h</a> <a href="#a">a</a> <a href="mailto:a@b">m</a> <a href="wren-https://x">w</a>`, "gallery"), `<a href="/img/x.webp">i</a> <a href="/gallery/">h</a> <a href="#a">a</a> <a href="mailto:a@b">m</a> <a href="wren-https://x">w</a>`)
	testing.expect_value(t, docs_out_rel("releases/v1.md"), "releases/v1/index.html")
	testing.expect_value(t, docs_out_rel("api/index.md"), "api/index.html")
	testing.expect_value(t, docs_page_url("api/index.html"), "/docs/api/")
}
