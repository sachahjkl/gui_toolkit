package tk_site

// The bar's links and the footer of a program's home page, the same on every site: the page holds two marks and
// build_changelog puts there what the site's Meta says, so a program declares data, not HTML. Every page made from the
// home (the changelog, the classic pages) then wears them.
//
//   <header class="bar"> <a class="brand" href="#">...</a> <button class="burger" ...> <!-- site-nav --> </header>
//       the nav#nav: Features, Download, Changelog, GitHub, and last, with a shop, "Buy license" (a button, as Wren's)
//   <!-- site-footer -->
//       the footer: the maker; the shop's pages and the source; the code's licence, Meta.footer_note, the toolkit, the
//       classic version
//
// The shop's own pages (licence_pages) list the same pages in their footer (SHOP_LINKS).

import "core:strings"

NAV_MARK    :: "<!-- site-nav -->"
FOOTER_MARK :: "<!-- site-footer -->"

// The shop's pages, from the site's root, in the order every footer lists them (licence_pages makes them): Wren's order,
// the pricing page first.
SHOP_LINKS :: [?]Link{
	{"pricing/", "Pricing"},
	{"privacy/", "Privacy"},
	{"terms/", "Terms"},
	{"refunds/", "Refunds"},
	{"imprint/", "Imprint"},
}

// The class of the nav's shop entry: the site's own accent button (every program's style.css has .btn.accent), made small
// by its .nav-buy rule.
NAV_BUY_CLASS :: "btn accent nav-buy"

// The word of the source's link, in the bar and in every footer.
SOURCE_LABEL :: "GitHub"

// The home page's nav: the sections every home page has (#features, #download), the changelog, the repository, and last
// the pricing page as a button ("Buy license") when the site sells a licence.
nav_html :: proc(m: Meta) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, "<nav id=\"nav\">\n",
		"    <a href=\"#", FEATURES_ID, "\">Features</a>\n",
		"    <a href=\"#", DOWNLOAD_ID, "\">Download</a>\n",
		"    <a href=\"", CHANGELOG_ADDRESS, "\">Changelog</a>\n",
		"    <a href=\"", esc(m.repository), "\">", SOURCE_LABEL, "</a>\n")
	if _, sells := m.shop.?; sells {
		links := SHOP_LINKS
		put(&b, "    <a href=\"", links[0].href, "\" class=\"", NAV_BUY_CLASS, "\">", BUY_LABEL, "</a>\n")   // (href first: nav_links reads it so)
	}
	put(&b, "  </nav>")
	return strings.to_string(b)
}

// The home page's footer. Its last link is CLASSIC_LINK: the changelog's and the classic pages' footers are this one.
footer_html :: proc(m: Meta) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, "<footer>\n  <p class=\"by\">By <span class=\"maker\">")
	if m.publisher_logo != "" { put(&b, `<img src="`, esc(m.publisher_logo), `" alt="" width="16" height="16">`) }
	put(&b, `<a href="`, esc(m.author_url), `">`, esc(m.publisher), "</a></span></p>\n  <p class=\"small\">")
	if _, sells := m.shop.?; sells {
		links := SHOP_LINKS
		for link in links { put(&b, `<a href="`, link.href, `">`, link.label, "</a> · ") }
	}
	put(&b, `<a href="`, esc(m.repository), `">`, SOURCE_LABEL, "</a></p>\n  <p class=\"small\">")
	if m.licence != "" { put(&b, "<span>", esc(m.licence), " License</span> · ") }
	if m.footer_note != "" { put(&b, "<span>", m.footer_note, "</span> · ") }
	put(&b, `<span>Built in <a href="https://odin-lang.org">Odin</a> on <a href="https://gt.sacha.house/">gui_toolkit</a></span> · `, CLASSIC_LINK, "</p>\n</footer>")
	return strings.to_string(b)
}

// The marks of `index` replaced by the nav and the footer of `m`. A page without the marks is left as it is. why: a mark
// and no repository to link (Changelog_Options.meta not given).
with_frame :: proc(index: string, m: Meta) -> (page: string, why: string) {
	has_nav, has_footer := strings.contains(index, NAV_MARK), strings.contains(index, FOOTER_MARK)
	if !has_nav && !has_footer { return index, "" }
	if m.repository == "" { return index, "a nav or footer mark, and no Meta to fill it (Changelog_Options.meta)" }
	page = index
	if has_nav { page, _ = strings.replace_all(page, NAV_MARK, nav_html(m), context.temp_allocator) }
	if has_footer { page, _ = strings.replace_all(page, FOOTER_MARK, footer_html(m), context.temp_allocator) }
	return page, ""
}
