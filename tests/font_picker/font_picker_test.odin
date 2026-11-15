// The font picker (ui.font_picker, docs/font-picker.md) over a fake source: no system read. What breaks first: the list
// read at each opening; every family's face asked at once; a ranking at each frame; the monospace families lost from
// the mono list; the default shown empty.
//   odin test tests/font_picker -collection:gt=src -vet -define:ODIN_TEST_THREADS=1 (Linux: -define:FONT_BACKEND=native)
package font_picker_test

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "gt:font"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") BOUND :: 20 * time.Second

// The fake system: these families (a few marked monospace), or `many` more after them; no face found.
@(private = "file")
Fake :: struct {
	many:  int,
	faces: int,   // the faces asked (atomic: the chores ask)
}

@(private = "file", rodata)
FAMILIES := [?]font.Family{{name = "Alpha Sans"}, {name = "Beta Mono", monospace = true}, {name = "Delta Code", monospace = true}, {name = "Gamma Serif"}}

@(private = "file")
fake_source :: proc(f: ^Fake) -> ui.Font_Source {
	return {
		user = f,
		families = proc(user: rawptr, allocator: mem.Allocator) -> []font.Family {
			f := (^Fake)(user)
			out := make([]font.Family, len(FAMILIES) + f.many, allocator)
			for x, i in FAMILIES { out[i] = {name = strings.clone(x.name, allocator), monospace = x.monospace} }
			for i in 0 ..< f.many { out[len(FAMILIES) + i] = {name = fmt.aprintf("Zeta %03d", i, allocator = allocator)} }
			return out
		},
		face = proc(user: rawptr, family: string) -> font.Font_Id {
			sync.atomic_add(&(^Fake)(user).faces, 1)
			return 0
		},
	}
}

@(private = "file")
App :: struct {
	fake:     Fake,
	families: ui.Font_Families,
	picker:   ui.Font_Picker,
	value:    string,   // (heap)
	mono:     bool,
	chosen:   [dynamic]string,
	default_face: font.Font_Id,
}

@(private = "file")
build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	ui.next({width = ui.px(300)})
	if v, ok := ui.font_picker("###picker", &app.picker, &app.families, app.value, {default_face = app.default_face, monospace = app.mono}).?; ok {
		a := runtime.heap_allocator()
		append(&app.chosen, strings.clone(v, a))
		delete(app.value, a)
		app.value = strings.clone(v, a)
	}
}

@(private = "file")
start :: proc(t: ^testing.T, app: ^App, value := "", mono := false, many := 0) -> ^session.Session {
	a := runtime.heap_allocator()
	app.value, app.mono, app.fake.many = strings.clone(value, a), mono, many
	app.families.source = fake_source(&app.fake)
	app.chosen.allocator = a
	s := session.start(t, {build = build, user = app, size = {700, 600}})
	app.default_face = s.own.ui_font
	session.frames(s, 2)
	return s
}

@(private = "file")
app_destroy :: proc(app: ^App) {
	a := runtime.heap_allocator()
	ui.font_picker_destroy(&app.picker)
	ui.font_families_destroy(&app.families)
	for c in app.chosen { delete(c, a) }
	delete(app.chosen)
	delete(app.value, a)
}

@(private = "file")
open :: proc(s: ^session.Session, app: ^App) {
	session.click(s, "picker")
	session.wait_until(s, proc(s: ^session.Session) -> bool { return (^App)(s.user).families.reading == .Ready }, "the families", BOUND)
	session.frames(s, 3)
}

// The kinds and names of the rows, as they are now ("Default", a family's name, "-" for the heading).
@(private = "file")
row_names :: proc(app: ^App) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for r in app.picker.rows {
		switch r.kind {
		case .Default: append(&out, "Default")
		case .Heading: append(&out, "-")
		case .Family:  append(&out, app.families.list[r.index].name)
		}
	}
	return out[:]
}

// Closed, the button names the default's family: never an empty field.
@(test)
the_default_is_named :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app)
	family := font.family_of(&s.own.fonts, s.own.ui_font)
	testing.expect(t, family != "", "the interface's face names its family")
	testing.expect(t, session.find_text(s, ui.font_default_label(family)) != nil, "the button shows the family in use, marked as the default")
	testing.expect_value(t, app.families.reads, 0)   // (nothing read before an opening)
}

// The embedded faces say their families from their name tables.
@(test)
a_face_says_its_family :: proc(t: ^testing.T) {
	fonts: font.State
	font.init(&fonts)
	defer font.destroy(&fonts)
	ui_face, ok := font.load_embedded(&fonts, font.FALLBACK_UI_DATA)
	if testing.expect(t, ok, "Roboto") { testing.expect_value(t, font.family_of(&fonts, ui_face), "Roboto") }
	mono, ok2 := font.load_embedded(&fonts, font.FALLBACK_MONO_DATA)
	if testing.expect(t, ok2, "Inconsolata") { testing.expect_value(t, font.family_of(&fonts, mono), "Inconsolata") }
	testing.expect_value(t, font.family_of(&fonts, 0), "")
}

// Opened: Default first, then the source's families, the monospace ones marked; the default is the one selected.
@(test)
the_families_are_listed :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app)
	open(s, &app)
	names := row_names(&app)
	if testing.expect_value(t, len(names), 5) {
		testing.expect_value(t, names[0], "Default")
		testing.expect_value(t, names[1], "Alpha Sans")
		testing.expect_value(t, names[4], "Gamma Serif")
	}
	testing.expect_value(t, app.picker.vl.sel, 0)
	testing.expect(t, session.find_text(s, "Beta Mono") != nil, "a family's row")
	testing.expect(t, session.find_text(s, "monospace") != nil, "a monospace family is marked")
	testing.expect(t, ui.focus_key_of(s.state) == app.picker.field_key, "the search field has the keyboard")
}

// The search narrows the list, the best one selected: Enter chooses it, and the picker closes.
@(test)
a_search_finds_and_enter_chooses :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app)
	open(s, &app)
	session.type_text(s, "gamser")
	session.frames(s, 2)
	names := row_names(&app)
	if testing.expect_value(t, len(names), 1) { testing.expect_value(t, names[0], "Gamma Serif") }
	ranked := app.picker.ranked
	session.frames(s, 5)
	testing.expect_value(t, app.picker.ranked, ranked)   // (a quiet build ranks nothing)
	session.key(s, .Return)
	if testing.expect_value(t, len(app.chosen), 1) { testing.expect_value(t, app.chosen[0], "Gamma Serif") }
	testing.expect(t, !app.picker.open, "closed after the choice")
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Gamma Serif") != nil, "the button shows the family chosen")
}

// Down moves in the list from the field; Default chooses "".
@(test)
the_keys_move_and_default_chooses_empty :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app, value = "Alpha Sans")
	open(s, &app)
	testing.expect_value(t, app.picker.vl.sel, 1)   // (the current family, selected at the opening)
	session.key(s, .Down)
	testing.expect_value(t, app.picker.vl.sel, 2)
	session.key(s, .Up)
	session.key(s, .Up)
	testing.expect_value(t, app.picker.vl.sel, 0)
	session.key(s, .Return)
	if testing.expect_value(t, len(app.chosen), 1) { testing.expect_value(t, app.chosen[0], "") }
}

// The mono setting: the monospace families first, the others after them under a heading, none lost.
@(test)
monospace_first :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app, mono = true)
	open(s, &app)
	names := row_names(&app)
	want := []string{"Default", "Beta Mono", "Delta Code", "-", "Alpha Sans", "Gamma Serif"}
	if testing.expect_value(t, len(names), len(want)) {
		for w, i in want { testing.expectf(t, names[i] == w, "row %d: %s, not %s", i, names[i], w) }
	}
	testing.expect(t, session.find_text(s, "Other families") != nil, "the heading")
}

// Escape closes, nothing chosen; the list is read once whatever the openings.
@(test)
escape_closes_and_the_list_is_read_once :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app)
	open(s, &app)
	session.key(s, .Escape)
	session.frames(s, 2)
	testing.expect(t, !app.picker.open, "closed")
	testing.expect_value(t, len(app.chosen), 0)
	open(s, &app)
	testing.expect(t, app.picker.open, "open again")
	testing.expect_value(t, app.families.reads, 1)
}

// A long list builds the rows in view, and asks only their faces.
@(test)
only_the_rows_in_view_ask_their_faces :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app, many = 500)
	open(s, &app)
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		app := (^App)(s.user)
		return !app.families.loading && sync.atomic_load(&app.fake.faces) > 0
	}, "the first faces", BOUND)
	session.frames(s, 20)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !(^App)(s.user).families.loading }, "the batches", BOUND)
	testing.expect_value(t, len(app.picker.rows), 505)
	asked := sync.atomic_load(&app.fake.faces)
	testing.expectf(t, asked > 0 && asked < 100, "the faces of the rows in view, not of the 504 families: %d", asked)
	testing.expect_value(t, asked, app.families.asked)
}
