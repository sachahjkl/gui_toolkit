// Package marks: marks drawn on a picture (boxes, ellipses, arrows, lines, ink, a highlighter, text, pixelated and
// blurred boxes, a crop), as a model with no window. ui.Mark_Editor is its widget; docs/mark-editor.md says how a program
// uses both, src/md/features/mark-editor.md why they are made this way.
//
//   the document   the picture's size, the shapes (points in the picture's pixels), the selection, the crop, the undo
//                  and redo steps (a gt:undo stack, each step a copy of the shapes and the crop)
//   the view       where the picture is in the canvas and how large: fitted, or zoomed and panned
//   the tool       what a press on the canvas does; each tool keeps its own style (colour, width...)
//   the mode       the interaction: one state machine, one transition procedure (step)
//
//   Idle --press--> Drawing | Moving | Resizing | Panning | Cropping | Selecting | Typing
//   Idle --Shift+press on a shape, Select--> Idle (the shape added to the selection, or taken from it)
//   Drawing, Moving, Resizing, Panning, Cropping, Selecting --release--> Idle
//   Typing --text end, press--> Idle
//
// A gesture is one undo step: the document is copied when it starts and the copy goes on the undo stack when it ends,
// unless the gesture changed nothing (a click on a shape selects it and leaves no step).
//
// The geometry of a shape is its figures (figures.odin): polylines to stroke and polygons to fill, which the screen and
// the flattening (flatten.odin) both draw. Every procedure allocates with context.allocator unless it takes one: call
// the model with the same allocator from its init to its destroy.
package tk_marks

import ink "../ink"
import tk_undo "../undo"

Vec :: [2]f32

// A rectangle by its two corners (min <= max once normalized).
Box :: struct { min, max: Vec }

Tool :: enum u8 { Select, Rectangle, Ellipse, Arrow, Line, Pen, Highlighter, Text, Pixelate, Blur, Crop }
Tools :: bit_set[Tool; u16]

TOOLS_ALL :: Tools{.Select, .Rectangle, .Ellipse, .Arrow, .Line, .Pen, .Highlighter, .Text, .Pixelate, .Blur, .Crop}

Kind :: enum u8 {
	Rectangle,
	Ellipse,
	Arrow,
	Line,
	Pen,           // ink: its samples, through gt:ink
	Highlighter,   // a translucent box of its colour
	Text,
	Pixelate,      // hides what is under its box behind a mosaic of the picture
	Blur,          // hides what is under its box behind a blurred copy of the picture
}

// What a bar offers to change for a kind.
Prop :: enum u8 { Color, Fill, Width, Dash, Radius, Heads, Text_Size, Bold, Text_Look, Pixel_Size, Blur_Radius }
Props :: bit_set[Prop; u16]

kind_props :: proc(k: Kind) -> Props {
	switch k {
	case .Rectangle:   return {.Color, .Fill, .Width, .Dash, .Radius}
	case .Ellipse:     return {.Color, .Fill, .Width, .Dash}
	case .Arrow:       return {.Color, .Width, .Dash, .Heads}
	case .Line:        return {.Color, .Width, .Dash}
	case .Pen:         return {.Color, .Width}
	case .Highlighter: return {.Color}
	case .Text:        return {.Color, .Fill, .Text_Size, .Bold, .Text_Look}
	case .Pixelate:    return {.Pixel_Size}
	case .Blur:        return {.Blur_Radius}
	}
	return {}
}

// How a text shows: its letters alone, the letters with an outline, or the letters on a box.
Text_Look :: enum u8 { Plain, Outline, Background }

// How a stroke is drawn: whole, in dashes, in dots.
Dash :: enum u8 { Solid, Dashed, Dotted }

// Where an arrow has its heads.
Heads :: enum u8 { None, End, Start, Both }

// The look of a shape. Lengths are logical pixels: on a picture taken at 200 %, a 4 px stroke is 8 of its pixels.
Style :: struct {
	color:       u32,   // 0xRRGGBB, sRGB
	// 0xAARRGGBB, sRGB: a box's or an ellipse's inside, a text's outline or box. Alpha 0: none (a text's outline or box
	// then takes black or white, whichever stands out from its letters)
	fill_color:  u32,
	width:       f32,
	text_size:   f32,
	text_look:   Text_Look,
	bold:        bool,
	dash:        Dash,
	radius:      f32,   // Rectangle: its corners
	heads:       Heads,
	pixel_size:  f32,   // Pixelate: a cell's side
	blur_radius: f32,   // Blur
}

// The swatches offered when the program gives none: red first, which reads on any screenshot.
COLORS :: [8]u32{0xE53935, 0xFB8C00, 0xFDD835, 0x43A047, 0x1E88E5, 0x8E24AA, 0x000000, 0xFFFFFF}
OPAQUE :: u32(0xFF000000)   // the alpha of a fill colour that is there
WIDTH_MIN :: 1              // a stroke's width, logical pixels: a slider's ends
WIDTH_MAX :: 40
RADIUS_MAX :: 60            // a rectangle's corners, logical pixels
TEXT_SIZES :: [4]f32{16, 24, 32, 48}
TEXT_SIZE_MIN :: 6          // what the scale handle can make of a text, logical pixels
TEXT_SIZE_MAX :: 400
// The choices of Blur's radius and Pixelate's cell: a few, each a blurred copy or a mosaic made once per picture
BLUR_RADII :: [4]f32{4, 8, 16, 32}
PIXEL_SIZES :: [4]f32{6, 12, 24, 48}

STYLE_DEFAULT :: Style{color = 0xE53935, width = 4, text_size = 24, blur_radius = 8, pixel_size = 12, heads = .End}
HIGHLIGHT_COLOR :: 0xFDD835   // (the yellow swatch)
HIGHLIGHT_ALPHA :: 0.4

// The pen's ink when the program gives none: a felt marker, a little thinner where the hand is fast, round ends. Its
// width is the style's.
PEN_DEFAULT :: ink.Pen{nib = .Round, width = 4, thinning = 0.3, smoothing = 0.5, min_width = 0.5}

HIT_PX       :: 6      // how far from a stroke a press still takes it, window pixels
HANDLE_PX    :: 7      // how far from a handle's centre a press takes it, window pixels
SMALL_PX     :: 4      // a shape drawn smaller than this on the screen was a click: it is dropped
ZOOM_MIN     :: 0.05
ZOOM_MAX     :: 16
ZOOM_STEP    :: 1.25   // one notch of the wheel, one Ctrl+= or Ctrl+-
WHEEL_PAN_PX :: 60     // window pixels a notch of the wheel pans
FIT_MARGIN   :: 0.96   // the share of the canvas a fitted picture takes: its edge stays visible
NUDGE_FAST   :: 10     // picture pixels a step with Shift
DUPLICATE_PX :: 16     // logical pixels a copy lands from its original
TEXT_OUTLINE :: 0.16   // a text's outline, in its text size (half of it shows: the letters cover the rest)
TEXT_BOX_PAD :: 0.25   // the room around a text on a box, in its text size
TEXT_BOX_ROUND :: 0.2  // a text's box's corners, in its text size
SCALE_MIN    :: 0.02   // the least a drawing is scaled to, of its size

Shape :: struct {
	kind:      Kind,
	// a box's two corners, or a line's two ends (a: where it starts). Text: its top left, then its bottom right as
	// measured. Pen: its box, made from its samples
	a, b:      Vec,
	samples:   [dynamic]ink.Sample,   // Pen (owned): picture pixels
	text:      string,                // Text (owned): its lines separated by "\n"
	style:     Style,
	picked:    bool,                  // in the selection (not compared, not undone: an undo selects nothing)
	// Pen: its ink (owned), made from the samples and the width when either changes (pen_trace), so a frame draws it
	// with no work
	polygon:   [][2]f32,
	triangles: [][3][2]f32,
}

// The shapes and the crop as they were (owned).
Snapshot :: struct {
	shapes:   []Shape,
	crop:     Box,
	has_crop: bool,
}

// The size of one line of text in the picture's pixels, at size picture pixels: the program's font measures it.
Measure :: proc(user: rawptr, text: string, size: f32, bold: bool) -> Vec

Doc :: struct {
	size:         Vec,   // the picture, pixels
	scale:        f32,   // the picture's pixels per logical pixel
	shapes:       [dynamic]Shape,   // drawn in order: the last one on top
	selected:     int,   // the shape picked whose style the bar shows; -1: none picked
	picked_count: int,   // how many shapes are picked, and of which kinds (made again when the picks change)
	picked_kinds: bit_set[Kind; u16],
	crop:         Box,   // what the picture keeps when it is done (has_crop), in its pixels
	has_crop:     bool,
	history:      tk_undo.Stack(Snapshot),
	pending:      Snapshot,   // the document when the gesture began (has_pending)
	has_pending:  bool,
	pen:          ink.Pen,    // the pen's ink; its width is each shape's style's
	// counts the kept changes (an undo step pushed, a slider's run that merged into one, an undo, a redo): a program
	// that keeps the picture's state saves it again when this moves
	edits:        u64,
	measure:      Measure,
	user:         rawptr,     // the measure's
}

// Where the picture is shown. Window pixels: the canvas box, the offset from its top left, the zoom.
View :: struct {
	canvas: Box,
	zoom:   f32,   // window pixels per picture pixel
	offset: Vec,   // the picture's top left, from the canvas's top left
	fit:    bool,  // the picture is fitted to the canvas at each place (until a zoom or a pan)
}

// Scale: one handle at the bottom right of a text or a drawing, that makes all of it larger or smaller.
Handle :: enum u8 { None, Top_Left, Top, Top_Right, Right, Bottom_Right, Bottom, Bottom_Left, Left, Start, End, Scale }
Handles :: bit_set[Handle; u16]

BOX_HANDLES :: Handles{.Top_Left, .Top, .Top_Right, .Right, .Bottom_Right, .Bottom, .Bottom_Left, .Left}
LINE_HANDLES :: Handles{.Start, .End}

// The interaction's states.
Idle      :: struct {}
Drawing   :: struct { index: int }                     // a new shape follows the pointer
Moving    :: struct { last: Vec }                      // the shapes picked; picture pixels
// the press and the shape as it was (for Scale, the whole shape as it was: the document kept when the gesture began).
// index -1: the crop's box
Resizing  :: struct { index: int, handle: Handle, start, a, b: Vec }
Panning   :: struct { last: Vec }                      // window pixels
Cropping  :: struct { start: Vec }
Selecting :: struct { start, at: Vec, add: bool }      // a box that picks the shapes it touches; add: Shift
Typing    :: struct { index: int, before: string, fresh: bool }   // before: the text as it was (owned); fresh: a new text

Mode :: union #no_nil { Idle, Drawing, Moving, Resizing, Panning, Cropping, Selecting, Typing }

Button :: enum u8 { Left, Middle, Right }

// The events, in window pixels. pan: Space is held (a left drag pans then). time: milliseconds, any origin (the pen's
// speed); pressure and tilt: the pointer's, as gt:ink's Sample takes them.
Press    :: struct { at: Vec, button: Button, shift, pan, double: bool, time: f64, pressure: f32, tilt: [2]f32 }
Move     :: struct { at: Vec, shift: bool, time: f64, pressure: f32, tilt: [2]f32 }
Release  :: struct { at: Vec, button: Button, shift: bool }
Wheel    :: struct { at: Vec, delta: Vec, zoom, sideways: bool }   // delta: notches, +y away from the top
Typed    :: struct { text: string }   // the text field's text now (not kept)
Type_End :: struct { keep: bool }     // Enter or a press elsewhere keep the text; Escape gives back the one before

Event :: union { Press, Move, Release, Wheel, Typed, Type_End }

// A style's field that a slider or the colour picker runs through: the values of one run are one undo step.
Run_Field :: enum u8 { None, Color, Fill_Color, Width, Radius }

Model :: struct {
	doc:     Doc,
	view:    View,
	mode:    Mode,
	tool:    Tool,
	styles:  [Tool]Style,   // each tool's own, for its next shape
	typing:  u32,           // counts the starts of Typing: the widget puts the shape's text in its field at a new one
	// counts every change the screen shows (a gesture's move too): the widget makes its figures again only when it moved
	changes: u64,
	// the last undo step was a run of run_field on this shape (its index + 1; 0: none), and the stack was this long
	// after it: the values a slider runs through are one step, not one a frame
	run_field: Run_Field,
	run_shape, run_undo: int,
}

// What a program sets. A zero field takes the toolkit's choice.
Options :: struct {
	scale:   f32,                // the picture's pixels per logical pixel (0: 1)
	tool:    Maybe(Tool),        // the tool chosen first (nil: Arrow)
	styles:  [Tool]Style,        // each tool's first style (a zero style: the toolkit's)
	pen:     Maybe(ink.Pen),     // the pen's ink (nil: PEN_DEFAULT); its width is the style's
	measure: Measure,            // nil: a text is as wide as its letters count, as tall as its size
	user:    rawptr,             // the measure's
}

// Each tool's style when the program gives none.
style_default :: proc(t: Tool) -> Style {
	s := STYLE_DEFAULT
	#partial switch t {
	case .Highlighter: s.color = HIGHLIGHT_COLOR
	}
	return s
}

// A model of a picture of size pixels, with nothing drawn on it yet.
init :: proc(m: ^Model, size: [2]int, o := Options{}) {
	m^ = {}
	m.doc = {size = {f32(size.x), f32(size.y)}, scale = o.scale > 0 ? o.scale : 1, selected = -1, measure = o.measure, user = o.user}
	m.doc.pen = o.pen.? or_else PEN_DEFAULT
	m.view = {zoom = 1, fit = true}
	m.mode = Idle{}
	m.tool = o.tool.? or_else .Arrow
	for t in Tool { m.styles[t] = o.styles[t] != {} ? o.styles[t] : style_default(t) }
}

destroy :: proc(m: ^Model) {
	if t, typing := m.mode.(Typing); typing { delete(t.before) }
	m.mode = Idle{}
	shapes_free(m.doc.shapes[:])
	delete(m.doc.shapes)
	tk_undo.destroy(&m.doc.history, snapshot_free)
	if m.doc.has_pending { snapshot_free(&m.doc.pending) }
	m^ = {}
}
