package markdown_test

// Link words (src/md/features/link-words.md): a program's own words, by their prefix, are links in plain text, in
// Markdown and alone in inline code; not inside another word; the word is its own target. (The prefixes are the
// process's: this binary sets them once, here.)

import "core:testing"
import "gt:markdown"
import "gt:ui"

@(test)
a_program_s_words_are_links :: proc(t: ^testing.T) {
	ui.link_words_set({"zzq_"})
	links :: proc(runs: []ui.Rich_Run) -> [dynamic]string {
		out := make([dynamic]string, context.temp_allocator)
		for r in runs { if r.link != "" { append(&out, r.link) } }
		return out
	}
	Case :: struct { text: string, want: []string }
	plain := []Case{
		{"open zzq_A1b2 now.", {"zzq_A1b2"}},
		{"(zzq_x_9), then https://a.b and zzq_y", {"zzq_x_9", "https://a.b", "zzq_y"}},
		{"xzzq_no zzq_ zzq", {}},
	}
	for c in plain {
		runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
		ui.rich_links(c.text, {}, &runs)
		got := links(runs[:])
		testing.expectf(t, len(got) == len(c.want), "%q: %v, wanted %v", c.text, got[:], c.want)
		for w, i in c.want { if i < len(got) { testing.expect_value(t, got[i], w) } }
	}
	md := []Case{
		{"the **session** zzq_abc ended", {"zzq_abc"}},
		{"see `zzq_def` and `zzq_ x` and ``", {"zzq_def"}},
	}
	for c in md {
		runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
		markdown.inline_runs(c.text, {}, &runs)
		got := links(runs[:])
		testing.expectf(t, len(got) == len(c.want), "%q: %v, wanted %v", c.text, got[:], c.want)
		for w, i in c.want { if i < len(got) { testing.expect_value(t, got[i], w) } }
	}
}
