package ui

// A preview: content (a picture, a page, a diagram) in a box that fits it, then zooms and pans. The wheel zooms around the
// pointer, a drag moves the content when it is larger than the box, a double click goes from what fits to its pixels and
// back; with the keyboard on it, + and - zoom, 0 fits, the arrows move. A bar over its corner may show the zoom and the
// buttons −, +, 1:1 and Fit. The program keeps a Preview per thing shown (preview_reset when another comes).
//
//	if ui.preview_image("###shot", &app.preview, tex, {w, h}, {buttons = true}).changed { ... }
//	// or any drawing: the content's size in its own units, a proc that draws it in a rectangle of the screen
//	ui.preview("###doc", &app.preview, {doc_w, doc_h}, draw_doc, doc, {buttons = true})
//
// The content's unit is a device pixel at the zoom 100 %: an image's pixel. Fitted, it is never larger than that unless
// Preview_Options.grow says so (a small picture is not blown up).

import "core:fmt"
import "core:math"
import "../draw"
import i18n "../i18n"
import "../render"

// A notch of the wheel, a press of + or -: the zoom times this.
PREVIEW_ZOOM_STEP :: 1.25
// The least zoom, of what fits; the most, in device pixels per unit of the content (0 in the options: these).
PREVIEW_ZOOM_MIN    :: 0.5
PREVIEW_NATIVE_MAX  :: 8
// An arrow key moves the content by this share of the box.
PREVIEW_KEY_PAN :: 0.1
// The bar over the corner: its margin from the box's edges and its height, in ems.
PREVIEW_BAR_MARGIN_EM :: 0.5
PREVIEW_BAR_EM        :: 1.9
PREVIEW_BAR_GUESS_EM  :: 15   // its width before its first frame

// What a preview keeps between frames: the zoom (1: what fits) and how far the content's centre is from the box's.
Preview :: struct {
	zoom: f32,   // 0 is taken as 1
	pan:  Vec2,
	grab: Vec2,  // the pan at the press of a drag
}

Preview_Options :: struct {
	buttons:  bool,     // the bar over the bottom right corner: the zoom in percent, −, +, 1:1, Fit
	grow:     bool,     // fitted, the content may be larger than its pixels
	zoom_max: f32,      // the most, in device pixels per unit (0: PREVIEW_NATIVE_MAX)
	zoom_min: f32,      // the least, of what fits (0: PREVIEW_ZOOM_MIN)
	radius:   f32,      // the content's corners (an image's)
	no_keys:  bool,     // its keys are the program's
}

Preview_Result :: struct {
	box:     ^Box,
	changed: bool,   // the zoom or the pan moved this frame
	percent: f32,    // the zoom shown, in percent of the content's pixels
	fit:     f32,    // device pixels per unit when it fits (zoom 1)
}

// Draws the content into `dst` (screen pixels: where its whole lies, the box clips it).
Preview_Draw_Proc :: proc(dc: ^draw.Context, dst: Rect, user: rawptr)

// The scale at which `content` fits `view` (device pixels per unit), no more than 1 unless `grow`.
preview_fit :: proc(content, view: Vec2, grow: bool) -> f32 {
	if content.x <= 0 || content.y <= 0 || view.x <= 0 || view.y <= 0 { return 1 }
	f := min(view.x / content.x, view.y / content.y)
	return grow ? f : min(f, 1)
}

// The zoom set to `zoom` (within its limits), the point `at` of the view (from its centre) staying where it is.
preview_zoom_to :: proc(p: ^Preview, zoom, least, most: f32, at: Vec2) {
	if p.zoom <= 0 { p.zoom = 1 }
	z := clamp(zoom, least, most)
	p.pan = at - (at - p.pan) * (z / p.zoom)
	p.zoom = z
}

// The pan within reach: none across a side the content fits, else until its edge meets the view's.
preview_pan_clamp :: proc(pan, shown, view: Vec2) -> Vec2 {
	reach := Vec2{max(0, (shown.x - view.x) * 0.5), max(0, (shown.y - view.y) * 0.5)}
	return {clamp(pan.x, -reach.x, reach.x), clamp(pan.y, -reach.y, reach.y)}
}

// Back to what fits, in the middle.
preview_reset :: proc(p: ^Preview) { p^ = {zoom = 1} }

@(private = "file")
Preview_Draw :: struct {
	fn:      Preview_Draw_Proc,
	user:    rawptr,
	content: Vec2,
	zoom:    f32,
	pan:     Vec2,
	grow:    bool,
}

// (what fits is worked out here, from the box as laid out this frame: the build knows only last frame's size, none for a
// box new this frame, and the content showed at its pixels for a frame before it fitted)
@(private = "file")
preview_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Preview_Draw)(user)
	r := b.rect
	view := r.max - r.min
	shown := d.content * preview_fit(d.content, view, d.grow) * d.zoom
	pan := preview_pan_clamp(d.pan, shown, view)
	c := (r.min + r.max) * 0.5 + pan
	lo, hi := c - shown * 0.5, c + shown * 0.5
	draw.push_clip(dc, r)
	d.fn(dc, {{math.round(lo.x), math.round(lo.y)}, {math.round(hi.x), math.round(hi.y)}}, d.user)
	draw.pop_clip(dc)
}

// The preview of content `content` units large, drawn by `fn`. Its size is the caller's (`next`; else it fills).
preview :: proc(id: string, p: ^Preview, content: Vec2, fn: Preview_Draw_Proc, user: rawptr, o := Preview_Options{}) -> (res: Preview_Result) {
	s := gs()
	em := font_size()
	if p.zoom <= 0 { p.zoom = 1 }
	if !s.has_next || s.next_mod.width == nil { next_merge({width = fill()}) }
	if s.next_mod.height == nil { next_merge({height = fill()}) }
	b := build_box({.Clickable, .Focusable, .Scroll_Self, .Clip}, id)
	res.box = b
	view := b.rect.max - b.rect.min   // (last frame's: the box keeps its key)
	fit := preview_fit(content, view, o.grow)
	least := o.zoom_min > 0 ? o.zoom_min : PREVIEW_ZOOM_MIN
	most := max(1, (o.zoom_max > 0 ? o.zoom_max : PREVIEW_NATIVE_MAX) / fit)
	before := p^
	shown := content * fit * p.zoom
	pannable := shown.x > view.x + 0.5 || shown.y > view.y + 0.5
	b.cursor = pannable ? (s.active_key[.Left] == b.key ? .Grabbing : .Grab) : .Arrow
	sig := signal(b)
	at := sig.mouse - view * 0.5
	if sig.scrolled.y != 0 { preview_zoom_to(p, p.zoom * math.pow(f32(PREVIEW_ZOOM_STEP), -sig.scrolled.y), least, most, at) }
	if sig.pointer_pressed { p.grab = p.pan; set_focus(b.key) }
	if sig.dragging && pannable { p.pan = p.grab + sig.drag_delta }
	if sig.double_clicked {
		// (what fits is the content's pixels already: twice them)
		native := 1 / fit
		preview_zoom_to(p, p.zoom != 1 ? 1 : (native > 1.01 ? native : 2), least, most, at)
	}
	if !o.no_keys && s.focus_key == b.key {
		if key_press(.Equal) || key_press(.Equal, {.Shift}) || key_press(.Num_Add) { preview_zoom_to(p, p.zoom * PREVIEW_ZOOM_STEP, least, most, {}) }
		if key_press(.Minus) || key_press(.Num_Subtract) { preview_zoom_to(p, p.zoom / PREVIEW_ZOOM_STEP, least, most, {}) }
		if key_press(.N0) { preview_reset(p) }
		if key_press(.Left) { p.pan.x += view.x * PREVIEW_KEY_PAN }
		if key_press(.Right) { p.pan.x -= view.x * PREVIEW_KEY_PAN }
		if key_press(.Up) { p.pan.y += view.y * PREVIEW_KEY_PAN }
		if key_press(.Down) { p.pan.y -= view.y * PREVIEW_KEY_PAN }
	}
	if o.buttons {
		if bar := preview_bar(b, view, fit, p.zoom, em); bar != .None {
			switch bar {
			case .Out:    preview_zoom_to(p, p.zoom / PREVIEW_ZOOM_STEP, least, most, {})
			case .In:     preview_zoom_to(p, p.zoom * PREVIEW_ZOOM_STEP, least, most, {})
			case .Native: preview_zoom_to(p, 1 / fit, least, most, {})
			case .Fit:    preview_reset(p)
			case .None:
			}
		}
	}
	shown = content * fit * p.zoom
	p.pan = preview_pan_clamp(p.pan, shown, view)
	d := frame_new(Preview_Draw)
	d^ = {fn, user, content, p.zoom, p.pan, o.grow}
	b.custom, b.custom_user = preview_draw, d
	a11y_default(b, {role = .Image, name = i18n.tr("Preview")})
	res.changed = p.zoom != before.zoom || p.pan != before.pan
	res.fit = fit
	res.percent = fit * p.zoom * 100
	if res.changed { wake_within(s, 1) }
	return
}

// An image's texture, `size` its pixels.
preview_image :: proc(id: string, p: ^Preview, tex: render.Texture, size: Vec2, o := Preview_Options{}) -> Preview_Result {
	Image :: struct { tex: render.Texture, radius: f32 }
	im := frame_new(Image)
	im^ = {tex, o.radius}
	return preview(id, p, size, proc(dc: ^draw.Context, dst: Rect, user: rawptr) {
		im := (^Image)(user)
		draw.image(dc, im.tex, dst, radius = im.radius)
	}, im, o)
}

@(private = "file")
Preview_Button :: enum u8 { None, Out, In, Native, Fit }

// The bar over the bottom right corner of the box: the zoom, then its buttons. The one clicked.
@(private = "file")
preview_bar :: proc(b: ^Box, view: Vec2, fit, zoom: f32, em: f32) -> (clicked: Preview_Button) {
	margin := math.round(em * PREVIEW_BAR_MARGIN_EM)
	h := math.round(em * PREVIEW_BAR_EM)
	// (as wide as what it holds: its width of the last frame places it in the corner; the first, an estimate)
	w := math.round(em * PREVIEW_BAR_GUESS_EM)
	if last := box_from_key(key_from_string(b.key, "preview_bar")); last != nil && last.rect.max.x > last.rect.min.x {
		w = last.rect.max.x - last.rect.min.x
	}
	if view.x < w + 2 * margin || view.y < h + 2 * margin { return }
	if parent(b) {
		next({fixed_x = view.x - w - margin, fixed_y = view.y - h - margin, width = children_sum(), height = px(h), axis = .X, cross = .Center, radius = rad(em * 0.4)})
		push_tags("bar")
		bar := build_box({.Draw_Background, .Draw_Border}, "###preview_bar")
		pop_tags()
		if parent(bar) {
			spacer(px(em * 0.4))
			if tags("weak") {
				// (its own width: a fill beside the buttons' text sizes had none left)
				next({width = text_size(em * 0.2), height = pct(1), font_size = em * 0.85})
				label(fmt.tprintf("%.0f %%###preview_zoom", fit * zoom * 100))
			}
			spacer(px(em * 0.3))
			items := [?]struct { id, text: string, which: Preview_Button }{
				{"preview_out", "−", .Out}, {"preview_in", "+", .In}, {"preview_native", "1:1", .Native}, {"preview_fit", i18n.tr("Fit"), .Fit},
			}
			for it in items {
				next({width = text_size(em * 0.45), height = px(h - em * 0.5), radius = rad(em * 0.3)})
				a11y({name = it.which == .Out ? i18n.tr("Zoom out") : it.which == .In ? i18n.tr("Zoom in") : it.which == .Native ? i18n.tr("Actual size") : i18n.tr("Fit")})
				if button(it.id, it.text, o = {face = .Ghost}).clicked { clicked = it.which }
			}
			spacer(px(em * 0.3))
		}
	}
	return
}
