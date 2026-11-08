package tk_site

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file") has :: proc(t: ^testing.T, html, part: string, loc := #caller_location) {
	testing.expect(t, strings.contains(html, part), fmt.tprintf("%q is not in %q", part, html), loc = loc)
}

@(test)
markdown_headings_and_paragraphs :: proc(t: ^testing.T) {
	html := markdown_html("# Title (`x`)\n\nOne line\nand two.\n\n## Against core:compress\n\n### Third\n")
	has(t, html, `<h1 id="title-x">Title (<code>x</code>)</h1>`)
	has(t, html, "<p>One line\nand two.</p>")
	has(t, html, `<h2 id="against-corecompress">Against core:compress</h2>`)
	has(t, html, `<h3 id="third">Third</h3>`)
	testing.expect_value(t, markdown_title("text\n```\n# not a title\n```\n# The title `x`\n"), "The title x")
}

@(test)
markdown_inline_constructs :: proc(t: ^testing.T) {
	has(t, markdown_html("a **strong** and *em* text"), "a <strong>strong</strong> and <em>em</em> text")
	has(t, markdown_html("a **strong\nacross** lines"), "<strong>strong\nacross</strong>")
	// code is literal: no emphasis, no link, HTML escaped
	has(t, markdown_html("`a < b && **c** [d](e)`"), "<code>a &lt; b &amp;&amp; **c** [d](e)</code>")
	has(t, markdown_html("``a ` b``"), "<code>a ` b</code>")
	// a star that opens nothing stays a star
	has(t, markdown_html("2 * 3 and *.png"), "2 * 3 and *.png")
	has(t, markdown_html("<b>&\"</b>"), "&lt;b&gt;&amp;&quot;&lt;/b&gt;")
	has(t, markdown_html(`a \* b \`),  "a * b \\")
	has(t, markdown_html("![shot](screenshots/x.png)"), `<img src="screenshots/x.png" alt="shot" loading="lazy">`)
	has(t, markdown_html("[the `code` link](x.md)"), `<a href="x.md">the <code>code</code> link</a>`)
	// a link's address as the project's rule makes it
	page :: proc(url: string) -> string { return strings.concatenate({"pages/", url}, context.temp_allocator) }
	has(t, markdown_html("[a](x.md) and [b](y)", page), `<a href="pages/x.md">a</a> and <a href="pages/y">b</a>`)
}

@(test)
markdown_code_blocks :: proc(t: ^testing.T) {
	html := markdown_html("```odin\nif a < b {\n\t# not a heading\n\n\t- not a list\n}\n```\nafter\n\n```\nplain\n```\n")
	has(t, html, "<pre><code class=\"language-odin\">if a &lt; b {\n\t# not a heading\n\n\t- not a list\n}</code></pre>")
	has(t, html, "<pre><code>plain</code></pre>")
	has(t, html, "<p>after</p>")
}

@(test)
markdown_lists :: proc(t: ^testing.T) {
	html := markdown_html("Intro:\n- one\n  wrapped\n- two\n  - nested *a*\n  - nested b\n- three\n\n1. first\n2. second\n   ```\n   code\n   ```\n\nend")
	has(t, html, "<p>Intro:</p>\n<ul>\n<li>one\nwrapped\n</li>")
	has(t, html, "<li>two\n<ul>\n<li>nested <em>a</em>\n</li>\n<li>nested b\n</li>\n</ul>\n</li>")
	has(t, html, "<li>three\n</li>\n</ul>")
	has(t, html, "<ol>\n<li>")
	has(t, html, "<li>second\n<pre><code>code</code></pre>\n</li>\n</ol>")
	has(t, html, "<p>end</p>")
	// a blank line between two items keeps one list
	testing.expect_value(t, strings.count(markdown_html("- a\n\n- b\n"), "<ul>"), 1)
}

@(test)
markdown_tables :: proc(t: ^testing.T) {
	html := markdown_html("| A | B |\n|---|:--|\n| `x|y` | **b** |\n| 2 | 3 \\| 4 |\n\nafter")
	has(t, html, "<thead><tr><th>A</th><th>B</th></tr></thead>")
	has(t, html, "<tr><td><code>x|y</code></td><td><strong>b</strong></td></tr>")
	has(t, html, "<td>2</td><td>3 | 4</td>")
	has(t, html, "</table></div>\n<p>after</p>")
}

@(test)
markdown_loose_list_items_keep_paragraphs :: proc(t: ^testing.T) {
	has(t, markdown_html("- first\n\n  second\n- b\n"), "<li><p>first</p>\n<p>second</p>\n</li>")
}
