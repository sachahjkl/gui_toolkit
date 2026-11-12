// A terminal's grid as a widget: the cells of a screen drawn from rows kept between frames, a selection made with the
// pointer, keys and the mouse turned into bytes, the scrollback under the toolkit's scroll bar, a zoom, a cursor.
//
// The widget emulates nothing. A Source gives it the screen (rows of cells, which rows changed, the cursor, the
// scrollback) and takes what it sends back (bytes, a new size, a scroll, a selection): an emulator such as libghostty-vt
// stands behind it, or a program's own model of a screen. Docs: docs/term.md.
package term

import "base:runtime"
import "../draw"
import tk_font "../font"
import "../platform"
import "../ui"

Color :: draw.Color

Cell_Flag :: enum u8 {
	Bold,
	Faint,       // its text drawn at Style.faint of its colour
	Inverse,     // its text and its background change places
	Invisible,   // its text is not drawn
	Underline,
	Strike,
	Selected,    // in the selection: drawn in Style.selection
}
Cell_Flags :: bit_set[Cell_Flag; u8]

// One cell of a row, as the source reads it. Its text is only read during the call (sink_cell).
Cell :: struct {
	text:   string,   // its grapheme, UTF-8 ("": nothing in it)
	fg:     Color,
	bg:     Color,
	has_bg: bool,     // false: the grid's background (Picture.background)
	flags:  Cell_Flags,
}

// Which rows of the picture changed since the source's rows were last read.
Dirty :: enum u8 {
	None,   // none: the rows are not read
	Rows,   // some: each row says (sink_row)
	All,    // every row is read again
}

Cursor_Shape :: enum u8 { Block, Bar, Underline }

Cursor :: struct {
	shown: bool,      // visible, and in the rows shown
	x, y:  int,       // its cell, in the rows shown
	shape: Cursor_Shape,
	color: Color,
}

// What the source says of its screen when the widget draws it (Source.picture).
Picture :: struct {
	dirty:      Dirty,
	foreground: Color,   // the text of a cell without its own background: an inverse cell takes it as background
	background: Color,
	cursor:     Cursor,
}

// The scrollback in rows: all of them, the first one shown, how many are shown.
Scrollbar :: struct { total, offset, len: int }

// What the program behind the screen asked of its terminal, as far as the widget is concerned.
Mode :: enum u8 {
	Bracketed_Paste,   // a paste comes between ESC [200~ and ESC [201~
	App_Cursor,        // the arrows say ESC O and not ESC [ (DECCKM): read by the toolkit's own encoder (xterm_key)
	Mouse_Tracking,    // the program wants the mouse (Source.encode_mouse says it): the pointer selects only with Shift
}
Modes :: bit_set[Mode; u8]

// What the widget asks of the source's selection. The source keeps it: its ends follow their text as rows come and as
// the grid is wrapped again, which only the emulator can know.
Select_Op :: enum u8 {
	Begin,    // a drag starts on `cell` (of the rows shown): the selection there is dropped, that cell is followed
	Extend,   // the selection runs from where the drag began to `cell`
	End,      // the drag is over: what was followed for it is let go, the selection stays
	All,      // all of the screen and its scrollback
	Drop,     // no selection
	Has,      // whether there is one (the answer)
}

Key_Input :: struct {
	key:    platform.Key,
	mods:   platform.Modifiers,
	repeat: bool,
}

Mouse_Action :: enum u8 { Press, Release, Motion }
Mouse_Button :: enum u8 { None, Left, Right, Middle, Wheel_Up, Wheel_Down }

// A mouse event for a program that tracks the mouse, with what an encoder needs of the grid.
Mouse_Input :: struct {
	action: Mouse_Action,
	button: Mouse_Button,
	mods:   platform.Modifiers,
	held:   bool,      // a button is down: a motion is a drag
	pos:    [2]f32,    // in the grid's box, from its top left, inside it
	size:   [2]f32,    // the box
	cell:   [2]f32,    // a cell
	pad:    f32,       // between the box and the cells, on each side
}

// The screen behind the widget. `data` goes to each procedure. The ones marked optional may be nil.
Source :: struct {
	data: rawptr,
	// The screen as it is now, for the frame being drawn. ok = false: nothing is drawn.
	picture: proc(data: rawptr) -> (p: Picture, ok: bool),
	// The rows of that picture, top to bottom: each by sink_row, then, if it says so, its cells by sink_cell. The source
	// then takes its dirty flags as read. Not called when the picture says Dirty.None and nothing else asks for them.
	rows: proc(data: rawptr, sink: ^Sink),
	scrollbar: proc(data: rawptr) -> (bar: Scrollbar, ok: bool),
	// Moves the rows shown by `delta` (up: below 0); `bottom`: to the last rows.
	scroll: proc(data: rawptr, delta: int, bottom: bool),
	// The grid laid out (each build): its size in cells. `changed`: another than the last one.
	resize: proc(data: rawptr, cols, rows: int, cell: [2]int, changed: bool),
	// Bytes for the program behind the screen (typed, pasted, the mouse). Optional: nil reads only.
	write: proc(data: rawptr, bytes: string),
	modes: proc(data: rawptr) -> Modes,
	// Optional: a key's bytes in `buf` (nil: xterm_key's). Returns how many.
	encode_key: proc(data: rawptr, k: Key_Input, buf: []u8) -> int,
	// Optional: a mouse event's bytes in `buf`. Returns how many. nil: the mouse is never reported.
	encode_mouse: proc(data: rawptr, m: Mouse_Input, buf: []u8) -> int,
	// Optional: nil, nothing is selected.
	select: proc(data: rawptr, op: Select_Op, cell: [2]int) -> bool,
	selection_text: proc(data: rawptr, allocator: runtime.Allocator) -> string,
}

// How the grid looks, given at each build.
Style :: struct {
	fonts:        ^tk_font.State,
	font:         tk_font.Font_Id,
	font_bold:    tk_font.Font_Id,
	font_size:    f32,   // at zoom 1
	pad:          f32,   // between the box and the cells
	background:   Color,
	selection:    Color,
	faint:        f32,   // the alpha of a faint cell's text, times its colour's
	cursor_alpha: f32,   // the alpha of a block cursor
}

// A grid's cells as last laid out: its face's size (the style's times the zoom) and what follows from it.
Metrics :: struct {
	font_size, cell_w, cell_h, ascent: f32,
	spacing, spacing_bold: f32,   // what a letter of the face (its bold) is short of a cell: each letter is drawn on its cell
}

// What the pointer holds on the grid. Its release comes wherever the pointer is: press_end.
Press :: enum u8 { None, Select, Program }

// A row as it is drawn, in columns and not in pixels: a new face size or zoom moves it without building it again.
Row :: struct {
	text:  [dynamic]u8,     // the text of all its runs, one after the other
	runs:  [dynamic]Run,
	fills: [dynamic]Fill,
	marks: [dynamic]Mark,
}

// Cells side by side of the same look go together: a row is a few runs of text, not one draw per cell.
Run  :: struct { col: u16, from, to: u32, color: Color, bold: bool }   // (its text: the row's text[from:to])
Fill :: struct { from, to: u16, color: Color, selected: bool }        // columns from..<to
Mark :: struct { from, to: u16, color: Color, strike: bool }          // an underline, or (strike) a line through

ZOOM_MIN     :: 0.5
ZOOM_MAX     :: 3
ZOOM_STEP    :: 1.1
// A zoom at rest after this long without a step: the grid then takes its new size. Each new number of columns wraps
// every row of the scrollback again, thousands of them: not at every notch of the wheel.
ZOOM_REST_MS :: 150.0
KEY_BYTES    :: 128   // the most a key or a mouse event is encoded in

View :: struct {
	source:    Source,
	read_only: bool,     // nothing is typed: the keys that are not for reading are the program's, the pointer selects
	zoom:      f32,      // times Style.font_size
	zoom_ms:   f64,      // when it last changed (0: never)
	hold:      bool,     // the program awaits a whole new picture (a size just given): the last one drawn stays until then
	cols, rows: int,     // the grid, as the source was last told
	fitted:    bool,     // laid out once: until then its size says nothing
	// As last built
	box:       ui.Key,
	rect:      draw.Rect,
	metrics:   Metrics,
	style:     Style,
	focused:   bool,     // its box has the keyboard: a solid cursor
	bar_at:    f32,      // where scroll_sync put the box's scroll: another place is the scroll bar, moved
	// The picture: rebuilt only for rows the source says changed (refresh)
	picture:   Picture,
	drawn:     bool,     // a picture was taken once
	lines:     [dynamic]Row,
	stale:     bool,     // the look of every row moved (recolour): all are built again
	rows_built: int,     // rows built since init: what a test counts
	// The pointer
	press:        Press,
	press_button: platform.Mouse_Button,
	press_pos:    [2]f32,
	press_cell:   [2]int,   // where a selection's drag began: it selects once the pointer leaves that cell
}

// `cols` and `rows`: the size the source starts with, until the grid is laid out.
init :: proc(v: ^View, source: Source, cols, rows: int, allocator := context.allocator) {
	v^ = {source = source, zoom = 1, cols = cols, rows = rows}
	v.lines = make([dynamic]Row, allocator)   // (its rows take its allocator: they are built in a frame, never in its temp one)
}

destroy :: proc(v: ^View) {
	for &r in v.lines { row_delete(&r) }
	delete(v.lines)
	v.lines = nil
}

// The colours the source gives moved (a new theme): every row is built again at the next draw.
recolour :: proc(v: ^View) { v.stale = true }

// Takes the source's picture and builds again the rows it says changed: none when nothing changed, and then the source
// reads none of its cells. (The draw does it; a test, out of a frame.) False: no picture.
refresh :: proc(v: ^View) -> bool {
	if v.hold && v.drawn { return true }
	if v.source.picture == nil { return false }
	p, ok := v.source.picture(v.source.data)
	if !ok { return false }
	v.picture, v.drawn = p, true
	every := v.stale || p.dirty == .All
	if every || p.dirty != .None {
		sink := Sink{view = v, every = every}
		v.source.rows(v.source.data, &sink)
		sink_end(&sink)
	}
	v.stale = false
	return true
}

////////////////////////////////
// The rows, as the source gives them

// Where Source.rows puts what it reads.
Sink :: struct {
	view:  ^View,
	every: bool,
	y:     int,      // the next row
	row:   ^Row,     // the row being built (nil: kept)
	x:     u16,      // its next cell
	run_from: int,
	run_col:  u16,
	run_color: Color,
	run_bold:  bool,
}

// The next row. `changed`: its own dirty flag. True: it is built again, and its cells follow (sink_cell); false: it is
// kept as it was, and the source gives none of them.
sink_row :: proc(s: ^Sink, changed: bool) -> bool {
	sink_close(s)
	v := s.view
	y := s.y
	s.y += 1
	fresh := y == len(v.lines)   // (never built: whatever its flag says)
	if fresh {
		a := v.lines.allocator
		append(&v.lines, Row{make([dynamic]u8, a), make([dynamic]Run, a), make([dynamic]Fill, a), make([dynamic]Mark, a)})
	}
	if !s.every && !fresh && !changed { return false }
	r := &v.lines[y]
	clear(&r.text); clear(&r.runs); clear(&r.fills); clear(&r.marks)
	v.rows_built += 1
	s.row, s.x, s.run_from, s.run_col, s.run_color, s.run_bold = r, 0, 0, 0, {}, false
	return true
}

// The next cell of the row. What is not ASCII stands alone, at the column it belongs to, whatever width the fallback
// face gives it.
sink_cell :: proc(s: ^Sink, c: Cell) {
	r := s.row
	if r == nil { return }
	x := s.x
	s.x += 1
	p := &s.view.picture
	fg, bg, has_bg := c.fg, c.bg, c.has_bg
	if .Inverse in c.flags { fg, bg, has_bg = has_bg ? bg : p.background, fg, true }
	if .Selected in c.flags {
		row_fill(r, x, {}, true)
	} else if has_bg {
		row_fill(r, x, bg, false)
	}
	color := fg
	if .Faint in c.flags { color.a *= s.view.style.faint if s.view.style.faint > 0 else 1 }
	if .Underline in c.flags { row_mark(r, x, color, false) }
	if .Strike in c.flags { row_mark(r, x, color, true) }
	text := .Invisible in c.flags ? "" : c.text
	bold := .Bold in c.flags
	started := len(r.text) > s.run_from
	if text == "" {
		if started { append(&r.text, ' ') }
		return
	}
	ascii := len(text) == 1 && text[0] < 0x80
	if !ascii || color != s.run_color || bold != s.run_bold || !started {
		run_close(r, s.run_from, s.run_col, s.run_color, s.run_bold)
		s.run_from, s.run_col, s.run_color, s.run_bold = len(r.text), x, color, bold
	}
	append(&r.text, text)
	if !ascii {
		run_close(r, s.run_from, s.run_col, s.run_color, s.run_bold)
		s.run_from = len(r.text)
	}
}

@(private)
sink_close :: proc(s: ^Sink) {
	if s.row != nil { run_close(s.row, s.run_from, s.run_col, s.run_color, s.run_bold) }
	s.row = nil
}

// (fewer rows: the view is shorter, and only a full read says so)
@(private)
sink_end :: proc(s: ^Sink) {
	sink_close(s)
	v := s.view
	for len(v.lines) > s.y { r := pop(&v.lines); row_delete(&r) }
}

@(private)
run_close :: proc(r: ^Row, from: int, col: u16, color: Color, bold: bool) {
	if from > len(r.text) { return }
	end := len(r.text)
	for end > from && r.text[end - 1] == ' ' { end -= 1 }   // (the spaces after a run's last letter draw nothing)
	resize(&r.text, end)
	if end > from { append(&r.runs, Run{col, u32(from), u32(end), color, bold}) }
}

// (cells side by side of one colour, or of the selection, are one rectangle)
@(private)
row_fill :: proc(r: ^Row, x: u16, color: Color, selected: bool) {
	if n := len(r.fills); n > 0 {
		last := &r.fills[n - 1]
		if last.to == x && last.selected == selected && (selected || last.color == color) { last.to = x + 1; return }
	}
	append(&r.fills, Fill{x, x + 1, color, selected})
}

@(private)
row_mark :: proc(r: ^Row, x: u16, color: Color, strike: bool) {
	// (a cell underlined and struck adds two: the one before the last may be of its kind)
	for i := len(r.marks) - 1; i >= max(len(r.marks) - 2, 0); i -= 1 {
		m := &r.marks[i]
		if m.strike == strike && m.to == x && m.color == color { m.to = x + 1; return }
	}
	append(&r.marks, Mark{x, x + 1, color, strike})
}

@(private)
row_delete :: proc(r: ^Row) {
	delete(r.text); delete(r.runs); delete(r.fills); delete(r.marks)
}

// The text of a row's runs as drawn, its gaps as spaces: what a test reads.
row_text :: proc(v: ^View, y: int, allocator := context.temp_allocator) -> string {
	if y < 0 || y >= len(v.lines) { return "" }
	r := &v.lines[y]
	out := make([dynamic]u8, allocator)
	col := 0
	for run in r.runs {
		for col < int(run.col) { append(&out, ' '); col += 1 }
		s := string(r.text[run.from:run.to])
		append(&out, s)
		for _ in s { col += 1 }
	}
	return string(out[:])
}
