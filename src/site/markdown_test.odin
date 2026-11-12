package tk_site

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file") has :: proc(t: ^testing.T, html, part: string, loc := #caller_location) {
	testing.expect(t, strings.contains(html, part), fmt.tprintf("%q is not in %q", part, html), loc = loc)
}

@(private = "file") html :: proc(md: string) -> string { return render_markdown(md, nil, context.temp_allocator).html }

@(test)
markdown_headings_and_paragraphs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	r := render_markdown("# Title (`x`)\n\nOne line\nand two.\n\n## Against core:compress\n\n### Third\n\n## Third\n")
	has(t, r.html, `<h1 id="title-x"><a class="anchor" href="#title-x" aria-hidden="true">#</a>Title (<code>x</code>)</h1>`)
	has(t, r.html, "<p>One line\nand two.</p>")
	has(t, r.html, `<h2 id="against-corecompress">`)
	// a second heading of the same text gets an id of its own
	has(t, r.html, `<h3 id="third">`)
	has(t, r.html, `<h2 id="third-1">`)
	testing.expect_value(t, len(r.headings), 4)
	testing.expect_value(t, r.headings[0].text, "Title (x)")
	has(t, r.plain, "One line and two.")
	// the title: the first "# " heading out of a code block, as plain text; a '_' inside a word stays
	testing.expect_value(t, markdown_title("text\n```\n# not a title\n```\n# The `gui_toolkit` [site](x.md) \\*\n"), "The gui_toolkit site *")
	testing.expect_value(t, markdown_title("**A release note.**\n\n# Later\n"), "")
	testing.expect_value(t, heading_id("A -- b_c: D!"), "a-b-c-d")
}

@(test)
markdown_inline_constructs :: proc(t: ^testing.T) {
	has(t, html("a **strong** and *em* and _em_ text"), "a <strong>strong</strong> and <em>em</em> and <em>em</em> text")
	has(t, html("gui_toolkit and api_generated"), "gui_toolkit and api_generated")
	// code is literal: no emphasis, no link, HTML escaped
	has(t, html("`a < b && **c** [d](e)`"), "<code>a &lt; b &amp;&amp; **c** [d](e)</code>")
	has(t, html("``a ` b``"), "<code>a ` b</code>")
	has(t, html("2 * 3 and *.png"), "2 * 3 and *.png")
	has(t, html("a <b> &amp; & c"), "a &lt;b&gt; &amp; &amp; c")
	has(t, html(`a \* b`), "a * b")
	has(t, html("![shot](x.png)"), `<img src="x.png" alt="shot" loading="lazy">`)
	has(t, html(`[the "link"](https://a.b/c "Its title")`), `<a href="https://a.b/c" title="Its title" rel="noopener">the "link"</a>`)
	has(t, html("<https://a.b> and <me@a.b>"), `<a href="https://a.b" rel="noopener">https://a.b</a> and <a href="mailto:me@a.b" rel="noopener">me@a.b</a>`)
	has(t, html("one  \ntwo"), "one  <br>\ntwo")
	// a link's address as the project's rule makes it
	rule :: proc(href: string, user: rawptr) -> string { return strings.concatenate({"pages/", href}, context.temp_allocator) }
	ctx := Markdown_Context{link = rule}
	has(t, render_markdown("[a](x.md) and ![b](y.png)", &ctx, context.temp_allocator).html, `<a href="pages/x.md">a</a> and <img src="pages/y.png"`)
}

@(test)
markdown_blocks_lists_and_quotes :: proc(t: ^testing.T) {
	out := html("Intro:\n\n- one\n  wrapped\n- two\n  - nested *a*\n  - nested b\n- three\n\n1. first\n2. second\n\n> quoted **text**\n\n---\n\n<div class=\"x\">kept</div>\n\nend")
	has(t, out, "<ul>\n<li>one\nwrapped</li>\n<li><p>two</p>\n<ul>\n<li>nested <em>a</em></li>\n<li>nested b</li>\n</ul></li>\n<li>three</li>\n</ul>")
	has(t, out, "<ol>\n<li>first</li>\n<li>second</li>\n</ol>")
	has(t, out, "<blockquote>\n<p>quoted <strong>text</strong></p>\n</blockquote>")
	has(t, out, "<hr>\n")
	has(t, out, "<div class=\"x\">kept</div>\n")
	has(t, out, "<p>end</p>")
	// a blank line inside an item makes its paragraphs
	has(t, html("- first\n\n  second\n- b\n"), "<li><p>first</p>\n<p>second</p></li>")
}

@(test)
markdown_tables :: proc(t: ^testing.T) {
	out := html("| A | B |\n|---|:-:|\n| `x|y` | **b** |\n| 2 | 3 \\| 4 |\n\nafter")
	has(t, out, `<div class="table-box"><table>`)
	has(t, out, `<thead><tr><th>A</th><th style="text-align:center">B</th></tr></thead>`)
	// a '|' in a code span is not a cell's end
	has(t, out, `<tr><td><code>x|y</code></td><td style="text-align:center"><strong>b</strong></td></tr>`)
	has(t, out, "<td>2</td><td style=\"text-align:center\">3 | 4</td>")
	has(t, out, "</table></div>\n<p>after</p>")
}

@(test)
code_blocks_are_coloured :: proc(t: ^testing.T) {
	out := html("```odin\nmain :: proc() { x := 1 // one\n\tfmt.println(\"a < b\") }\n```\n\n~~~\nplain <b>\n~~~\n\n```text\nas is\n```\n")
	has(t, out, `<div class="code"><div class="file">Odin</div><pre><code>main :: <span class="k">proc</span>() { x := <span class="t">1</span> <span class="c">// one</span>`)
	has(t, out, "\tfmt.<span class=\"f\">println</span>(<span class=\"s\">\"a &lt; b\"</span>) }")
	has(t, out, `<div class="code"><pre><code>plain &lt;b&gt;</code></pre></div>`)
	has(t, out, `<div class="code"><div class="file"></div><pre><code>as is</code></pre></div>`)
	// a project's own language comes before the others
	mine := []Code_Language{{names = {"odin", "mine"}, label = "Mine", highlight = true, keywords = {"main"}}}
	b := strings.builder_make(context.temp_allocator)
	write_code_block(&b, "main x", "odin", mine)
	testing.expect_value(t, strings.to_string(b), "<div class=\"code\"><div class=\"file\">Mine</div><pre><code><span class=\"k\">main</span> x</code></pre></div>\n")
	strings.builder_reset(&b)
	write_code_block(&b, "a", "cobol")
	testing.expect_value(t, strings.to_string(b), "<div class=\"code\"><div class=\"file\">cobol</div><pre><code>a</code></pre></div>\n")
}
