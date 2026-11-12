// The terminal widget (src/term) on a screen of the test's own (Fake): no emulator, no window, no font. The row cache and its
// dirty flags, the selection made with the pointer and copied, the keys turned into bytes, the paste keys, the press held
// and let go, the zoom keys.
//   odin test tests/term -vet
package term_test

import "base:runtime"
import "core:strings"
import "core:testing"
import "../../src/platform"
import "../../src/term"

// A screen of a few rows of ASCII, each cell a byte. The selection is on one row, as the widget asks for it.
Fake :: struct {
	lines:      [4]string,
	changed:    [4]bool,       // the rows written since they were read
	dirty:      term.Dirty,
	cells_read: int,
	out:        [dynamic]u8,   // what the widget sent
	modes:      term.Modes,
	sel:        bool,
	anchor:     [2]int,
	sel_to:     [2]int,
	scrolled:   int,
	bottom:     bool,
	encoder:    bool,          // the fake has an encoder of its own: every key is "<k>"
}

fake_source :: proc(f: ^Fake) -> term.Source {
	return {
		data = f,
		picture = proc(data: rawptr) -> (p: term.Picture, ok: bool) {
			f := (^Fake)(data)
			p.dirty = f.dirty
			p.foreground, p.background = {1, 1, 1, 1}, {0, 0, 0, 1}
			return p, true
		},
		rows = proc(data: rawptr, sink: ^term.Sink) {
			f := (^Fake)(data)
			for line, y in f.lines {
				if !term.sink_row(sink, f.changed[y]) { continue }
				for x in 0 ..< len(line) {
					flags: term.Cell_Flags
					if f.sel && y == f.anchor.y && x >= min(f.anchor.x, f.sel_to.x) && x <= max(f.anchor.x, f.sel_to.x) { flags += {.Selected} }
					term.sink_cell(sink, {text = line[x:x + 1], fg = {1, 1, 1, 1}, flags = flags})
					f.cells_read += 1
				}
			}
			f.changed = {}
			f.dirty = .None
		},
		scrollbar = proc(data: rawptr) -> (bar: term.Scrollbar, ok: bool) { return {total = 100, offset = 96, len = 4}, true },
		scroll = proc(data: rawptr, delta: int, bottom: bool) {
			f := (^Fake)(data)
			if bottom { f.bottom = true } else { f.scrolled += delta }
		},
		write = proc(data: rawptr, bytes: string) { append(&(^Fake)(data).out, bytes) },
		modes = proc(data: rawptr) -> term.Modes { return (^Fake)(data).modes },
		encode_key = proc(data: rawptr, k: term.Key_Input, buf: []u8) -> int {
			f := (^Fake)(data)
			if !f.encoder { return len(term.xterm_key(k, .App_Cursor in f.modes, buf)) }
			return copy(buf, "<k>")
		},
		select = proc(data: rawptr, op: term.Select_Op, cell: [2]int) -> bool {
			f := (^Fake)(data)
			switch op {
			case .Has:    return f.sel
			case .Begin:  f.sel, f.anchor = false, cell
			case .Extend: f.sel, f.sel_to = true, cell
			case .End:
			case .Drop:   f.sel = false
			case .All:    f.sel, f.anchor, f.sel_to = true, {0, 0}, {79, 0}
			}
			return true
		},
		selection_text = proc(data: rawptr, allocator: runtime.Allocator) -> string {
			f := (^Fake)(data)
			line := f.lines[f.anchor.y]
			from, to := min(f.anchor.x, f.sel_to.x), min(max(f.anchor.x, f.sel_to.x) + 1, len(line))
			return strings.clone(line[min(from, to):to], allocator)
		},
	}
}

// A view laid out as a build leaves it: 80 by 4 cells of 8 by 16 pixels, from the window's corner, no padding.
make_view :: proc(f: ^Fake) -> (v: term.View) {
	term.init(&v, fake_source(f), 80, 4)
	v.rect = {{0, 0}, {640, 64}}
	v.metrics.cell_w, v.metrics.cell_h = 8, 16
	return
}

// The middle of a cell, in window pixels.
at :: proc(cell: [2]int) -> [2]f32 { return {f32(cell.x) * 8 + 4, f32(cell.y) * 16 + 8} }

@(test)
a_clean_frame_builds_no_row :: proc(t: ^testing.T) {
	f := Fake{lines = {"hello", "world", "", ""}, dirty = .All}
	defer delete(f.out)
	v := make_view(&f)
	defer term.destroy(&v)
	testing.expect(t, term.refresh(&v), "a picture")
	testing.expect_value(t, v.rows_built, 4)
	testing.expect_value(t, term.row_text(&v, 0), "hello")
	testing.expect_value(t, term.row_text(&v, 1), "world")
	read := f.cells_read
	built := v.rows_built
	for _ in 0 ..< 3 { term.refresh(&v) }
	testing.expect_value(t, v.rows_built, built)   // (nothing written: no row built)
	testing.expect_value(t, f.cells_read, read)    // (and no cell read)
	f.lines[1], f.changed[1], f.dirty = "world!", true, .Rows
	term.refresh(&v)
	testing.expect_value(t, v.rows_built, built + 1)   // (the row written, alone)
	testing.expect_value(t, term.row_text(&v, 1), "world!")
	testing.expect_value(t, term.row_text(&v, 0), "hello")
	term.recolour(&v)
	term.refresh(&v)
	testing.expect_value(t, v.rows_built, built + 1 + 4)   // (the colours moved: every row, whatever the source says)
}

// A picture held (the program awaits a whole new screen) keeps the rows drawn last.
@(test)
a_held_picture_reads_nothing :: proc(t: ^testing.T) {
	f := Fake{lines = {"a", "", "", ""}, dirty = .All}
	v := make_view(&f)
	defer term.destroy(&v)
	term.refresh(&v)
	v.hold = true
	f.lines[0], f.changed[0], f.dirty = "b", true, .Rows
	term.refresh(&v)
	testing.expect_value(t, term.row_text(&v, 0), "a")
	v.hold = false
	term.refresh(&v)
	testing.expect_value(t, term.row_text(&v, 0), "b")
}

// Cells of one look are one run; a gap of empty cells is no text, and the next run starts at its own column.
@(test)
a_row_is_runs_of_one_look :: proc(t: ^testing.T) {
	f := Fake{lines = {"ab  cd", "", "", ""}, dirty = .All}
	v := make_view(&f)
	defer term.destroy(&v)
	term.refresh(&v)
	r := &v.lines[0]
	testing.expect_value(t, len(r.runs), 1)
	testing.expect_value(t, string(r.text[r.runs[0].from:r.runs[0].to]), "ab  cd")
	f.sel, f.anchor, f.sel_to, f.changed[0], f.dirty = true, {1, 0}, {2, 0}, true, .Rows
	term.refresh(&v)
	testing.expect_value(t, len(r.fills), 1)
	testing.expect(t, r.fills[0].selected && r.fills[0].from == 1 && r.fills[0].to == 3, "the selection, one rectangle")
}

// A drag selects from the cell it began on to the one it is over; Ctrl+Shift+C copies that text.
@(test)
a_selection_copies_its_text :: proc(t: ^testing.T) {
	f := Fake{lines = {"", "hello world", "", ""}}
	defer delete(f.out)
	v := make_view(&f)
	defer term.destroy(&v)
	ev := platform.Event{kind = .Mouse_Press, button = .Left, pos = at({6, 1})}
	testing.expect_value(t, term.event(&v, ev), term.Outcome.Ignored)   // (the box takes the focus)
	testing.expect_value(t, v.press, term.Press.Select)
	testing.expect(t, !term.has_selection(&v), "nothing yet: the pointer is on the cell it began on")
	term.event(&v, {kind = .Mouse_Move, pos = at({10, 1}), buttons = {.Left}})
	term.event(&v, {kind = .Mouse_Release, button = .Left, pos = at({10, 1})})
	testing.expect_value(t, v.press, term.Press.None)
	testing.expect(t, term.has_selection(&v), "selected")
	copy_key := platform.Event{kind = .Key_Press, key = .C, mods = {.Ctrl, .Shift}}
	testing.expect_value(t, term.event(&v, copy_key), term.Outcome.Copy)
	testing.expect_value(t, term.selection_text(&v), "world")
	// Ctrl+C alone copies where nothing is typed; else it is the program's (an interrupt), and typing drops the selection
	v.read_only = true
	testing.expect_value(t, term.event(&v, {kind = .Key_Press, key = .C, mods = {.Ctrl}}), term.Outcome.Copy)
	v.read_only = false
	testing.expect_value(t, term.event(&v, {kind = .Key_Press, key = .C, mods = {.Ctrl}}), term.Outcome.Taken)
	testing.expect_value(t, string(f.out[:]), "\x03")
	testing.expect(t, !term.has_selection(&v), "dropped")
}

// A press let go on the cell it began on selects nothing; typing drops a selection.
@(test)
a_click_selects_nothing_and_typing_drops_a_selection :: proc(t: ^testing.T) {
	f := Fake{lines = {"abc", "", "", ""}}
	defer delete(f.out)
	v := make_view(&f)
	defer term.destroy(&v)
	term.event(&v, {kind = .Mouse_Press, button = .Left, pos = at({1, 0})})
	term.event(&v, {kind = .Mouse_Move, pos = at({1, 0}) + {2, 0}, buttons = {.Left}})
	term.event(&v, {kind = .Mouse_Release, button = .Left, pos = at({1, 0})})
	testing.expect(t, !term.has_selection(&v), "a click")
	term.select_all(&v)
	testing.expect(t, term.has_selection(&v), "all of it")
	testing.expect_value(t, term.event(&v, {kind = .Text, text = 'x'}), term.Outcome.Taken)
	testing.expect_value(t, string(f.out[:]), "x")
	testing.expect(t, !term.has_selection(&v), "typing drops it")
	testing.expect(t, f.bottom, "and goes back to the last rows")
}

// The keys a terminal sends, as xterm says them (the encoder of a source that has none).
@(test)
a_key_encodes_to_its_bytes :: proc(t: ^testing.T) {
	f := Fake{}
	defer delete(f.out)
	v := make_view(&f)
	defer term.destroy(&v)
	expect :: proc(t: ^testing.T, v: ^term.View, k: platform.Key, mods: platform.Modifiers, want: string, loc := #caller_location) {
		testing.expect_value(t, term.encode_key(v, {k, mods, false}), want, loc = loc)
	}
	expect(t, &v, .Return, {}, "\r")
	expect(t, &v, .Backspace, {}, "\x7f")
	expect(t, &v, .Tab, {}, "\t")
	expect(t, &v, .Tab, {.Shift}, "\x1b[Z")
	expect(t, &v, .Escape, {}, "\x1b")
	expect(t, &v, .Up, {}, "\x1b[A")
	expect(t, &v, .Left, {}, "\x1b[D")
	expect(t, &v, .Right, {.Ctrl}, "\x1b[1;5C")
	expect(t, &v, .Home, {}, "\x1b[H")
	expect(t, &v, .End, {}, "\x1b[F")
	expect(t, &v, .Delete, {}, "\x1b[3~")
	expect(t, &v, .Page_Up, {}, "\x1b[5~")
	expect(t, &v, .F1, {}, "\x1bOP")
	expect(t, &v, .F5, {}, "\x1b[15~")
	expect(t, &v, .F12, {.Shift}, "\x1b[24;2~")
	expect(t, &v, .C, {.Ctrl}, "\x03")
	expect(t, &v, .Z, {.Ctrl}, "\x1a")
	expect(t, &v, .B, {.Alt}, "\x1bb")
	expect(t, &v, .A, {}, "")              // (its character comes by the Text event)
	expect(t, &v, .A, {.Shift}, "")
	expect(t, &v, .N2, {.Ctrl, .Alt}, "")  // (AltGr: a character too)
	f.modes = {.App_Cursor}
	expect(t, &v, .Up, {}, "\x1bOA")
	// a key pressed reaches the program, the source's encoder when it has one
	testing.expect_value(t, term.event(&v, {kind = .Key_Press, key = .Up}), term.Outcome.Taken)
	testing.expect_value(t, string(f.out[:]), "\x1bOA")
	f.encoder = true
	term.event(&v, {kind = .Key_Press, key = .Down})
	testing.expect_value(t, string(f.out[:]), "\x1bOA<k>")
	// a key alone (Shift) is taken and sends nothing; a read-only grid leaves the keys to the program
	testing.expect_value(t, term.event(&v, {kind = .Key_Press, key = .Shift, mods = {.Shift}}), term.Outcome.Taken)
	v.read_only = true
	testing.expect_value(t, term.event(&v, {kind = .Key_Press, key = .Escape}), term.Outcome.Ignored)
	testing.expect_value(t, term.event(&v, {kind = .Text, text = 'x'}), term.Outcome.Ignored)
	testing.expect_value(t, string(f.out[:]), "\x1bOA<k>")
}

// Shift+Insert is the terminals' other paste (Ctrl+Insert their other copy): the program's clipboard, not the Insert key
// ("\x1b[2~"). A paste is in brackets when the program asks, else its line ends are returns.
@(test)
shift_insert_pastes :: proc(t: ^testing.T) {
	f := Fake{}
	defer delete(f.out)
	v := make_view(&f)
	defer term.destroy(&v)
	testing.expect_value(t, term.event(&v, {kind = .Key_Press, key = .Insert, mods = {.Shift}}), term.Outcome.Paste)
	testing.expect_value(t, term.event(&v, {kind = .Key_Press, key = .V, mods = {.Ctrl, .Shift}}), term.Outcome.Paste)
	testing.expect_value(t, term.event(&v, {kind = .Key_Press, key = .Insert, mods = {.Ctrl}}), term.Outcome.Taken)   // (nothing selected)
	testing.expect_value(t, string(f.out[:]), "")
	term.paste(&v, "a\r\nb\nc")
	testing.expect_value(t, string(f.out[:]), "a\rb\rc")
	clear(&f.out)
	f.modes = {.Bracketed_Paste}
	term.paste(&v, "a\nb")
	testing.expect_value(t, string(f.out[:]), "\x1b[200~a\nb\x1b[201~")
	clear(&f.out)
	v.read_only = true
	testing.expect_value(t, term.event(&v, {kind = .Key_Press, key = .Insert, mods = {.Shift}}), term.Outcome.Ignored)
	term.paste(&v, "x")
	testing.expect_value(t, string(f.out[:]), "")
}

// A program that has the mouse is told of a press, and of its release wherever the pointer is let go, or when the press is
// taken away (press_end). With Shift, the pointer selects; a right click is the program's menu.
@(test)
a_program_hears_the_release_of_its_press :: proc(t: ^testing.T) {
	f := Fake{lines = {"abc", "", "", ""}, modes = {.Mouse_Tracking}}
	defer delete(f.out)
	src := fake_source(&f)
	src.encode_mouse = proc(data: rawptr, m: term.Mouse_Input, buf: []u8) -> int {
		s := m.action == .Press ? "P" : m.action == .Release ? "R" : "M"
		return copy(buf, s)
	}
	v: term.View
	term.init(&v, src, 80, 4)
	defer term.destroy(&v)
	v.rect = {{0, 0}, {640, 64}}
	v.metrics.cell_w, v.metrics.cell_h = 8, 16
	testing.expect(t, term.tracks_mouse(&v), "tracked")
	term.event(&v, {kind = .Mouse_Press, button = .Left, pos = at({1, 1})})
	testing.expect_value(t, v.press, term.Press.Program)
	term.event(&v, {kind = .Mouse_Move, pos = {5000, 10}, buttons = {.Left}})
	term.event(&v, {kind = .Mouse_Release, button = .Left, pos = {5000, 10}})
	testing.expect_value(t, string(f.out[:]), "PMR")
	testing.expect_value(t, v.press, term.Press.None)
	clear(&f.out)
	term.event(&v, {kind = .Mouse_Press, button = .Left, pos = at({1, 1})})
	term.press_end(&v)
	testing.expect_value(t, string(f.out[:]), "PR")
	clear(&f.out)
	term.event(&v, {kind = .Mouse_Press, button = .Left, mods = {.Shift}, pos = at({1, 1})})
	testing.expect_value(t, v.press, term.Press.Select)
	term.press_end(&v)
	testing.expect_value(t, string(f.out[:]), "")
	testing.expect_value(t, term.event(&v, {kind = .Mouse_Press, button = .Right, pos = at({1, 1})}), term.Outcome.Ignored)   // (the program's right button)
	testing.expect_value(t, term.event(&v, {kind = .Mouse_Press, button = .Right, mods = {.Shift}, pos = at({1, 1})}), term.Outcome.Menu)
}

// Ctrl+= and Ctrl+- move the zoom by a step, within its bounds; Ctrl+0 puts it back. The wheel scrolls the rows shown.
@(test)
the_zoom_keys_and_the_wheel :: proc(t: ^testing.T) {
	f := Fake{}
	defer delete(f.out)
	v := make_view(&f)
	defer term.destroy(&v)
	testing.expect_value(t, term.event(&v, {kind = .Key_Press, key = .Equal, mods = {.Ctrl}}), term.Outcome.Zoomed)
	testing.expect(t, v.zoom > 1.05, "bigger")
	for _ in 0 ..< 50 { term.event(&v, {kind = .Key_Press, key = .Equal, mods = {.Ctrl}}) }
	testing.expect_value(t, v.zoom, f32(term.ZOOM_MAX))
	term.event(&v, {kind = .Key_Press, key = .N0, mods = {.Ctrl}})
	testing.expect_value(t, v.zoom, f32(1))
	testing.expect_value(t, string(f.out[:]), "")   // (nothing reached the program)
	testing.expect_value(t, term.event(&v, {kind = .Scroll, pos = at({1, 1}), delta = {0, -1}}), term.Outcome.Taken)
	testing.expect(t, f.scrolled < 0, "up the scrollback")
	f.scrolled = 0
	term.event(&v, {kind = .Key_Press, key = .Page_Up, mods = {.Shift}})
	testing.expect_value(t, f.scrolled, -v.rows)
}
