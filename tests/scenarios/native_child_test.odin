package scenarios_test

// Popups over native child views (src/md/features/popup-over-native.md):
// ui.native_child(b) registers a box hosting an OS child window; ui splits the tree at the last
// root child containing a native child, flags overlay visuals (including drop-shadow reach), and
// computes exact input-shield rectangles (empty for tooltips, clipped to the native child for
// toasts/floating views, covering the native child while menus or modals are open).

import "core:testing"
import "gt:draw"
import "gt:render"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Native_Run :: struct {
	announcer:       ui.Announcer,
	show_tooltip:    bool,
	tooltip_at:      ui.Rect,
	show_toast:      bool,
	toast_sent:      bool,
	open_menu:       bool,
	menu_at:         ui.Vec2,
	open_modal:      bool,
	modal_sent:      bool,
	floating_native: bool,
	floating_other:  bool,
	native_rect:     ui.Rect,
}

@(private = "file")
native_build :: proc(s: ^session.Session) {
	r := (^Native_Run)(s.user)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.row(flags = {.Draw_Background}, id = "###page") {
		ui.next({width = ui.px(160), height = ui.fill(), axis = .Y})
		if ui.column(id = "###sidebar") {
			ui.next({width = ui.px(120), height = ui.px(32)})
			if ui.button("btn", "Action").clicked { r.open_menu = true }
		}
		ui.next({width = ui.fill(), height = ui.fill(), bg = ui.Color{0.1, 0.2, 0.4, 1}})
		host_box := ui.build_box({.Draw_Background}, "###native_host")
		if !r.floating_native {
			ui.native_child(host_box)
			r.native_rect = host_box.rect
		}
	}

	if r.floating_native {
		// (simulate a floating view hosting the native child: its own frame must stay on the base layer)
		ui.next({fixed_x = 180, fixed_y = 60, fixed_w = 240, fixed_h = 200, axis = .Y, bg = ui.Color{0.15, 0.15, 0.2, 1}})
		fv := ui.build_box({.Clickable, .Draw_Background, .Draw_Border}, "###float_native")
		if ui.parent(fv) {
			ui.next({width = ui.fill(), height = ui.fill()})
			nb := ui.build_box({}, "###float_native_body")
			ui.native_child(nb)
			r.native_rect = nb.rect
		}
	}

	if r.floating_other {
		ui.next({fixed_x = 220, fixed_y = 100, fixed_w = 140, fixed_h = 80, bg = ui.Color{0.8, 0.2, 0.2, 1}})
		_ = ui.build_box({.Clickable, .Draw_Background, .Draw_Border}, "###float_over")
	}

	if r.show_tooltip {
		if ui.tooltip_near(r.tooltip_at) {
			ui.tooltip_text("Tip over native view")
		}
	}

	if r.open_menu {
		ui.menu_open("native_menu", r.menu_at)
		r.open_menu = false
	}
	if ui.menu("native_menu") {
		_ = ui.menu_item("First item")
		_ = ui.menu_item("Second item")
	}

	if r.show_toast && !r.toast_sent {
		r.toast_sent = true
		r.announcer.mode = .Window
		ui.announce(&r.announcer, .Info, "Toast over native")
	}

	if r.open_modal && !r.modal_sent {
		r.modal_sent = true
		ui.confirm_open("native_confirm", {title = "Confirm", note = "Over native child", act = "OK"})
	}
}

@(test)
native_child_idle_has_no_overlay_or_shield :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Native_Run
	s := session.start(t, {size = {520, 360}, user = &r, build = native_build})
	session.frames(s, 2)
	testing.expect(t, ui.has_native_children(s.state), "native child registered")
	testing.expect(t, !ui.has_native_overlay(s.state), "no overlay when idle")
	testing.expect_value(t, len(ui.native_input_rects(s.state)), 0)
}) }

@(test)
native_child_tooltip_draws_on_overlay_without_input_shield :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Native_Run{
		show_tooltip = true,
		tooltip_at   = {{220, 120}, {260, 140}},
	}
	s := session.start(t, {size = {520, 360}, user = &r, build = native_build})
	// (tooltips measure on frame 1 at transparency 1 and show on frame 2)
	session.frames(s, 3)
	testing.expect(t, ui.has_native_children(s.state), "native child registered")
	testing.expect(t, ui.has_native_overlay(s.state), "tooltip overlapping native child activates overlay")
	testing.expect_value(t, len(ui.native_input_rects(s.state)), 0)
}) }

@(test)
native_child_tooltip_shadow_reach_activates_overlay :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	// Place tooltip just to the left of the native child (x = 160): bare box sits inside the sidebar,
	// while its drop shadow extends across x = 160 into the native child.
	r := Native_Run{
		show_tooltip = true,
		tooltip_at   = {{152, 120}, {158, 140}},
	}
	s := session.start(t, {size = {520, 360}, user = &r, build = native_build})
	session.frames(s, 3)
	testing.expect(t, ui.has_native_overlay(s.state), "shadow reaching across native child edge activates overlay")
	testing.expect_value(t, len(ui.native_input_rects(s.state)), 0)
}) }

@(test)
native_child_toast_shields_only_its_overlap :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Native_Run{show_toast = true}
	s := session.start(t, {size = {520, 360}, user = &r, build = native_build})
	// Default toast position is Bottom_Right, inside the native child on the right half.
	session.frames(s, 4)
	testing.expect(t, ui.has_native_overlay(s.state), "toast activates overlay")
	rects := ui.native_input_rects(s.state)
	testing.expect_value(t, len(rects), 1)
	if len(rects) == 1 {
		// Shield rect must stay strictly within the native child rect (not covering the whole native child)
		ir := rects[0]
		nr := r.native_rect
		testing.expect(t, ir.min.x >= nr.min.x - 0.5 && ir.max.x <= nr.max.x + 0.5, "shield X inside native child")
		testing.expect(t, ir.min.y >= nr.min.y - 0.5 && ir.max.y <= nr.max.y + 0.5, "shield Y inside native child")
		testing.expect(t, (ir.max.y - ir.min.y) < (nr.max.y - nr.min.y) * 0.5, "shield covers only toast height, not whole native child")
	}
}) }

@(test)
native_child_menu_and_modal_shield_whole_native_child :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	// Menu opened in the sidebar (away from native child): clicking the native child must still dismiss it.
	r := Native_Run{open_menu = true, menu_at = {20, 40}}
	s := session.start(t, {size = {520, 360}, user = &r, build = native_build})
	session.frames(s, 3)
	rects := ui.native_input_rects(s.state)
	testing.expect_value(t, len(rects), 1)
	if len(rects) == 1 {
		testing.expect_value(t, rects[0], r.native_rect)
	}

	// Menu opened over the native child: both overlay visuals and shield are active.
	r.open_menu, r.menu_at = true, {240, 80}
	session.frames(s, 3)
	testing.expect(t, ui.has_native_overlay(s.state), "menu over native child activates overlay")
	testing.expect_value(t, len(ui.native_input_rects(s.state)), 1)

	// Close menu, open modal: scrim dims the whole window including native child.
	ui.menu_close()
	r.open_modal = true
	session.frames(s, 4)
	testing.expect(t, ui.has_native_overlay(s.state), "modal scrim activates overlay")
	testing.expect_value(t, len(ui.native_input_rects(s.state)), 1)
}) }

@(test)
native_child_in_floating_view_stays_on_base_while_higher_overlay_splits :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Native_Run{floating_native = true}
	s := session.start(t, {size = {520, 360}, user = &r, build = native_build})
	session.frames(s, 2)
	testing.expect(t, ui.has_native_children(s.state), "floating native child registered")
	testing.expect(t, !ui.has_native_overlay(s.state), "floating host itself does not trigger overlay above itself")
	testing.expect_value(t, len(ui.native_input_rects(s.state)), 0)

	// A floating panel stacked AFTER the floating native host triggers the overlay and shield.
	r.floating_other = true
	session.frames(s, 2)
	testing.expect(t, ui.has_native_overlay(s.state), "higher floating box activates overlay")
	testing.expect_value(t, len(ui.native_input_rects(s.state)), 1)
}) }

@(test)
draw_tree_base_and_overlay_separate_layers_cleanly :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Native_Run{floating_native = true, floating_other = true}
	s := session.start(t, {size = {520, 360}, user = &r, build = native_build})
	session.frames(s, 2)
	testing.expect(t, ui.has_native_overlay(s.state), "overlay active")
	dc := session.draw_context(s)

	// Render ONLY the base layer and sample inside ###float_over (220..360, 100..180):
	// ###float_over is bright red (0.8, 0.2, 0.2) and MUST NOT appear in draw_tree_base.
	draw.begin_frame(dc, {520, 360})
	render.frame_begin(s.renderer, {})
	ui.draw_tree_base(s.state, dc)
	draw.end_frame(dc)
	render.frame_end(s.renderer, false)
	base_img := session.capture(s)
	base_px := session.pixel(base_img, 280, 140)
	testing.expectf(t, base_px.r < 120, "base layer must not draw higher overlay box: got %v", base_px)

	// Render ONLY the overlay layer cleared to transparent:
	// inside ###float_over -> opaque red; inside the base sidebar (x=40, y=140) -> transparent (alpha 0).
	draw.begin_frame(dc, {520, 360})
	render.frame_begin(s.renderer, {})
	draw.set_partial_redraw(dc, false)
	ui.draw_tree_overlay(s.state, dc)
	draw.end_frame(dc)
	render.frame_end(s.renderer, false)
	over_img := session.capture(s)
	over_px := session.pixel(over_img, 280, 140)
	side_px := session.pixel(over_img, 40, 140)
	testing.expectf(t, over_px.r > 180 && over_px.a > 240, "overlay layer draws higher box opaque red: got %v", over_px)
	testing.expectf(t, side_px.a == 0, "overlay layer leaves base area transparent: got %v", side_px)
}) }
