package scenarios_test

// What a tool bar's tools look like: a picture of fidget's bar and of a composer's bar (toolbar_faces.png in the test's
// folder, src/md/features/toolbar.md).

import "core:fmt"
import "core:math"
import "core:testing"
import "gt:draw"
import lucide "gt:lucide"
import "gt:platform"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Faces_Run :: struct { tool: int, width: f32 }

// fidget's tool bar (examples/fidget/pages.odin, demo_toolbar), with Lucide's glyphs.
@(private = "file")
faces_fidget_bar :: proc(r: ^Faces_Run) {
	em := ui.font_size()
	icons := ui.lucide_icons()
	glyphs := [?]string{lucide.PENCIL, lucide.TYPE, lucide.ERASER, lucide.IMAGE}
	names := [?]string{"Pen", "Text", "Eraser", "Image"}
	keys := [?]string{"P", "T", "G", "I"}
	hues := [?]f32{0.62, 0.02, 0.40, 0.13}
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.8))})
	if ui.toolbar("fidget_bar", {overflow = .Fold}) {
		if ui.toolbar_group("tools", {title = "Tools", priority = 2}) {
			for g, i in glyphs {
				if ui.toolbar_tool(fmt.tprintf("tool%d", i), {label = names[i], icon = g, icon_font = icons, shortcut = keys[i], on = r.tool == i}) { r.tool = i }
			}
		}
		if ui.toolbar_group("style", {title = "Style", separator = true}) {
			if ui.toolbar_control("colour", {label = "Colour"}) {
				side := math.round(em * 1.4)
				for h, i in hues {
					if i > 0 { ui.spacer(ui.px(math.round(em * 0.25))) }
					ui.next({width = ui.px(side), height = ui.px(side), radius = side * 0.5, bg = draw.hsv(h, 0.65, 0.95)})
					_ = ui.build_box({.Draw_Background, .Fixed_Radius}, fmt.tprintf("###swatch%d", i))
				}
			}
			if ui.toolbar_control("width", {label = "Width", labelled = true}) {
				ui.next({width = ui.px(math.round(em * 7)), height = ui.px(math.round(em * 1.6))})
				ui.slider("###width", &r.width, 1, 20, 1, "%.0f")
			}
		}
		if ui.toolbar_group("edit", {title = "Edit", priority = 1, separator = true}) {
			_ = ui.toolbar_tool("undo", {label = "Undo", icon = lucide.UNDO_2, icon_font = icons, shortcut = "Ctrl+Z"})
			_ = ui.toolbar_tool("save", {label = "Save", icon = lucide.SAVE, icon_font = icons, shortcut = "Ctrl+S"})
		}
		if ui.toolbar_group("end", {pinned = true}) {
			_ = ui.toolbar_tool("cancel", {label = "Cancel", words = true})
			_ = ui.toolbar_tool("done", {label = "Done", words = true, intent = .Primary})
		}
	}
}

// A composer's bar, as opencode native builds it: an agent, a model, a thinking level, an approval mode in words (short
// in the bar, whole in the menu); subagents, a terminal and a stop at its end, which fold; Steer pinned.
@(private = "file")
faces_composer_bar :: proc(r: ^Faces_Run) {
	icons := ui.lucide_icons()
	ui.next({width = ui.fill(), height = ui.px(math.round(ui.font_size() * 2.6))})
	if ui.toolbar("composer_bar", {overflow = .Fold}) {
		if ui.toolbar_group("attach") {
			_ = ui.toolbar_tool("attach", {label = "Attach a file", icon = lucide.PAPERCLIP, icon_font = icons})
		}
		if ui.toolbar_group("run", {title = "Run", priority = 1}) {
			_ = ui.toolbar_tool("agent", {label = "Agent: plan", bar_label = "plan", icon = lucide.BOT, icon_font = icons, words = true})
			_ = ui.toolbar_tool("model", {label = "Model: Opus 5.5", bar_label = "Opus 5.5", icon = lucide.CPU, icon_font = icons, words = true})
			_ = ui.toolbar_tool("thinking", {label = "Thinking: low", bar_label = "low", icon = lucide.GAUGE, icon_font = icons, words = true})
			_ = ui.toolbar_tool("approval", {label = "Approval: all", bar_label = "all", icon = lucide.SHIELD, icon_font = icons, icon_intent = .Warning, words = true})
		}
		if ui.toolbar_group("side", {title = "Panels", end = true}) {
			_ = ui.toolbar_tool("subagents", {label = "Subagents", icon = lucide.BOT, icon_font = icons, badge = 2})
			_ = ui.toolbar_tool("terminal", {label = "Terminal", icon = lucide.TERMINAL, icon_font = icons, dot = .Pulse})
			_ = ui.toolbar_tool("stop", {label = "Stop", icon = lucide.SQUARE, icon_font = icons, intent = .Danger})
		}
		if ui.toolbar_group("send", {pinned = true}) {
			_ = ui.toolbar_tool("steer", {label = "Steer", icon = lucide.SEND, icon_font = icons, words = true, intent = .Primary})
		}
	}
}

// The picture of both bars, for a person to look at (the tests below check what it shows).
@(test)
toolbar_faces_picture :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Faces_Run{width = 4}
	s := session.start(t, {size = {1100, 220}, user = &r, build = proc(s: ^session.Session) {
		r := (^Faces_Run)(s.user)
		em := ui.font_size()
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###page") {
			ui.spacer(ui.px(em))
			faces_fidget_bar(r)
			ui.spacer(ui.px(em * 1.5))
			faces_composer_bar(r)
		}
	}})
	session.frames(s, 4)
	session.save_png(s, "toolbar_faces.png")
	session.hover(s, "model")
	session.frames(s, 3)
	session.save_png(s, "toolbar_faces_hover.png")
	// (narrow: the end group folds before the tools in words, the "…" button before Steer)
	session.leave(s)
	session.resize(s, {560, 220})
	session.frames(s, 5)
	session.save_png(s, "toolbar_faces_narrow.png")
}) }

// Longer than a tooltip's delay (ui.FEEL_DEFAULT.tooltip_delay_ms, 500 ms).
@(private = "file") TOOLTIP_WAIT_MS :: 600

////////////////////////////////
// The tests of what the picture shows

// The colour of the page behind the bars, and of a tool's face at its left edge (inside its border), in the last frame.
@(private = "file")
face_at :: proc(img: session.Image, b: ^ui.Box) -> session.Color {
	return session.pixel(img, int(b.rect.min.x) + 3, int((b.rect.min.y + b.rect.max.y) * 0.5))
}

@(private = "file")
Look_Run :: struct { raised: bool }

@(private = "file")
look_build :: proc(s: ^session.Session) {
	r := (^Look_Run)(s.user)
	icons := ui.lucide_icons()
	ui.next({fixed_x = 20, fixed_y = 20, width = ui.px(900), height = ui.px(44)})
	if ui.toolbar("look_bar", {overflow = .Fold}) {
		if ui.toolbar_group("run") {
			_ = ui.toolbar_tool("model", {label = "Model: Opus 5.5", bar_label = "Opus 5.5", icon = lucide.CPU, icon_font = icons, words = true})
			_ = ui.toolbar_tool("plain", {label = "Plain"})
			_ = ui.toolbar_tool("cancel", {label = "Cancel", words = true, face = r.raised ? ui.Button_Face.Raised : nil})
			_ = ui.toolbar_tool("hint", {label = "Hint", words = true, face = .Link})
			_ = ui.toolbar_tool("picker", {label = "Picker", words = true, lit = true})
		}
		if ui.toolbar_group("send", {pinned = true}) {
			_ = ui.toolbar_tool("send", {label = "Send", words = true, intent = .Primary})
		}
	}
}

// A tool in words has no face at rest; under the pointer, pressed and `lit` it has one. Words of intent .Primary are
// raised at rest, and `face` raises another; .Link has none even under the pointer.
@(test)
a_toolbar_tool_in_words_has_no_face_at_rest :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Look_Run{}
	s := session.start(t, {size = {960, 120}, user = &r, build = look_build})
	session.frames(s, 4)
	session.move(s, {5, 100})
	session.frames(s, 2)
	img := session.capture(s)
	ground := session.pixel(img, 10, 10)
	for name in ([]string{"model", "plain", "cancel"}) {
		b := session.get(s, name)
		testing.expectf(t, session.near(face_at(img, b), ground, 2), "%s at rest: no face (%v on %v)", name, face_at(img, b), ground)
	}
	testing.expectf(t, !session.near(face_at(img, session.get(s, "send")), ground, 6), "Send (.Primary): raised at rest")
	testing.expectf(t, !session.near(face_at(img, session.get(s, "picker")), ground, 2), "a lit tool shows its face")
	testing.expect(t, .Lit in session.get(s, "picker").flags, "lit: the box is lit")
	testing.expect(t, .Draw_Background not_in session.get(s, "hint").flags, ".Link: no face at rest")
	// (under the pointer, then pressed)
	session.hover(s, "model")
	session.frames(s, 2)
	img = session.capture(s)
	hovered := face_at(img, session.get(s, "model"))
	testing.expectf(t, !session.near(hovered, ground, 2), "under the pointer: its face (%v on %v)", hovered, ground)
	session.press(s, session.center(session.get(s, "model")))
	session.frames(s, 2)
	img = session.capture(s)
	testing.expectf(t, !session.near(face_at(img, session.get(s, "model")), ground, 2), "pressed: its face")
	session.release(s, session.center(session.get(s, "model")))
	session.hover(s, "hint")
	session.frames(s, 2)
	testing.expect(t, .Draw_Background not_in session.get(s, "hint").flags, ".Link: no face under the pointer")
	// (face: .Raised)
	session.move(s, {5, 100})
	r.raised = true
	session.frames(s, 3)
	img = session.capture(s)
	testing.expectf(t, !session.near(face_at(img, session.get(s, "cancel")), ground, 2), "face .Raised: raised at rest")
}) }

// `bar_label` is the bar's words; `label` the tooltip's, a screen reader's and, folded, the menu row's.
@(test)
a_toolbar_tool_has_its_bar_words_and_its_menu_words :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { bar_w: f32 }
	r := Run{}
	s := session.start(t, {size = {900, 400}, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = r.bar_w > 0 ? ui.px(r.bar_w) : ui.fill(), height = ui.px(40)})
		if ui.toolbar("wbar", {overflow = .Fold}) {
			if ui.toolbar_group("run") {
				_ = ui.toolbar_tool("effort", {label = "Thinking: high", bar_label = "high", words = true})
			}
			if ui.toolbar_group("end", {pinned = true}) { _ = ui.toolbar_tool("send", {label = "Envoyer", words = true, intent = .Primary}) }
		}
	}})
	session.frames(s, 3)
	effort := session.get(s, "effort")
	testing.expect(t, session.find_text(s, "high") != nil && session.find_text(s, "Thinking: high") == nil, "the bar shows its short words")
	testing.expect(t, effort.a11y != nil && effort.a11y.name == "Thinking: high", "a screen reader hears the whole name")
	session.hover(s, "effort")
	session.advance(s, TOOLTIP_WAIT_MS)
	testing.expect(t, session.find_text(s, "Thinking: high") != nil, "the tooltip says the whole name")
	session.leave(s)
	send := session.get(s, "send")
	r.bar_w = send.size.x * 1.5
	session.frames(s, 4)
	more := session.get(s, "toolbar_more")
	r.bar_w = send.size.x + more.size.x + more.font_size
	session.frames(s, 4)
	testing.expect(t, session.find(s, "effort") == nil, "folded")
	session.click(s, "toolbar_more")
	row := session.wait_text(s, "Thinking: high")
	testing.expect_value(t, ui.box_text(row), "Thinking: high")
}) }

@(private = "file")
End_Run :: struct { bar_w: f32, terminal: int }

// A start group, an `end` group (folds first: its priority is lower), a pinned Send.
@(private = "file")
end_build :: proc(s: ^session.Session) {
	r := (^End_Run)(s.user)
	ui.next({width = r.bar_w > 0 ? ui.px(r.bar_w) : ui.fill(), height = ui.px(40)})
	if ui.toolbar("ebar", {overflow = .Fold}) {
		if ui.toolbar_group("run", {title = "Exécution", priority = 1}) {
			for name in ([]string{"agent", "model", "effort", "approval"}) { _ = ui.toolbar_tool(name, {label = name, words = true}) }
		}
		if ui.toolbar_group("side", {title = "Panneaux", end = true}) {
			if ui.toolbar_tool("terminal", {label = "Terminal", words = true}) { r.terminal += 1 }
			_ = ui.toolbar_tool("preview", {label = "Aperçu", words = true})
		}
		if ui.toolbar_group("send", {pinned = true}) { _ = ui.toolbar_tool("send", {label = "Envoyer", words = true, intent = .Primary}) }
	}
}

// An `end` group stands at the bar's end, before Send, a group's room from it; narrower, it folds into the "…" menu
// before the start group (its priority), the "…" button between it and Send; at every width nothing runs past the bar.
@(test)
a_toolbar_end_group_stays_at_the_end_and_folds :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := End_Run{}
	s := session.start(t, {size = {1000, 400}, user = &r, no_renderer = true, build = end_build})
	session.frames(s, 3)
	bar, send, preview, terminal := session.get(s, "ebar"), session.get(s, "send"), session.get(s, "preview"), session.get(s, "terminal")
	em := send.font_size
	testing.expectf(t, abs(send.rect.max.x - bar.rect.max.x) <= 1, "Send at the bar's end: %v of %v", send.rect.max.x, bar.rect.max.x)
	gap := send.rect.min.x - preview.rect.max.x
	testing.expectf(t, gap >= em * 0.8 && gap <= em * 1.5, "the end group a group's room before Send: %v px", gap)
	testing.expectf(t, terminal.rect.min.x - session.get(s, "approval").rect.max.x > 5 * em, "the end group far from the start group: at the end")
	testing.expect(t, session.find(s, "toolbar_more") == nil, "room for all: no \"…\" button")
	saw_end_folded_alone, saw_all_folded := false, false
	// (down to the room of Send and the "…" button, about 150 px, which never fold: below it they run past the bar)
	for w := 1000; w >= 160; w -= 29 {
		r.bar_w = f32(w)
		session.frames(s, 4)
		bar = session.get(s, "ebar")
		send = session.get(s, "send")
		testing.expectf(t, abs(send.rect.max.x - bar.rect.max.x) <= 1, "at %d px: Send at the bar's end", w)
		more := session.find(s, "toolbar_more")
		// (a pixel of rounding: the layout rounds a box's start and its size apart, so a half-pixel start and a half-pixel
		// width end a pixel further, as Done in toolbar_test.odin)
		for name in ([]string{"agent", "model", "effort", "approval", "terminal", "preview", "toolbar_more", "send"}) {
			b := session.find(s, name, within = bar)
			if b == nil { continue }
			testing.expectf(t, b.rect.max.x <= bar.rect.max.x + 1, "at %d px: %s ends at %v, past the bar's end %v", w, name, b.rect.max.x, bar.rect.max.x)
		}
		if p := session.find(s, "preview"); p != nil {
			testing.expect(t, more == nil || p.rect.max.x <= more.rect.min.x, "the end group before the \"…\" button")
		}
		if more != nil { testing.expectf(t, more.rect.max.x <= send.rect.min.x, "at %d px: the \"…\" button before Send", w) }
		start_shown := session.find(s, "agent") != nil
		end_shown := session.find(s, "terminal") != nil
		testing.expectf(t, !end_shown || start_shown || session.find(s, "approval") != nil, "at %d px: the end group (priority 0) folds before the start group (1)", w)
		if !end_shown && start_shown { saw_end_folded_alone = true }
		if !end_shown && !start_shown { saw_all_folded = true }
	}
	testing.expect(t, saw_end_folded_alone, "a width where the end group alone is folded")
	testing.expect(t, saw_all_folded, "a width where both are folded")
	// (folded, its tools are rows of the "…" menu under its title, and run there)
	session.click(s, "toolbar_more")
	session.wait_text(s, "Panneaux")
	session.click_text(s, "Terminal")
	session.frames(s, 2)
	testing.expect_value(t, r.terminal, 1)
}) }

@(private = "file")
Badge_Run :: struct { count: int, dot: ui.Badge_Dot }

// A tool's badge is ui.badge on its corner; its dot ui.badge_dot. A pulsing dot asks for a wake of its own pace, not a
// frame each refresh, and none once it is gone; animations off, it asks for nothing.
@(test)
a_toolbar_tool_shows_a_badge_or_a_dot :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Badge_Run{count = 3}
	s := session.start(t, {size = {600, 200}, user = &r, animations = true, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Badge_Run)(s.user)
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.toolbar("bbar", {overflow = .Fold}) {
			if ui.toolbar_group("g") {
				_ = ui.toolbar_tool("agents", {label = "Sous-agents", icon = lucide.BOT, icon_font = ui.lucide_icons(), badge = r.count, dot = r.dot})
			}
		}
	}})
	session.frames(s, 3)
	tool := session.get(s, "agents")
	pill := session.get(s, "badge_count", within = tool)
	testing.expect_value(t, ui.box_text(pill), "3")
	testing.expect(t, session.find(s, "badge_dot_disc") == nil, "a count, no dot")
	r.count, r.dot = 0, .Pulse
	session.frames(s, 3)
	tool = session.get(s, "agents")
	disc := session.get(s, "badge_dot_disc", within = tool)
	testing.expect(t, disc.rect.max.x <= tool.rect.max.x && disc.rect.max.x > (tool.rect.min.x + tool.rect.max.x) * 0.5 && disc.rect.min.y >= tool.rect.min.y, "the dot in the tool's top right corner")
	testing.expect(t, session.find(s, "badge_count") == nil, "no count at 0")
	wake := ui.wake_ms(s.state)
	testing.expectf(t, wake > 0 && wake <= ui.BADGE_PULSE_STEP_MS, "pulsing: a wake of its pace (%d ms)", wake)
	testing.expect(t, !ui.needs_frame(s.state), "pulsing: no frame each refresh")
	r.dot = .Still
	session.frames(s, 3)
	testing.expect(t, session.find(s, "badge_dot_disc") != nil, "a still dot")
	testing.expect_value(t, ui.wake_ms(s.state), 0)
	r.dot = .None
	session.frames(s, 3)
	testing.expect(t, session.find(s, "badge_dot_disc") == nil, "no dot")
}) }

// `icon_intent` colours the glyph alone, in the intent's hue; the words keep theirs.
@(test)
a_toolbar_tool_glyph_shows_its_intent :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { intent: Maybe(ui.Intent) }
	r := Run{}
	s := session.start(t, {size = {600, 200}, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.toolbar("ibar", {overflow = .Fold}) {
			if ui.toolbar_group("g") {
				_ = ui.toolbar_tool("approval", {label = "all", icon = lucide.SHIELD, icon_font = ui.lucide_icons(), words = true, icon_intent = r.intent})
			}
		}
	}})
	session.frames(s, 3)
	tool := session.get(s, "approval")
	plain := session.get(s, "ico", within = tool).text_color
	words := session.get(s, "t", within = tool).text_color
	r.intent = .Warning
	session.frames(s, 3)
	tool = session.get(s, "approval")
	warned := session.get(s, "ico", within = tool).text_color
	testing.expectf(t, warned != plain, "the glyph in the intent's hue: %v, plain %v", warned, plain)
	testing.expect(t, session.get(s, "t", within = tool).text_color == words, "the words keep their colour")
}) }

// A tool with no face at rest still shows where the keyboard is: Tab to it draws its focus ring around it, in words and
// as a glyph alone.
@(test)
a_ghost_toolbar_tool_shows_the_keyboard_focus :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Look_Run{}
	s := session.start(t, {size = {960, 120}, user = &r, build = look_build})
	session.frames(s, 4)
	session.move(s, {5, 100})
	session.frames(s, 2)
	rest := session.capture(s)
	for name in ([]string{"model", "plain"}) {
		// (bounded: the bar's tools are few)
		for i := 0; i < 12 && session.focused_name(s) != name; i += 1 { session.key(s, .Tab) }
		testing.expectf(t, session.focused_name(s) == name, "Tab reaches %s", name)
		session.frames(s, 2)
		img := session.capture(s)
		b := session.get(s, name)
		changed := 0
		for y := int(b.rect.min.y) - 4; y <= int(b.rect.max.y) + 4; y += 1 {
			for x := int(b.rect.min.x) - 4; x <= int(b.rect.max.x) + 4; x += 1 {
				if !session.near(session.pixel(img, x, y), session.pixel(rest, x, y), 6) { changed += 1 }
			}
		}
		// (a ring: at least its two long sides)
		testing.expectf(t, f32(changed) >= b.size.x, "%s under the keyboard focus: its ring shows (%d pixels changed)", name, changed)
	}
}) }

// A tool in words turned `on` keeps its width: a mode turned on does not shift the bar.
@(test)
a_toolbar_tool_in_words_keeps_its_width_when_on :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { on: bool }
	r := Run{}
	s := session.start(t, {size = {600, 200}, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.toolbar("obar", {overflow = .Fold}) {
			if ui.toolbar_group("g") {
				_ = ui.toolbar_tool("mode", {label = "Preview", words = true, on = r.on})
				_ = ui.toolbar_tool("next", {label = "Next", words = true})
			}
		}
	}})
	session.frames(s, 3)
	off_w, off_x := session.get(s, "mode").size.x, session.get(s, "next").rect.min.x
	r.on = true
	session.frames(s, 3)
	testing.expect(t, .Held in session.get(s, "mode").flags, "on: held down")
	testing.expectf(t, abs(session.get(s, "mode").size.x - off_w) <= 0.5, "on: the same width (%v, off %v)", session.get(s, "mode").size.x, off_w)
	testing.expectf(t, abs(session.get(s, "next").rect.min.x - off_x) <= 0.5, "the next tool stays where it was")
}) }

// A screen reader hears a tool's whole name once, its count after its description, and a lit tool expanded.
@(test)
a_toolbar_tool_says_its_count_and_its_state :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {900, 200}, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.toolbar("abar", {overflow = .Fold}) {
			if ui.toolbar_group("g") {
				_ = ui.toolbar_tool("effort", {label = "Thinking: high", bar_label = "high", words = true, badge = 3})
				_ = ui.toolbar_tool("save", {label = "Save", words = true, shortcut = "Ctrl+S", badge = 4})
				_ = ui.toolbar_tool("agents", {label = "Subagents", icon = lucide.BOT, icon_font = ui.lucide_icons(), badge = 2})
				_ = ui.toolbar_tool("model", {label = "Model: Opus", bar_label = "Opus", words = true, lit = true})
			}
		}
	}})
	ui.a11y_capture(s.state, true)
	session.frames(s, 3)
	// (the tree a screen reader reads: the boxes' strings are the frame's, gone after it)
	tree := ui.a11y_tree(s.state)
	said :: proc(s: ^session.Session, name: string, kind: platform.A11y_Prop_Kind) -> string {
		i := ui.a11y_find(s.state, session.get(s, name).key)
		return i < 0 ? "<none>" : platform.a11y_node_string(ui.a11y_tree(s.state), i, kind)
	}
	testing.expect_value(t, said(s, "effort", .Label), "Thinking: high")
	testing.expect_value(t, said(s, "effort", .Description), "3")
	testing.expect_value(t, said(s, "save", .Description), "Save (Ctrl+S), 4")
	testing.expect_value(t, said(s, "agents", .Label), "Subagents")
	testing.expect_value(t, said(s, "agents", .Description), "2")
	testing.expect_value(t, said(s, "model", .Description), "")
	// (on a tool in words too, at its top right corner: its box is sized by its words)
	for name in ([]string{"effort", "save"}) {
		tool := session.get(s, name)
		pill := session.get(s, "badge_count", within = tool)
		// (inside its border, when it has one)
		testing.expectf(t, pill.rect.max.x <= tool.rect.max.x && tool.rect.max.x - pill.rect.max.x <= 3 && pill.rect.min.y >= tool.rect.min.y && pill.rect.min.y - tool.rect.min.y <= 3, "%s: its count at its top right corner (%v in %v)", name, pill.rect, tool.rect)
	}
	i := ui.a11y_find(s.state, session.get(s, "model").key)
	testing.expect(t, i >= 0 && .Has_Expanded in tree.nodes[i].flags && .Expanded in tree.nodes[i].flags, "lit: expanded")
}) }

// Animations off, a pulsing dot is still and asks for no wake.
@(test)
a_pulsing_dot_is_still_with_the_animations_off :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {600, 200}, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.toolbar("pbar", {overflow = .Fold}) {
			if ui.toolbar_group("g") { _ = ui.toolbar_tool("terminal", {label = "Terminal", icon = lucide.TERMINAL, icon_font = ui.lucide_icons(), dot = .Pulse}) }
		}
	}})
	session.frames(s, 3)
	disc := session.get(s, "badge_dot_disc")
	testing.expect(t, disc.bg.a == 1, "still: whole")
	testing.expect_value(t, ui.wake_ms(s.state), 0)
}) }
