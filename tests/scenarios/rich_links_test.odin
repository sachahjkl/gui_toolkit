package scenarios_test

import "core:strings"
import "core:testing"
import "../../src/ui"

// rich_links: the web addresses of plain text become link runs, without the marks that end the sentence around them.
@(test)
rich_links_finds_web_addresses :: proc(t: ^testing.T) {
	Case :: struct { text: string, links: []string }
	cases := []Case{
		{"see https://sacha.house.", {"https://sacha.house"}},
		{"(at http://a.b/c_(d)), then https://x.y/?q=1&r=2!", {"http://a.b/c_(d)", "https://x.y/?q=1&r=2"}},
		{"<https://a.b/c> and \"https://d.e\"", {"https://a.b/c", "https://d.e"}},
		{"[doc](https://a.b/x) `https://c.d`", {"https://a.b/x", "https://c.d"}},
		{"xhttps://no.link https:// ftp://no.link", {}},
		{"line\nhttps://a.b\tthen", {"https://a.b"}},
		{"plain text", {}},
	}
	for c in cases {
		runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
		ui.rich_links(c.text, {bold = true}, &runs)
		got := make([dynamic]string, context.temp_allocator)
		joined := strings.builder_make(context.temp_allocator)
		for r in runs {
			strings.write_string(&joined, r.text)
			testing.expect(t, r.bold, "each run keeps the style")
			if r.link != "" {
				append(&got, r.link)
				testing.expectf(t, r.underline && r.color.a == 0 && r.text == r.link, "%q: a link run is underlined, in the link colour", c.text)
			}
		}
		testing.expectf(t, strings.to_string(joined) == c.text, "%q: the runs are the whole text", c.text)
		testing.expectf(t, len(got) == len(c.links), "%q: links %v, wanted %v", c.text, got[:], c.links)
		for l, i in c.links { if i < len(got) { testing.expectf(t, got[i] == l, "%q: link %q, wanted %q", c.text, got[i], l) } }
	}
}
