package tk

import "core:fmt"
import "core:strings"
import tk_site "../../src/site"
import toolbox "../../src/toolbox"

// site_docs <site> <out>: the Docs section, <out>/docs/, made by src/site (tk_site.build_docs, docs/site.md) of docs/*.md and
// docs/_nav.txt. This file says what is the toolkit's: the home page's header and menu script (from <site>/index.html, so a
// change there reaches the docs without a second copy), its footer, its colours and its headings.

GITHUB :: "https://github.com/sachahjkl/gui_toolkit"

run_site_docs :: proc(args: []string) -> string {
	return build_docs(join({toolkit_root(), "docs"}), toolbox.plain_args(args)[0], toolbox.plain_args(args)[1])
}

// Reads `docs_dir` and `site`/index.html, writes `out`/docs/.
build_docs :: proc(docs_dir, site, out: string) -> string {
	index, ok := read_text(join({site, "index.html"}))
	if !ok { return fmt.tprintf("%s/index.html cannot be read", site) }
	header := between(index, "<header class=\"bar\">", "</header>")
	script := between(index, "<script>", "</script>")
	if header == "" || script == "" { return fmt.tprintf("%s/index.html has no header or no script", site) }
	footer := fmt.tprintf(`<footer>
<p>gui_toolkit, MIT licence. These pages are the Markdown files of <a href="%s/tree/master/docs">docs/</a>.</p>
</footer>
<script>%s</script>
`, GITHUB, script)
	d := tk_site.Docs{
		source     = docs_dir,
		out        = join({out, "docs"}),
		name       = "gui_toolkit",
		site_url   = SITE_META.url,
		repository = GITHUB,
		branch     = "master",
		note       = "<!-- Made by tk site_docs from docs/*.md: edit those. -->",
		head       = "<link rel=\"icon\" href=\"/img/logo.png\">\n<link rel=\"stylesheet\" href=\"/style.css\">\n<link rel=\"stylesheet\" href=\"/docs/docs.css\">\n",
		header     = fmt.tprintf("<header class=\"bar\">%s</header>\n", home_links(header)),
		footer     = proc(d: ^tk_site.Docs, p: ^tk_site.Doc_Page) -> string { return (^string)(d.user)^ },
		assets     = {"screenshots"},
		css        = {note = "/* Made by tk site_docs. Layers over style.css. */", bar = DOCS_BAR, theme = DOCS_THEME, extra = DOCS_CODE_AND_LOOK},
		moved      = true,   // (the pages were docs/<name>.html)
		user       = &footer,
		writer     = {tool = "site_docs"},
	}
	if !tk_site.build_docs(&d) { return "the Docs pages were not made" }
	if d.writer.problems > 0 { return fmt.tprintf("%d files of the Docs pages were not written", d.writer.problems) }
	return ""
}

// The home page's links as root-absolute ones (build_docs makes them relative to each page): "#x" is the home's, "img/x.png" is
// "/img/x.png". Addresses with a scheme stay.
home_links :: proc(html: string) -> string {
	rooted := tk_site.rooted(html, "")
	out, _ := strings.replace_all(rooted, ` href="#`, ` href="/#`, context.temp_allocator)
	return out
}

// The text of `s` between the first `open` and the next `close`.
between :: proc(s, open, close: string) -> string {
	i := strings.index(s, open)
	if i < 0 { return "" }
	rest := s[i + len(open):]
	j := strings.index(rest, close)
	return j < 0 ? "" : rest[:j]
}

// The height of the site's bar (.bar in site/style.css), in px: the menu and the table of contents stay under it.
DOCS_BAR :: 50

// The colours the docs' style sheet reads, from the site's own (site/style.css).
DOCS_THEME :: `/* the toolkit's colours, under the names the docs' style sheet reads */
:root {
  --bg: var(--bg0);
  --surface: var(--bg1);
  --surface-2: var(--bg2);
  --line: #262626;
  --line-2: #3a3a3a;
  --muted: var(--weak);
  --soft: var(--faint);
  --accent-dim: rgba(111, 156, 240, 0.14);
}
`

DOCS_CODE_AND_LOOK :: tk_site.DOCS_CODE_CSS + `
/* the toolkit's look: headings in its monospace face; a page's <main> is not centred by the site's rule for main */
.doc-main { max-width: none; margin: 0; }
.doc-article { overflow-wrap: break-word; }
.doc-article h1 { font: 700 clamp(1.6rem, 4vw, 2.2rem) var(--mono); overflow-wrap: anywhere; }
.doc-article h2 { font: 700 1.35rem var(--mono); }
.doc-article h3 { font: 700 1.05rem var(--mono); color: var(--cyan); }
.doc-article h4, .doc-article h5, .doc-article h6 { font: 700 0.95rem var(--mono); }
.doc-article img { max-width: 100%; height: auto; }
.doc-seq a { min-width: 0; }
.doc-sec-title, .doc-toc-title { font-family: var(--mono); }
`
