package tk

// The toolkit's site, made when it is deployed (.github/workflows/pages.yml) so that it cannot be behind a release. The steps are
// src/site's; this file says what the toolkit's site is (its address, names, colours).
//   site_build <site> <out>        the three steps below, in order, then the links of <out> (site.check_links): <out> is what is published
//   site_changelog <site> <out>    <out> gets a copy of <site>, the history and the classic pages (site.build_changelog)
//   site_meta <site> <out>         what a page says when it is shared, the feed, the sitemap, the files around the pages (site.build_meta)
//   site_docs <site> <out>         docs/*.md as pages, docs/_nav.txt their menu (site.build_docs; site_docs.odin)
//   site_card                      draws site/img/card.png, once, by hand, in a local Chromium (CHROME, or the usual places)
//   site_check [--site folder] [--shot file.png] [--browser program]
//                                  the site as published (site_build) in a real browser with no window, served on 127.0.0.1 (site.check)

import "core:fmt"
import tk_site "../../src/site"

SITE_META :: tk_site.Meta{
	url         = "https://gt.sacha.house/",
	name        = "gui_toolkit",
	repository  = "https://github.com/sachahjkl/gui_toolkit",
	tagline     = "A fast, native, immediate-mode GUI toolkit in Odin",
	card        = "img/card.png",
	logo        = "img/logo.png",
	theme       = "#111111",
	accent      = "#6f9cf0",
	author      = "Sacha Froment",
	author_url  = "https://froment.software",
	publisher   = "Froment Software",
	ld_type     = "SoftwareSourceCode",
	card_title  = "gui_toolkit",
	card_size   = 150,
	card_logo   = 168,
	card_font   = `"Segoe UI Variable Display", "Segoe UI", sans-serif`,
}

// What the home's structured data says besides its names.
@(private = "file") SITE_LD :: [?][2]string{
	{"programmingLanguage", "Odin"},
	{"codeRepository", "https://github.com/sachahjkl/gui_toolkit"},
	{"license", "https://opensource.org/license/mit"},
}

// The toolkit's site, its files in the checkout `root`.
site_meta :: proc(root: string) -> tk_site.Meta {
	m := SITE_META
	ld := SITE_LD
	m.ld_fields = make([][2]string, len(ld), context.temp_allocator)
	copy(m.ld_fields, ld[:])
	m.changes = join({root, "CHANGELOG.md"})
	m.logo_file = join({root, "site", "img", "logo.png"})
	return m
}

site_changelog :: proc(site, out: string) -> bool {
	return tk_site.build_changelog(site, out, {changes = join({toolkit_root(), "CHANGELOG.md"})})
}

run_site_changelog :: proc(a: ^Args) -> string {
	return site_changelog(a.positionals[0], a.positionals[1]) ? "" : "the pages were not made"
}

run_site_meta :: proc(a: ^Args) -> string {
	return tk_site.build_meta(site_meta(toolkit_root()), a.positionals[0], a.positionals[1]) ? "" : "the pages were not made"
}

run_site_card :: proc(a: ^Args) -> string {
	root := toolkit_root()
	return tk_site.draw_card(site_meta(root), join({root, "site"})) ? "" : "no card"
}

// The site as it is published.
site_build :: proc(site, out: string) -> string {
	if !site_changelog(site, out) { return "the changelog's pages were not made" }
	if !tk_site.build_meta(site_meta(toolkit_root()), out, out) { return "what the pages say when shared was not made" }
	if why := build_docs(join({toolkit_root(), "docs"}), site, out); why != "" { return why }
	dead, pages := tk_site.check_links(out, {})
	for d in dead { fmt.println(d) }
	if len(dead) > 0 { return fmt.tprintf("%d dead links or anchors in %s", len(dead), out) }
	fmt.printfln("%d pages, every link, file and anchor resolves: %s", pages, out)
	return ""
}

run_site_build :: proc(a: ^Args) -> string { return site_build(a.positionals[0], a.positionals[1]) }

run_site_check :: proc(a: ^Args) -> string {
	generate :: proc(site, out: string) -> bool {
		why := site_build(site, out)
		if why != "" { fmt.eprintln(why) }
		return why == ""
	}
	o := tk_site.Check_Options{site = join({toolkit_root(), "site"}), generate = generate}
	if why := tk_site.check_arguments(a.positionals[:], &o); why != "" { return why }
	return tk_site.check(o) ? "" : fmt.tprintf("the site differs from what it must be")
}
