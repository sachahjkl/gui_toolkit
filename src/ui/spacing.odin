package ui

import "core:fmt"
import "core:math"

// The spacing scale (src/md/features/spacing.md): every gap and inset of a page is one of these steps, in font sizes,
// through its role. Scattered values (0.3, 0.45, 0.9 em) made every place look a little off from the next one.
SPACE_1 :: f32(0.25)
SPACE_2 :: f32(0.5)
SPACE_3 :: f32(0.75)
SPACE_4 :: f32(1)
SPACE_6 :: f32(1.5)

// The roles of a page, each with one step, the same in every program.
PAGE_MARGIN :: SPACE_6   // the page's left, right and bottom edges
CARD_PAD    :: SPACE_4   // a card's inset, the same on its four sides
ROW_PAD     :: SPACE_3   // a list row's inset above and below (its sides: CARD_PAD)
GROUP_GAP   :: SPACE_6   // between two groups of a page
ITEM_GAP    :: SPACE_4   // between two items of one group
LINE_GAP    :: SPACE_2   // between two lines of a group, and between a group's head and its card
ICON_GAP    :: SPACE_2   // between an icon (a mark, a box) and its words
CONTROL_GAP :: SPACE_2   // between two buttons, and between words and their button
TOOL_GAP    :: SPACE_1   // between two icon buttons of a bar
INNER_PAD   :: SPACE_3   // inside a well: its content's inset from its edge

// A gap of `step` font sizes along the parent's axis, on whole pixels.
space :: proc(step: f32) {
	spacer(px(math.round(font_size() * step)))
	if b := parent_box().last; b != nil { b.gap_step = step }   // (the wireframe tints it by its step)
}

// `if list_card("###id") { if card_row("###a") { ... }; if card_row("###b") { ... } }`: one card whose rows are split by
// hairlines. Its first and last rows sit CARD_PAD from its edges, as the content of any card. Tags used: "card".
// `o`: its own look, as a card's.
@(require_results, deferred_none = list_card_end)
list_card :: proc(id: string, o := Card_Options{}) -> bool {
	card_open(id, CARD_PAD - ROW_PAD, o = o)
	return true
}

@(private)
list_card_end :: proc() {
	card_close(CARD_PAD - ROW_PAD)
}

// A row of a list card: ROW_PAD above and below, its content laid along `axis` (.X: one line, centred across it). A row
// that is not the card's first draws the hairline above itself.
@(require_results, deferred_none = card_row_end)
card_row :: proc(id: string, axis := Axis.X) -> bool {
	if parent_box().child_count > 1 { hline(fill()) }   // (the body holds its top inset first: a row after it is the first)
	set_next_axis(.Y)
	gs().next_mod.width = fill()
	gs().next_mod.height = children_sum()
	push_parent(build_box({}, id))
	space(ROW_PAD)
	set_next_axis(axis, axis == .X ? .Center : .Start)
	gs().next_mod.width = fill()
	gs().next_mod.height = children_sum()
	push_parent(build_box({}, fmt.tprintf("%s_content", id)))
	return true
}

@(private)
card_row_end :: proc() {
	pop_parent()   // content
	space(ROW_PAD)
	pop_parent()   // row
}

// A card's box, its padded row and its body, `pad_y` font sizes above its content (card and list_card). `name`: what a
// screen reader says of the group ("": none). `o`: its own look (card's options; zero: the theme's).
@(private)
card_open :: proc(id: string, pad_y: f32, name := "", o := Card_Options{}) {
	em := font_size()
	push_tags("card")
	set_next_axis(.Y)
	gs().next_mod.width = fill()
	gs().next_mod.height = children_sum()
	gs().next_mod.radius = o.radius > 0 ? o.radius * scale() : em * 0.6
	c := build_box({.Draw_Background, .Draw_Border, .Plate}, id)
	if o.look != {} { c.plate = new_clone(o.look, frame_allocator()) }
	a11y_default(c, {role = .Group, name = name})
	push_parent(c)
	set_next_axis(.X)
	gs().next_mod.width = fill()
	gs().next_mod.height = children_sum()
	push_parent(build_box({}, "###card_pad"))
	space(CARD_PAD)
	set_next_axis(.Y)
	gs().next_mod.width = fill()
	gs().next_mod.height = children_sum()
	push_parent(build_box({}, "###card_body"))
	space(pad_y)
}

// Its end, `pad_y` font sizes under its content; nothing after the card (the page puts the gap between two).
@(private)
card_close :: proc(pad_y: f32) {
	space(pad_y)
	pop_parent()   // body
	space(CARD_PAD)
	pop_parent()   // padded row
	pop_parent()   // card
	pop_tags()
}
