// The commands of a program (ui/commands.odin): their keys' texts, their keys, the palette and the sheet of the keys.
// Synthetic input events and builds, without a window; the ui state of a build is global: one test thread.
//   odin run tools/run_tests -- commands   (on Linux it needs the native text backend: tools/tk build_text)
package commands_test

import "core:testing"
import "../../src/font"
import "../../src/platform"
import "../../src/ui"

WINDOW :: ui.Vec2{800, 600}

Fx :: struct {
	fonts: font.State,
	theme: ui.Theme,
	s:     ui.State,
	base_font: font.Font_Id,
}

@(private = "file")
open :: proc(f: ^Fx) -> bool {
	font.init(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !ok { return false }
	ui.apply_palette(&f.theme, ui.palette_of("Midnight"))
	ui.init(&f.s, &f.fonts, &f.theme)
	f.base_font = id
	return true
}

@(private = "file")
close :: proc(f: ^Fx) {
	ui.destroy(&f.s)
	ui.theme_destroy(&f.theme)
	font.destroy(&f.fonts)
}

@(private = "file")
frame :: proc(f: ^Fx, events: []platform.Event, body: proc(f: ^Fx, user: rawptr), user: rawptr) {
	ui.begin_build(&f.s, {
		window_size = WINDOW, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
	})
	body(f, user)
	ui.end_build()
	free_all(context.temp_allocator)
}

@(private = "file")
key :: proc(k: platform.Key, mods: platform.Modifiers = {}) -> platform.Event { return {kind = .Key_Press, key = k, mods = mods} }

@(private = "file")
typed :: proc(r: rune) -> platform.Event { return {kind = .Text, text = r} }

@(private = "file")
PALETTE_COMMANDS := [?]ui.Command{
	{label = "End task", group = "Processes", keys = {{.Delete, {}}, {}}},
	{label = "Kill…", group = "Processes", keys = {{.Delete, {.Shift}}, {}}},
	{label = "Start", group = "Services", keys = {{.S, {.Ctrl}}, {}}},
	{label = "Command palette", group = "Window", keys = {{.K, {.Ctrl}}, {.P, {.Ctrl, .Shift}}}},
}

Palette_Run :: struct {
	key:     ui.Key,
	enabled: [len(PALETTE_COMMANDS)]bool,
	chosen:  int,
	pressed: [len(PALETTE_COMMANDS)]bool,
}

@(private = "file")
build_palette :: proc(f: ^Fx, user: rawptr) {
	r := (^Palette_Run)(user)
	if i := ui.palette(r.key, PALETTE_COMMANDS[:], r.enabled[:]); i >= 0 { r.chosen = i }
}

@(private = "file")
build_command_keys :: proc(f: ^Fx, user: rawptr) {
	r := (^Palette_Run)(user)
	for c, i in PALETTE_COMMANDS { r.pressed[i] = ui.command_pressed(c, r.enabled[i]) }
}

@(test)
command_texts :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.chord_text({.P, {.Ctrl, .Shift}}), "Ctrl+Shift+P")
	testing.expect_value(t, ui.chord_text({.Delete, {.Shift}}), "Shift+Delete")
	testing.expect_value(t, ui.chord_text({.F5, {}}), "F5")
	testing.expect_value(t, ui.chord_text({.N3, {.Ctrl}}), "Ctrl+3")
	testing.expect_value(t, ui.chord_text({.Return, {.Alt}}), "Alt+Enter")
	testing.expect_value(t, ui.chord_text({}), "")
	testing.expect_value(t, ui.command_shortcut(PALETTE_COMMANDS[1]), "Shift+Delete")
	testing.expect_value(t, ui.command_keys_text(PALETTE_COMMANDS[3]), "Ctrl+K, Ctrl+Shift+P")
	testing.expect_value(t, ui.command_tip(PALETTE_COMMANDS[1]), "Kill… (Shift+Delete)")
	testing.expect_value(t, ui.command_tip({label = "Open"}), "Open")
}

@(test)
command_keys_and_palette :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Palette_Run{key = ui.Key(0x9a1e77e), chosen = -1}
	r.enabled = {true, true, false, true}

	// a command's keys, and only when it can act
	frame(&f, {key(.Delete, {.Shift})}, build_command_keys, &r)
	testing.expect(t, !r.pressed[0] && r.pressed[1], "Shift+Delete is Kill's, not End task's")
	frame(&f, {key(.P, {.Ctrl, .Shift})}, build_command_keys, &r)
	testing.expect(t, r.pressed[3], "a command's second key")
	frame(&f, {key(.S, {.Ctrl})}, build_command_keys, &r)
	testing.expect(t, !r.pressed[2], "a command that cannot act takes no key")

	// the palette: typed letters keep the matches, Enter runs the first one that can act
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.palette_open((^Palette_Run)(user).key) }, &r)
	frame(&f, nil, build_palette, &r)
	frame(&f, nil, build_palette, &r)
	pr, sel, ok := ui.menu_rect(0)
	testing.expect(t, ok, "the palette is laid out")
	testing.expect(t, abs((pr.min.x + pr.max.x) * 0.5 - WINDOW.x * 0.5) < 2, "at the window's centre")
	testing.expect_value(t, sel, 0)
	for c in "kil" { frame(&f, {typed(c)}, build_palette, &r) }
	frame(&f, nil, build_palette, &r)
	frame(&f, {key(.Return)}, build_palette, &r)
	testing.expect_value(t, r.chosen, 1)
	testing.expect(t, !ui.ctx_menu_any_open(), "choosing closes the palette")

	// what cannot act is not chosen: "start" matches only Start, which is greyed
	r.chosen = -1
	frame(&f, nil, proc(f: ^Fx, user: rawptr) { ui.palette_open((^Palette_Run)(user).key) }, &r)
	frame(&f, nil, build_palette, &r)
	for c in "start" { frame(&f, {typed(c)}, build_palette, &r) }
	frame(&f, nil, build_palette, &r)
	frame(&f, {key(.Return)}, build_palette, &r)
	testing.expect_value(t, r.chosen, -1)
	frame(&f, {key(.Escape)}, build_palette, &r)
	testing.expect(t, !ui.ctx_menu_any_open(), "Escape closes it")
}

Sheet_Run :: struct { open: bool }

@(test)
shortcuts_sheet_lists_the_keys :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Sheet_Run{open = true}
	sheet :: proc(f: ^Fx, user: rawptr) { ui.shortcuts_sheet("keys", PALETTE_COMMANDS[:], &(^Sheet_Run)(user).open) }
	frame(&f, nil, sheet, &r)
	frame(&f, nil, sheet, &r)
	found := 0
	for _, b in f.s.boxes {
		if b == nil || b.last_build != f.s.build_index { continue }
		text := ui.box_text(b)
		if text == "Ctrl+K, Ctrl+Shift+P" || text == "Shift+Delete" { found += 1 }
	}
	testing.expect_value(t, found, 2)
	frame(&f, {key(.Escape)}, sheet, &r)
	frame(&f, nil, sheet, &r)   // (a dialog takes Escape at the end of a build: it closes at the next)
	testing.expect(t, !r.open, "Escape closes it")
}
