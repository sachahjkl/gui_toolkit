#+build windows
package a11y_test

// A real window read through UI Automation, as a screen reader reads it (only with -define:A11Y_ACCESSKIT=true, after
// tools\build_a11y.ps1): a client on a thread of its own finds the widgets by control type and name, reads their
// states and values, then invokes, toggles, sets values, selects and focuses them, and sees the window answer. The
// window is never shown.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../../platform"
import "../../tools/uia"
import "../../ui"

_ :: runtime
_ :: fmt
_ :: strings
_ :: sync
_ :: testing
_ :: thread
_ :: time
_ :: platform
_ :: uia
_ :: ui

when #config(A11Y_ACCESSKIT, false) {

Uia_App :: struct {
	using app: App,
	label:     [32]u8,
}

Uia_Shared :: struct {
	hwnd:   rawptr,
	done:   bool,          // atomic
	steps:  [dynamic]string,   // what the client checked, "ok ..." or "FAIL ..."
	dump:   [dynamic]string,   // the elements it saw first
	allocator: runtime.Allocator,   // the test's (tracked): what the client keeps is freed by the test
}

uia_body :: proc(a: ^Uia_App) {
	body(&a.app)
	ui.next({width = ui.px(300), height = ui.px(30)})
	ui.label(fmt.bprintf(a.label[:], "Clicks: %d###clicks", a.clicks))
}

@(private = "file")
find :: proc(c: ^uia.Client, root: ^uia.Element, ct: uia.Control, name: string) -> ^uia.Element {
	els := uia.descendants(c, root)
	defer delete(els)
	found: ^uia.Element
	for e in els {
		if found == nil && uia.control(e) == ct && uia.name(e, context.temp_allocator) == name { found = e; continue }
		uia.drop(e)
	}
	return found
}

// Waits (pumping nothing: the window's thread does) until `cond` holds, 10 s at most.
@(private = "file")
wait_for :: proc(c: ^uia.Client, root: ^uia.Element, cond: proc(c: ^uia.Client, root: ^uia.Element) -> bool) -> bool {
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < 10 {
		if cond(c, root) { return true }
		time.sleep(20 * time.Millisecond)
	}
	return false
}

@(private = "file")
step :: proc(sh: ^Uia_Shared, ok: bool, what: string) {
	append(&sh.steps, fmt.aprintf("%s %s", ok ? "ok" : "FAIL", what))
}

@(private = "file")
client :: proc(sh: ^Uia_Shared) {
	context.allocator = sh.allocator
	defer sync.atomic_store(&sh.done, true)
	defer free_all(context.temp_allocator)
	c, ok := uia.open()
	if !ok { step(sh, false, "UI Automation could not start"); return }
	defer uia.close(&c)
	root := uia.from_window(&c, sh.hwnd)
	if root == nil { step(sh, false, "no element for the window"); return }
	defer uia.drop(root)

	// the tree comes with the frame that answers the first question (a placeholder until then)
	step(sh, wait_for(&c, root, proc(c: ^uia.Client, root: ^uia.Element) -> bool {
		e := find(c, root, .Button, "Save")
		defer uia.drop(e)
		return e != nil
	}), "the tree arrives")
	els := uia.descendants(&c, root)
	for e in els { append(&sh.dump, uia.describe(e)) }
	uia.drop_all(els)

	check :: proc(sh: ^Uia_Shared, c: ^uia.Client, root: ^uia.Element, ct: uia.Control, name: string) -> ^uia.Element {
		e := find(c, root, ct, name)
		step(sh, e != nil, fmt.tprintf("%v \"%s\" is there", ct, name))
		return e
	}
	back := check(sh, &c, root, .Button, "Go back")
	uia.drop(back)
	save := check(sh, &c, root, .Button, "Save")
	wrap := check(sh, &c, root, .Check_Box, "Wrap lines")
	tab2 := check(sh, &c, root, .Tab_Item, "Two")
	hello := check(sh, &c, root, .Text, "Hello")
	uia.drop(hello)
	pears := check(sh, &c, root, .List_Item, "Pears")
	defer { uia.drop(save); uia.drop(wrap); uia.drop(tab2); uia.drop(pears) }
	if save == nil || wrap == nil || tab2 == nil { return }

	step(sh, uia.toggle_state(wrap) == 0, "the check box is unchecked")
	step(sh, uia.is_selected(tab2) == 0, "tab Two is not selected")

	// the field and the slider: found by type (their names come from the app, none here)
	all := uia.descendants(&c, root)
	edit, slider: ^uia.Element
	for e in all {
		#partial switch uia.control(e) {
		case .Edit:   if edit == nil { edit = e; continue }
		case .Slider: if slider == nil { slider = e; continue }
		}
		uia.drop(e)
	}
	delete(all)
	defer { uia.drop(edit); uia.drop(slider) }
	step(sh, edit != nil, "a field is there")
	step(sh, slider != nil, "a slider is there")
	if edit != nil {
		v, vok := uia.value(edit, context.temp_allocator)
		step(sh, vok && v == "Ada", fmt.tprintf("the field says \"%s\"", v))
	}
	if slider != nil {
		r, rok := uia.range_value(slider)
		step(sh, rok && r == 40, fmt.tprintf("the slider is at %v", r))
	}

	// actions: the window answers them as clicks, values, selection and focus
	step(sh, uia.invoke(save), "invoke Save")
	step(sh, wait_for(&c, root, proc(c: ^uia.Client, root: ^uia.Element) -> bool {
		e := find(c, root, .Text, "Clicks: 1")
		defer uia.drop(e)
		return e != nil
	}), "Save was clicked")
	step(sh, uia.toggle(wrap), "toggle the check box")
	step(sh, wait_for(&c, root, proc(c: ^uia.Client, root: ^uia.Element) -> bool {
		e := find(c, root, .Check_Box, "Wrap lines")
		defer uia.drop(e)
		return e != nil && uia.toggle_state(e) == 1
	}), "the check box is checked")
	if edit != nil {
		step(sh, uia.set_value(edit, "Grace"), "set the field's value")
		step(sh, wait_for(&c, root, proc(c: ^uia.Client, root: ^uia.Element) -> bool {
			all := uia.descendants(c, root)
			defer uia.drop_all(all)
			for e in all { if uia.control(e) == .Edit { v, _ := uia.value(e, context.temp_allocator); return v == "Grace" } }
			return false
		}), "the field says Grace")
	}
	if slider != nil {
		step(sh, uia.set_range_value(slider, 70), "set the slider")
		step(sh, wait_for(&c, root, proc(c: ^uia.Client, root: ^uia.Element) -> bool {
			all := uia.descendants(c, root)
			defer uia.drop_all(all)
			for e in all { if uia.control(e) == .Slider { r, _ := uia.range_value(e); return r == 70 } }
			return false
		}), "the slider is at 70")
	}
	step(sh, uia.select(tab2), "select tab Two")
	step(sh, wait_for(&c, root, proc(c: ^uia.Client, root: ^uia.Element) -> bool {
		e := find(c, root, .Tab_Item, "Two")
		defer uia.drop(e)
		return e != nil && uia.is_selected(e) == 1
	}), "tab Two is selected")
	if pears != nil {
		step(sh, uia.select(pears), "select the row Pears")
		step(sh, wait_for(&c, root, proc(c: ^uia.Client, root: ^uia.Element) -> bool {
			e := find(c, root, .List_Item, "Pears")
			defer uia.drop(e)
			return e != nil && uia.is_selected(e) == 1
		}), "Pears is selected")
	}
	step(sh, uia.set_focus(wrap), "focus the check box")
	step(sh, wait_for(&c, root, proc(c: ^uia.Client, root: ^uia.Element) -> bool {
		e := find(c, root, .Check_Box, "Wrap lines")
		defer uia.drop(e)
		return e != nil && uia.has_focus(e)
	}), "the check box has the focus")
}

@(test)
read_by_ui_automation :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	a: Uia_App
	defer app_destroy(&a.app)
	ui.field_set(&a.field, "Ada")
	a.volume = 40
	testing.expect(t, platform.a11y_available(), "built with the adapter")

	w := platform.open_window("a11y test", {700, 700})
	if !testing.expect(t, w != nil, "a window") { return }
	defer platform.destroy_window(w)
	sh := Uia_Shared{hwnd = rawptr(w.hwnd), allocator = context.allocator}
	defer {
		for s in sh.steps { delete(s) }
		delete(sh.steps)
		for s in sh.dump { delete(s) }
		delete(sh.dump)
	}
	th := thread.create_and_start_with_poly_data(&sh, client)
	start := time.tick_now()
	frames := 0
	for !sync.atomic_load(&sh.done) && time.duration_seconds(time.tick_since(start)) < 60 {
		events := platform.poll_events(w, true, 15)
		ui.begin_build(&f.s, {
			window_size = {f32(w.size.x), f32(w.size.y)}, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1, window = w,
			base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
		})
		uia_body(&a)
		ui.end_build()
		free_all(context.temp_allocator)
		frames += 1
	}
	thread.join(th)
	thread.destroy(th)
	updates, refused, _ := ui.a11y_stats(&f.s)
	log_lines := strings.join(sh.dump[:], "\n", context.temp_allocator)
	testing.expectf(t, len(sh.steps) > 0, "the client ran (%d frames)", frames)
	for s in sh.steps { testing.expectf(t, strings.has_prefix(s, "ok"), "%s\nthe elements:\n%s", s, log_lines) }
	when #config(A11Y_TEST_VERBOSE, false) { fmt.printf("%d frames\n%s\n\n%s\n", frames, strings.join(sh.steps[:], "\n", context.temp_allocator), log_lines) }
	testing.expect(t, updates > 0, "updates went to the adapter")
	testing.expect_value(t, refused, 0)
}


// Two windows of one thread, a State each: each is read on its own (its own widgets, not the other's), a request on one
// reaches that one only, and a window a reader has read stays quiet at rest (no wake, no update while nothing changes).
Two_Shared :: struct {
	hwnd:      [2]rawptr,
	done:      bool,   // atomic
	resting:   bool,   // atomic: the client asks nothing meanwhile
	steps:     [dynamic]string,
	allocator: runtime.Allocator,
}

Two_App :: struct {
	name:   string,
	clicks: int,
	label:  [32]u8,
}

@(private = "file")
two_body :: proc(a: ^Two_App) {
	ui.next({width = ui.px(200), height = ui.px(30)})
	if ui.button(fmt.tprintf("%s###b", a.name)).clicked { a.clicks += 1 }
	ui.next({width = ui.px(200), height = ui.px(30)})
	ui.label(fmt.bprintf(a.label[:], "%s: %d###n", a.name, a.clicks))
}

@(private = "file")
two_client :: proc(sh: ^Two_Shared) {
	context.allocator = sh.allocator
	defer sync.atomic_store(&sh.done, true)
	defer free_all(context.temp_allocator)
	c, ok := uia.open()
	if !ok { step2(sh, false, "UI Automation could not start"); return }
	defer uia.close(&c)
	roots := [2]^uia.Element{uia.from_window(&c, sh.hwnd[0]), uia.from_window(&c, sh.hwnd[1])}
	defer { uia.drop(roots[0]); uia.drop(roots[1]) }
	if roots[0] == nil || roots[1] == nil { step2(sh, false, "no element for a window"); return }
	names := [2]string{"One", "Two"}
	for k in 0 ..< 2 {
		start := time.tick_now()
		e: ^uia.Element
		for e == nil && time.duration_seconds(time.tick_since(start)) < 10 {
			e = find(&c, roots[k], .Button, names[k])
			if e == nil { time.sleep(20 * time.Millisecond) }
		}
		step2(sh, e != nil, fmt.tprintf("window %d has its button %s", k + 1, names[k]))
		uia.drop(e)
		other := find(&c, roots[k], .Button, names[1 - k])
		step2(sh, other == nil, fmt.tprintf("window %d has not the other's", k + 1))
		uia.drop(other)
	}
	sync.atomic_store(&sh.resting, true)
	time.sleep(600 * time.Millisecond)
	sync.atomic_store(&sh.resting, false)
	two := find(&c, roots[1], .Button, "Two")
	defer uia.drop(two)
	step2(sh, two != nil && uia.invoke(two), "invoke Two")
	start := time.tick_now()
	got: ^uia.Element
	for got == nil && time.duration_seconds(time.tick_since(start)) < 10 {
		got = find(&c, roots[1], .Text, "Two: 1")
		if got == nil { time.sleep(20 * time.Millisecond) }
	}
	step2(sh, got != nil, "window 2 counted the click")
	uia.drop(got)
	one := find(&c, roots[0], .Text, "One: 0")
	step2(sh, one != nil, "window 1 did not")
	uia.drop(one)
}

@(private = "file")
step2 :: proc(sh: ^Two_Shared, ok: bool, what: string) {
	append(&sh.steps, fmt.aprintf("%s %s", ok ? "ok" : "FAIL", what))
}

@(test)
two_windows_read_apart :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	fx: [2]Fx
	apps := [2]Two_App{{name = "One"}, {name = "Two"}}
	wins: [2]^platform.Window
	for k in 0 ..< 2 {
		if !testing.expect(t, open(&fx[k]), "fonts") { return }
		wins[k] = platform.open_window(fmt.tprintf("a11y window %d", k + 1), {400, 300})
		if !testing.expect(t, wins[k] != nil, "a window") { return }
	}
	defer for k in 0 ..< 2 { platform.destroy_window(wins[k]); close(&fx[k]) }
	sh := Two_Shared{hwnd = {rawptr(wins[0].hwnd), rawptr(wins[1].hwnd)}, allocator = context.allocator}
	defer { for s in sh.steps { delete(s) }; delete(sh.steps) }
	th := thread.create_and_start_with_poly_data(&sh, two_client)
	start := time.tick_now()
	rest_events, rest_updates, rest_frames := 0, 0, 0
	for !sync.atomic_load(&sh.done) && time.duration_seconds(time.tick_since(start)) < 60 {
		resting := sync.atomic_load(&sh.resting)
		for k in 0 ..< 2 {
			events := platform.poll_events(wins[k], k == 0, 15)
			before, _, _ := ui.a11y_stats(&fx[k].s)
			ui.begin_build(&fx[k].s, {
				window_size = {f32(wins[k].size.x), f32(wins[k].size.y)}, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1, window = wins[k],
				base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = fx[k].base_font, font_size = 15, text_pad = 6},
			})
			two_body(&apps[k])
			ui.end_build()
			free_all(context.temp_allocator)
			after, _, _ := ui.a11y_stats(&fx[k].s)
			if resting && sync.atomic_load(&sh.resting) {
				rest_frames += 1
				rest_events += len(events)
				rest_updates += after - before
			}
		}
	}
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, len(sh.steps) > 0, "the client ran")
	for s in sh.steps { testing.expectf(t, strings.has_prefix(s, "ok"), "%s", s) }
	testing.expectf(t, rest_frames > 0 && rest_events == 0 && rest_updates == 0, "at rest: %d events, %d updates in %d frames", rest_events, rest_updates, rest_frames)
	for k in 0 ..< 2 {
		_, refused, _ := ui.a11y_stats(&fx[k].s)
		testing.expect_value(t, refused, 0)
	}
}
}
