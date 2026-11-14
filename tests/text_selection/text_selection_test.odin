// Text a person reads is selectable by default, a control's label is not (src/md/features/text-selection.md). For each
// kind of widget: a drag over it selects and Ctrl+C copies, or nothing is selected. Then selectable text in a clickable
// row: a click is the row's, a drag selects and the row gets no click. Builds without a window; the ui state of a build
// is global: one test thread.
//   odin run tools/run_tests -- text_selection
package text_selection_test

import "core:strings"
import "core:testing"
import tk_diff "../../src/diff"
import "../../src/font"
import "../../src/markdown"
import "../../src/platform"
import "../../src/ui"

@(private = "file") WINDOW :: ui.Vec2{600, 400}

@(private = "file")
Kind :: enum {
	Paragraph,
	Rich,
	Label,           // a control's name: not selectable
	Matched_Label,   // a row's lit name: not selectable
	Content_Label,   // a label marked .Selectable
	Empty_State,
	Diff,
	Markdown,
	Row,             // a .Selectable label in a clickable row
}

@(private = "file")
Fx :: struct {
	fonts:   font.State,
	theme:   ui.Theme,
	s:       ui.State,
	ui_font: font.Font_Id,
	clock:   f64,
	kind:    Kind,
	target:  ^ui.Box,   // the box dragged over
	md:      markdown.Doc,
	diff:    []tk_diff.Line,
	clicks:  int,       // the row's
	copies:  int,       // the program's own Ctrl+C command
	on_para: bool,      // .Row: the target is the paragraph above the row, `row` the row's text
	row:     ^ui.Box,
}

@(private = "file") COPY := ui.Command{label = "Copy the files", keys = {{.C, {.Ctrl}}}}

// (the clipboard callbacks take no argument: one test thread)
@(private = "file") clip: string

@(private = "file")
open :: proc(f: ^Fx) -> bool {
	font.init(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !ok { return false }
	ui.apply_palette(&f.theme, ui.palette_of("Midnight"))
	ui.init(&f.s, &f.fonts, &f.theme)
	f.ui_font = id
	f.diff = tk_diff.parse_lines("--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n-old line\n+new line\n same line\n")
	return true
}

@(private = "file")
close :: proc(f: ^Fx) {
	markdown.doc_destroy(&f.md)
	delete(f.diff)
	ui.destroy(&f.s)
	ui.theme_destroy(&f.theme)
	font.destroy(&f.fonts)
	delete(clip)
	clip = ""
}

@(private = "file")
frame :: proc(f: ^Fx, events: []platform.Event = nil) {
	f.clock += 16
	ui.begin_build(&f.s, {
		window_size = WINDOW, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1, time_ms = f.clock,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.ui_font, font_size = 15, text_pad = 6},
		clipboard_get = proc() -> string { return clip },
		clipboard_set = proc(t: string) { delete(clip); clip = strings.clone(t) },
	})
	if ui.command_pressed(COPY) { f.copies += 1 }
	ui.next({width = ui.px(400), height = ui.px(300), axis = .Y})
	if ui.column(id = "###frame") {
		switch f.kind {
		case .Paragraph:
			f.target = ui.paragraph("First words of a paragraph, then more words###t").box
		case .Rich:
			f.target = ui.rich_paragraph("###t", {{text = "Rich "}, {text = "bold", style = {bold = true}}, {text = " words"}}).box
		case .Label:
			f.target = ui.label("Font size###t").box
		case .Matched_Label:
			f.target = ui.matched_label("###t", "matched name", {{0, 3}})
		case .Content_Label:
			ui.next({flags = {.Selectable}})
			f.target = ui.label("A value to copy###t").box
		case .Empty_State:
			_ = ui.empty_state("empty", {title = "Nothing in this folder"})
			f.target = find_text(ui.parent_box(), "Nothing in this folder")
		case .Diff:
			tk_diff.lines_view("###d", f.diff, true)
			f.target = ui.parent_box().last
		case .Markdown:
			// (in a column of its own: view builds its blocks in its parent, the last one is the code block's frame)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###md_frame") {
				markdown.view(&f.md, "md", "A *Markdown* paragraph.\n\n```\ncode line\n```\n", {})
			}
			f.target = ui.parent_box().last
		case .Row:
			para := ui.paragraph("Selected words###p").box
			ui.next({width = ui.fill(), height = ui.px(40), axis = .X})
			row := ui.build_box({.Clickable, .Draw_Background}, "###row")
			if ui.parent(row) {
				ui.next({flags = {.Selectable}})
				f.target = ui.label("History item text###t").box
			}
			if ui.signal(row).clicked { f.clicks += 1 }
			if f.on_para { f.row, f.target = f.target, para }
		}
	}
	ui.end_build()
	free_all(context.temp_allocator)
}

// The box under `b` that shows `text` (nil: none).
@(private = "file")
find_text :: proc(b: ^ui.Box, text: string) -> ^ui.Box {
	if b.text == text { return b }
	for c := b.first; c != nil; c = c.next {
		if got := find_text(c, text); got != nil { return got }
	}
	return nil
}

// The .Selectable boxes under `b`, `b` with them, in build order.
@(private = "file")
selectables :: proc(b: ^ui.Box, out: ^[dynamic]^ui.Box) {
	if .Selectable in b.flags { append(out, b) }
	for c := b.first; c != nil; c = c.next { selectables(c, out) }
}

@(private = "file") press :: proc(p: ui.Vec2) -> platform.Event { return {kind = .Mouse_Press, pos = p, button = .Left} }
@(private = "file") release :: proc(p: ui.Vec2) -> platform.Event { return {kind = .Mouse_Release, pos = p, button = .Left} }
@(private = "file") move :: proc(p: ui.Vec2) -> platform.Event { return {kind = .Mouse_Move, pos = p} }

// A drag from the start of the target's first line to its bottom right, then Ctrl+C: what the clipboard has ("": no copy).
@(private = "file")
drag_copy :: proc(f: ^Fx) -> string {
	delete(clip)
	clip = ""
	ui.clear_selection(&f.s)
	frame(f)
	frame(f)
	// (from the first selectable box in the target to the last: a diff's text is after its gutters)
	first, last := f.target, f.target
	boxes := make([dynamic]^ui.Box, context.temp_allocator)
	selectables(f.target, &boxes)
	if len(boxes) > 0 { first, last = boxes[0], boxes[len(boxes) - 1] }
	r := first.rect
	from := ui.Vec2{r.min.x + first.text_pad + 0.5, r.min.y + min(10, (r.max.y - r.min.y) * 0.5)}
	to := ui.Vec2{last.rect.max.x - 2, last.rect.max.y - 2}
	frame(f, {move(from)})
	frame(f, {press(from)})
	frame(f, {move((from + to) * 0.5)})
	frame(f, {move(to)})
	frame(f, {release(to)})
	frame(f, {{kind = .Key_Press, key = .C, mods = {.Ctrl}}})
	frame(f, {{kind = .Key_Release, key = .C, mods = {.Ctrl}}})
	for _ in 0 ..< 30 { frame(f) }   // (the next press is no double click)
	return clip
}

@(private = "file")
fixture :: proc(t: ^testing.T) -> ^Fx {
	f := new(Fx)
	if !testing.expect(t, open(f), "the embedded face") { free(f); return nil }
	return f
}

@(private = "file")
done :: proc(f: ^Fx) { close(f); free(f) }

@(test)
content_widgets_select_by_default :: proc(t: ^testing.T) {
	f := fixture(t)
	if f == nil { return }
	defer done(f)
	expect_copy :: proc(t: ^testing.T, f: ^Fx, kind: Kind, start: string, loc := #caller_location) {
		f.kind = kind
		frame(f)
		if !testing.expectf(t, f.target != nil, "%v: built", kind, loc = loc) { return }
		got := drag_copy(f)
		testing.expectf(t, got != "" && strings.has_prefix(got, start), "%v: a drag selects, Ctrl+C copies: %q", kind, got, loc = loc)
	}
	expect_copy(t, f, .Paragraph, "First words")
	expect_copy(t, f, .Rich, "Rich bold")
	expect_copy(t, f, .Content_Label, "A value")
	expect_copy(t, f, .Empty_State, "Nothing")
	expect_copy(t, f, .Markdown, "A Markdown paragraph.\n\ncode line")   // (its blocks apart by a blank line, as the source)
}

// The diff's rows: a drag from the first line's text down to the last selects across them.
@(test)
a_diff_selects_across_its_rows :: proc(t: ^testing.T) {
	f := fixture(t)
	if f == nil { return }
	defer done(f)
	f.kind = .Diff
	frame(f)
	frame(f)
	if !testing.expect(t, f.target != nil, "built") { return }
	got := drag_copy(f)
	testing.expectf(t, strings.contains(got, "old line") && strings.contains(got, "new line"), "two rows of the diff: %q", got)
}

// A control's label and a row's lit name are not content: a drag over them selects nothing.
@(test)
control_labels_do_not_select :: proc(t: ^testing.T) {
	f := fixture(t)
	if f == nil { return }
	defer done(f)
	for kind in ([]Kind{.Label, .Matched_Label}) {
		f.kind = kind
		frame(f)
		if !testing.expectf(t, f.target != nil, "%v: built", kind) { continue }
		got := drag_copy(f)
		testing.expectf(t, got == "" && !ui.has_selection(&f.s), "%v: nothing selected: %q", kind, got)
	}
}

// Selectable text in a clickable row: a press and a release is the row's click and selects nothing; a press that moves
// selects, and the row gets no click.
@(test)
a_click_acts_a_drag_selects :: proc(t: ^testing.T) {
	f := fixture(t)
	if f == nil { return }
	defer done(f)
	f.kind = .Row
	frame(f)
	frame(f)
	if !testing.expect(t, f.target != nil, "built") { return }
	r := f.target.rect
	at := ui.Vec2{r.min.x + f.target.text_pad + 0.5, (r.min.y + r.max.y) * 0.5}
	frame(f, {move(at)})
	frame(f, {press(at)})
	frame(f, {release(at)})
	frame(f)
	testing.expect_value(t, f.clicks, 1)
	testing.expect(t, !ui.has_selection(&f.s), "a click selects nothing")
	for _ in 0 ..< 30 { frame(f) }
	// a small move under the slop is still a click
	frame(f, {press(at)})
	frame(f, {move(at + {2, 0})})
	frame(f, {release(at + {2, 0})})
	frame(f)
	testing.expect_value(t, f.clicks, 2)
	testing.expect(t, !ui.has_selection(&f.s), "a jitter selects nothing")
	for _ in 0 ..< 30 { frame(f) }
	got := drag_copy(f)
	testing.expect_value(t, f.clicks, 2)
	testing.expectf(t, strings.has_prefix(got, "History"), "a drag selects and copies: %q", got)
}

// The program's own Ctrl+C command: not while text that the last press selected is there (the selection copies); again
// after a press elsewhere (a row picked), though the selection still shows.
@(test)
the_selection_takes_ctrl_c_from_a_command :: proc(t: ^testing.T) {
	f := fixture(t)
	if f == nil { return }
	defer done(f)
	f.kind, f.on_para = .Row, true
	frame(f)
	got := drag_copy(f)
	testing.expectf(t, strings.has_prefix(got, "Selected"), "the selection copied: %q", got)
	testing.expect_value(t, f.copies, 0)
	// a click on the row: the selection stays, Ctrl+C is the command's
	delete(clip)
	clip = ""
	r := f.row.rect
	at := ui.Vec2{r.max.x + 100, (r.min.y + r.max.y) * 0.5}   // (the row, past its text)
	frame(f, {move(at)})
	frame(f, {press(at)})
	frame(f, {release(at)})
	testing.expect_value(t, f.clicks, 1)
	testing.expect(t, ui.has_selection(&f.s), "the selection still shows")
	frame(f, {{kind = .Key_Press, key = .C, mods = {.Ctrl}}})
	frame(f)
	testing.expect_value(t, f.copies, 1)
	testing.expect_value(t, clip, "")
}
