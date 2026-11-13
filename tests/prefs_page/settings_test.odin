package prefs_page_test

// The common settings of every program (standard.odin) on the page: each set registers and applies (a changed value
// changes what the toolkit's getter says), the Advanced part folds, the sidebar's width is kept, a bounded number goes
// through ui.number, the user's themes file is made from its template and read back, Export writes JSON and Import reads
// our own format back; docs/settings.md lists every standard preference.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import config "../../src/config"
import "../../src/fsx"
import prefs_page "../../src/prefs_page"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file")
SETTINGS_DOC :: #load("../../docs/settings.md", string)

@(private = "file")
Common :: struct {
	prefs:   config.Prefs,
	page:    prefs_page.Page,
	watch:   prefs_page.Standard_Watch,
	changed: [dynamic]string,
	shown:   f64,   // the last value Page_Options.preview showed
	previews: int,
}

@(private = "file")
common_build :: proc(s: ^session.Session) {
	c := (^Common)(s.user)
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&c.page, &c.prefs, {user = c, changed = proc(user: rawptr, name: string) {
		append(&(^Common)(user).changed, strings.clone(name))
	}, preview = proc(user: rawptr, name: string, value: f64) {
		c := (^Common)(user)
		c.shown = value
		c.previews += 1
	}})
}

// `page`: the page shown first ("": the first one).
@(private = "file")
common_start :: proc(t: ^testing.T, c: ^Common, page := "", size := [2]int{1200, 800}) -> ^session.Session {
	c.prefs = config.prefs_make()
	d := prefs_page.STANDARD_DEFAULTS
	d.theme, d.app_name = "Midnight", "Sample"
	prefs_page.standard_register(&c.prefs, prefs_page.STANDARD_ALL, d, context.temp_allocator)
	if page != "" { c.page.current = strings.clone(page) }
	s := session.start(t, {size = size, build = common_build, user = c})
	prefs_page.standard_watch(&c.watch, &c.prefs, s.state)
	return s
}

@(private = "file")
common_end :: proc(c: ^Common) {
	prefs_page.standard_unwatch(&c.watch)
	prefs_page.destroy(&c.page)
	config.prefs_destroy(&c.prefs)
	for n in c.changed { delete(n) }
	delete(c.changed)
}

// Each set registers its preferences under its group, and a change of one reaches the toolkit's setter at once.
@(test)
every_standard_set_registers_and_applies :: proc(t: ^testing.T) {
	c: Common
	defer common_end(&c)
	s := common_start(t, &c)
	for prefix in ([]string{"appearance.", "appearance.text.", "window.", "scrolling.", "input.", "timing.", "rendering.", "update.", "general."}) {
		n := 0
		for e in c.prefs.entries { if strings.has_prefix(e.def.name, prefix) { n += 1 } }
		testing.expectf(t, n > 0, "the set of %s registers", prefix)
	}
	testing.expect_value(t, config.group_title(&c.prefs, "appearance.text"), "Text and fonts")
	st := s.state
	set :: proc(t: ^testing.T, c: ^Common, name, value: string) {
		testing.expectf(t, config.set_from_string(&c.prefs, name, value, .User) == .None, "%s = %s is taken", name, value)
	}
	set(t, &c, "appearance.density", "0.8");          testing.expect_value(t, ui.density(st), f32(0.8))
	set(t, &c, "appearance.zoom", "1.5");             testing.expect_value(t, ui.zoom(st), f32(1.5))
	set(t, &c, "appearance.rounding", "0");           testing.expect_value(t, st.rounding, f32(0))
	set(t, &c, "appearance.animations", "off");       testing.expect_value(t, ui.animations(st), ui.Animations.Off)
	set(t, &c, "window.toast_position", "bottom_left"); testing.expect_value(t, ui.toast_position(st), ui.Toast_Position.Bottom_Left)
	set(t, &c, "scrolling.smooth", "on");             testing.expect_value(t, ui.smooth_scroll(st), ui.Smooth_Scroll.On)
	set(t, &c, "scrolling.duration", "0");            testing.expect_value(t, ui.scroll_settings(st).duration_ms, f32(0))
	set(t, &c, "scrolling.curve", "ease_out");        testing.expect_value(t, ui.scroll_settings(st).curve, ui.Scroll_Curve.Ease_Out)
	set(t, &c, "scrolling.wheel_lines", "5");         testing.expect_value(t, ui.feel(st).wheel_lines, f32(5))
	set(t, &c, "scrolling.autohide_scrollbars", "true"); testing.expect(t, st.scrollbar_autohide, "the bars hide")
	set(t, &c, "scrolling.autoscroll.dead_zone", "20"); testing.expect_value(t, ui.autoscroll_settings(st).dead_zone, f32(20))
	set(t, &c, "input.key_repeat_rate", "30");        testing.expect_value(t, ui.feel(st).key_repeat_rate, 30)
	set(t, &c, "input.undo_steps", "50");             testing.expect_value(t, ui.feel(st).undo_steps, 50)
	set(t, &c, "input.step_alt", "0.5");              testing.expect_value(t, ui.feel(st).step_alt, 0.5)
	set(t, &c, "timing.tooltip_delay", "900");        testing.expect_value(t, ui.feel(st).tooltip_delay_ms, 900)
	set(t, &c, "timing.menu_item_height", "2.5");     testing.expect_value(t, ui.feel(st).menu_item_em, f32(2.5))
	set(t, &c, "rendering.partial_redraw", "true");   testing.expect(t, ui.partial_redraw(st), "partial redraw is on")
	// a reset puts the toolkit's default back
	config.reset(&c.prefs, "timing.tooltip_delay")
	testing.expect_value(t, ui.feel(st).tooltip_delay_ms, ui.FEEL_DEFAULT.tooltip_delay_ms)
	// the watch applies every standard preference: the user's, and the defaults too (a program's own default is its
	// Standard_Defaults.values, never a setter called beside the registry)
	ui.set_density(st, 1)
	ui.set_scrollbar_arrows(st, true)
	prefs_page.standard_unwatch(&c.watch)
	prefs_page.standard_watch(&c.watch, &c.prefs, st)
	testing.expect_value(t, ui.density(st), f32(0.8))
	testing.expect(t, !st.scrollbar_arrows, "the default applied")
}

// The advanced preferences of a page are under "Advanced", folded until a click.
@(test)
the_advanced_part_unfolds :: proc(t: ^testing.T) {
	c: Common
	defer common_end(&c)
	s := common_start(t, &c, "scrolling")
	testing.expect(t, session.find_text(s, "Smooth scrolling") != nil, "the page's own")
	testing.expect(t, session.find_text(s, "Middle-button scrolling") != nil, "an inner group under its title")
	testing.expect(t, session.find_text(s, "Advanced") != nil, "the Advanced part")
	testing.expect(t, session.find_text(s, "Glide curve") == nil, "folded")
	session.click(s, "accordion_header")
	session.frames(s, 4)
	testing.expect(t, session.find_text(s, "Glide curve") != nil, "unfolded by a click")
	testing.expect(t, c.page.unfolded["scrolling"], "the page keeps it open")
	// a search finds an advanced one wherever it is
	prefs_page.show(&c.page, &c.prefs, {}, "rendering.blur_sigma_limit")
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Blur limit") != nil, "found by a search")
}

// The sidebar is resized by its handle; its width is a preference, so a page made again has it.
@(test)
the_sidebar_width_is_kept :: proc(t: ^testing.T) {
	c: Common
	defer common_end(&c)
	s := common_start(t, &c)
	nav := session.get(s, "prefs_nav")
	before := nav.rect.max.x - nav.rect.min.x
	h := session.get(s, "prefs_split")
	from := [2]f32{(h.rect.min.x + h.rect.max.x) * 0.5, (h.rect.min.y + h.rect.max.y) * 0.5}
	session.drag(s, from, from + {120, 0})
	session.frames(s, 2)
	kept := config.float_of(&c.prefs, prefs_page.SIDEBAR_PREF)
	testing.expectf(t, kept > 14.5, "the width is kept: %v em", kept)
	nav = session.get(s, "prefs_nav")
	after := nav.rect.max.x - nav.rect.min.x
	testing.expectf(t, after > before + 60, "wider: %v from %v", after, before)
	prefs_page.destroy(&c.page)
	c.page = {}
	session.frames(s, 2)
	nav = session.get(s, "prefs_nav")
	testing.expectf(t, abs((nav.rect.max.x - nav.rect.min.x) - after) < 2, "a new page has it: %v", nav.rect.max.x - nav.rect.min.x)
	// a window too narrow for it: the sidebar takes no more than half of it, nothing goes past the window
	session.resize(s, {700, 600})
	session.frames(s, 3)
	nav = session.get(s, "prefs_nav")
	testing.expectf(t, nav.rect.max.x - nav.rect.min.x <= 351, "at most half: %v", nav.rect.max.x - nav.rect.min.x)
	body := session.get(s, "prefs_body")
	testing.expectf(t, body.rect.max.x <= 700, "the page stays in the window: %v", body.rect.max.x)
}

// A bounded number is a ui.number: its + button writes the next value at once.
@(test)
a_number_preference_steps :: proc(t: ^testing.T) {
	c: Common
	defer common_end(&c)
	s := common_start(t, &c)
	prefs_page.show(&c.page, &c.prefs, {}, "timing.tooltip_delay")
	session.frames(s, 2)
	testing.expect(t, session.find(s, "slider") != nil, "with its slider")
	session.click(s, "inc")
	testing.expect_value(t, config.int_of(&c.prefs, "timing.tooltip_delay"), 501)
	testing.expect_value(t, ui.feel(s.state).tooltip_delay_ms, 501)
	testing.expect(t, len(c.changed) > 0 && c.changed[len(c.changed) - 1] == "timing.tooltip_delay", "the program is told")
}

@(private = "file")
Themes :: struct {
	tf:   prefs_page.Themes_File,
	made: bool,   // (the task's answer)
}

// The user's themes file: the template a task writes has no theme (all of it is comments); a theme written in it is read
// back by the poll's task, after the program's.
@(test)
the_themes_file_is_made_and_read :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "tk_themes_file_*", context.temp_allocator)
	testing.expect(t, err == nil, "a temporary folder")
	defer fsx.remove_tree(dir)
	path := fmt.tprintf("%s/sub/themes.txt", dir)
	th: Themes
	prefs_page.themes_file_init(&th.tf, path, ui.THEMES[:4])
	defer prefs_page.themes_file_destroy(&th.tf)
	s := session.start(t, {user = &th, build = proc(s: ^session.Session) {
		th := (^Themes)(s.user)
		_ = prefs_page.themes_file_poll(&th.tf, s.state)
	}})
	ui.task(s.state, proc(d: rawptr) { _ = prefs_page.themes_file_write_template((^Themes)(d).tf.path) }, proc(d: rawptr, _: u64) { (^Themes)(d).made = true }, &th)
	session.wait_until(s, &th, proc(s: ^session.Session, th: ^Themes) -> bool { return th.made }, "the template written")
	data, ok := fsx.read_all(path, context.temp_allocator)
	testing.expect(t, ok && strings.has_prefix(string(data), "# Themes of your own"), "the template, made with its folder")
	testing.expect(t, strings.contains(string(data), "from = "), "it says how a theme starts from another")
	// (looked at again: the template holds no theme)
	th.tf.due_ms = 0
	serial := th.tf.serial
	session.wait_until(s, &th, proc(s: ^session.Session, th: ^Themes) -> bool { return !th.tf.busy && th.tf.due_ms > 0 }, "a poll")
	session.frames(s, 2)
	testing.expect_value(t, len(th.tf.all), 4)
	mine := strings.concatenate({string(data), "\n[My own]\nfrom = Midnight\naccent = #ff8800\n"}, context.temp_allocator)
	testing.expect(t, fsx.write_atomic(path, transmute([]u8)mine), "a theme written in it")
	th.tf.due_ms = 0
	th.tf.stamp = -1   // (the file system's clock may give the same time twice)
	session.wait_until(s, &th, proc(s: ^session.Session, th: ^Themes) -> bool { return len(th.tf.all) == 5 }, "the user's theme")
	testing.expect(t, th.tf.serial > serial, "a reload is counted")
	testing.expect_value(t, th.tf.all[4].name, "My own")
	testing.expect_value(t, th.tf.all[4].dark.hues[0], u32(0xff8800ff))
}

// Export writes the user's settings as JSON; our own format, imported, gives them back.
@(test)
export_and_import :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "tk_prefs_export_*", context.temp_allocator)
	testing.expect(t, err == nil, "a temporary folder")
	defer fsx.remove_tree(dir)
	c: Common
	defer common_end(&c)
	s := common_start(t, &c)
	config.set_from_string(&c.prefs, "appearance.density", "0.8", .User)
	json := fmt.tprintf("%s/settings.json", dir)
	own := fmt.tprintf("%s/settings.txt", dir)
	testing.expect_value(t, prefs_page.export_format_of(json), config.Export_Format.Json)
	testing.expect_value(t, prefs_page.export_format_of(own), config.Export_Format.Own)
	prefs_page.export_to(&c.page, json, .Json)
	session.wait_until(s, json, proc(s: ^session.Session, path: string) -> bool { return os.exists(path) }, "the JSON file")
	data, ok := fsx.read_all(json, context.temp_allocator)
	testing.expect(t, ok && strings.contains(string(data), `"appearance.density": 0.8`), string(data))
	prefs_page.export_to(&c.page, own, .Own)
	session.wait_until(s, own, proc(s: ^session.Session, path: string) -> bool { return os.exists(path) }, "our own file")
	config.reset(&c.prefs, "appearance.density")
	testing.expect_value(t, ui.density(s.state), f32(1))
	prefs_page.import_from(&c.page, own)
	session.wait_until(s, &c, proc(s: ^session.Session, c: ^Common) -> bool { return config.float_of(&c.prefs, "appearance.density") == 0.8 }, "the import")
	testing.expect_value(t, ui.density(s.state), f32(0.8))
	testing.expect(t, strings.has_prefix(c.page.note, "Imported"), c.page.note)
}

// docs/settings.md names every standard preference.
@(test)
the_settings_doc_lists_every_standard_preference :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	prefs_page.standard_register(&p, prefs_page.STANDARD_ALL, prefs_page.STANDARD_DEFAULTS, context.temp_allocator)
	for e in p.entries {
		testing.expectf(t, strings.contains(SETTINGS_DOC, fmt.tprintf("`%s`", e.def.name)), "docs/settings.md lists %s", e.def.name)
	}
}

// A number's slider held: each value it moves to is previewed, nothing is written until it is let go; then it is.
@(test)
a_held_number_is_previewed_then_written :: proc(t: ^testing.T) {
	c: Common
	defer common_end(&c)
	s := common_start(t, &c)
	prefs_page.show(&c.page, &c.prefs, {}, "appearance.rounding")
	session.frames(s, 2)
	sl := session.get(s, "slider", within = session.get(s, "set_appearance.rounding"))
	from := session.center(sl)
	to := [2]f32{sl.rect.min.x + 1, from.y}
	session.press(s, from)
	session.move(s, to)
	session.frames(s, 2)
	testing.expect(t, c.previews > 0 && c.shown < 0.2, "previewed while held")
	testing.expect_value(t, config.float_of(&c.prefs, "appearance.rounding"), 1)
	session.release(s, to)
	session.frames(s, 2)
	testing.expect(t, config.float_of(&c.prefs, "appearance.rounding") < 0.2, "written when let go")
}

// A program's own default for a standard setting: registered as the default, so a reset comes back to it.
@(test)
a_program_s_own_default_is_the_default :: proc(t: ^testing.T) {
	prefs := config.prefs_make()
	defer config.prefs_destroy(&prefs)
	d := prefs_page.STANDARD_DEFAULTS
	d.app_name = "Sample"
	own := []prefs_page.Standard_Value{{"appearance.rounding", "0.25"}, {"rendering.partial_redraw", "true"}}
	d.values = own
	prefs_page.standard_register(&prefs, prefs_page.STANDARD_ALL, d, context.temp_allocator)
	testing.expect_value(t, config.float_of(&prefs, "appearance.rounding"), 0.25)
	testing.expect_value(t, config.default_string(&prefs, config.ref_of(&prefs, "appearance.rounding")), "0.25")
	if config.ref_of(&prefs, "rendering.partial_redraw") != config.NO_REF { testing.expect(t, config.bool_of(&prefs, "rendering.partial_redraw")) }
}

// A page of the program's own: in the sidebar under its heading, built by the program under its title when chosen.
@(test)
a_program_s_own_page_is_in_the_sidebar :: proc(t: ^testing.T) {
	Own :: struct { c: Common, built: int }
	own: Own
	defer common_end(&own.c)
	own.c.prefs = config.prefs_make()
	d := prefs_page.STANDARD_DEFAULTS
	d.theme, d.app_name = "Midnight", "Sample"
	prefs_page.standard_register(&own.c.prefs, prefs_page.STANDARD_ALL, d, context.temp_allocator)
	s := session.start(t, {size = {1200, 800}, user = &own, build = proc(s: ^session.Session) {
		o := (^Own)(s.user)
		pages := []prefs_page.Page_Info{
			{category = "appearance", title = "Appearance", heading = "CLIENT"},
			{category = "server", title = "The server", heading = "SERVER", build = proc(user: rawptr, em: f32) {
				(^Own)(user).built += 1
				ui.label("Running###server_state")
			}},
		}
		ui.next({width = ui.fill(), height = ui.fill()})
		prefs_page.build(&o.c.page, &o.c.prefs, {user = o, pages = pages})
	}})
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "SERVER") != nil, "its heading")
	testing.expect_value(t, own.built, 0)
	session.click(s, "nav1")
	session.frames(s, 2)
	testing.expect(t, own.built > 0, "built when chosen")
	testing.expect(t, session.find(s, "server_state") != nil, "what it built")
}
