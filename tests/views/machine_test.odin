package views_test

// The machine of a view (ui.view_step), one row per transition of src/md/features/views.md, section 3.2, and the line of
// its memory (views_format, views_parse). Pure: no State, no window.

import "core:testing"
import "../../src/ui"

@(private = "file")
Row :: struct {
	name:  string,
	from:  ui.View_Machine,
	event: ui.View_Event,
	state: ui.View_State,
	as:    ui.View_Presentation,
	answer: Maybe(int),
	fx:    ui.View_Effects,
}

@(private = "file") RIGHT :: ui.View_Place{edge = .Right}
@(private = "file") LEFT :: ui.View_Place{edge = .Left}
@(private = "file") PROGRAM_CODE :: 3

// A machine in `state`, shown `as`, homed as a dialog (or a panel at the right with `panel_home`).
@(private = "file")
m :: proc(state: ui.View_State, as: ui.View_Presentation, from := ui.View_Presentation.Dialog, panel_home := false, answer: Maybe(int) = nil) -> ui.View_Machine {
	x := ui.View_Machine{state = state, as = as, from = from, answer = answer}
	if panel_home { x.home, x.home_place, x.place = .Panel, RIGHT, as == .Panel ? RIGHT : {} }
	return x
}

@(test)
every_transition_of_the_table :: proc(t: ^testing.T) {
	rows := [?]Row{
		{"closed: open as a dialog", m(.Closed, .Dialog, answer = 2), {kind = .Open, as = .Dialog}, .Opening, .Dialog, nil, {.Drop_Answer, .Keep_Focus}},
		{"closed: open as external opens its window", m(.Closed, .Dialog), {kind = .Open, as = .External}, .Opening, .External, nil, {.Drop_Answer, .Keep_Focus, .Open_Window}},
		{"opening: settled shows it", m(.Opening, .Dialog), {kind = .Settled}, .Shown, .Dialog, nil, {.Show}},
		{"shown: open again raises it", m(.Shown, .Internal), {kind = .Open, as = .Dialog}, .Shown, .Internal, nil, {.Raise}},
		{"opening: open again raises it", m(.Opening, .Dialog), {kind = .Open}, .Opening, .Dialog, nil, {.Raise}},
		{"shown: present moves it", m(.Shown, .Dialog), {kind = .Present, as = .Internal}, .Moving, .Internal, nil, {.Remember}},
		{"shown: present as external opens its window", m(.Shown, .Dialog), {kind = .Present, as = .External}, .Moving, .External, nil, {.Remember, .Open_Window}},
		{"opening: present opens it there", m(.Opening, .Dialog), {kind = .Present, as = .Internal}, .Opening, .Internal, nil, {.Remember}},
		{"opening: reattach opens it at home", m(.Opening, .Internal), {kind = .Reattach}, .Opening, .Dialog, nil, {.Remember}},
		{"dragged: a present waits for the drop", m(.Dragged, .Internal), {kind = .Present, as = .Panel, place = LEFT}, .Dragged, .Internal, nil, {}},
		{"dragged: a reattach waits for the drop", m(.Dragged, .Internal), {kind = .Reattach}, .Dragged, .Internal, nil, {}},
		{"moving: a drag does not start", m(.Moving, .Internal), {kind = .Drag_Start}, .Moving, .Internal, nil, {}},
		{"dragged: open again raises it", m(.Dragged, .Internal), {kind = .Open}, .Dragged, .Internal, nil, {.Raise}},
		{"shown: present where it is does nothing", m(.Shown, .Internal), {kind = .Present, as = .Internal}, .Shown, .Internal, nil, {}},
		{"shown: reattach goes home", m(.Shown, .Internal), {kind = .Reattach}, .Moving, .Dialog, nil, {.Remember}},
		{"shown at home: reattach does nothing", m(.Shown, .Dialog), {kind = .Reattach}, .Shown, .Dialog, nil, {}},
		{"moving: settled shows it there", m(.Moving, .Internal), {kind = .Settled}, .Shown, .Internal, nil, {.Show, .Retire_Old, .Carry_State}},
		{"moving: present again changes the target", m(.Moving, .Internal), {kind = .Present, as = .Panel, place = LEFT}, .Moving, .Panel, nil, {.Remember}},
		{"moving: reattach changes the target", m(.Moving, .External), {kind = .Reattach}, .Moving, .Dialog, nil, {.Remember}},
		{"shown: a dialog's drag leaves its scrim", m(.Shown, .Dialog), {kind = .Drag_Start}, .Dragged, .Internal, nil, {.Leave_Scrim}},
		{"shown: an external window's drag stays external", m(.Shown, .External), {kind = .Drag_Start}, .Dragged, .External, nil, {}},
		{"dragged: a drop docks it", m(.Dragged, .Internal), {kind = .Drop, as = .Panel, place = LEFT}, .Shown, .Panel, nil, {.Remember}},
		{"dragged: a drop outside opens a window", m(.Dragged, .Internal), {kind = .Drop_Outside}, .Moving, .External, nil, {.Remember, .Open_Window}},
		{"dragged: a cancel puts it back", m(.Dragged, .Internal, from = .Panel, panel_home = true), {kind = .Drag_Cancel}, .Shown, .Panel, nil, {}},
		{"opening: end gives the code", m(.Opening, .Dialog), {kind = .End, code = PROGRAM_CODE}, .Closed, .Dialog, PROGRAM_CODE, {.Close_Windows, .Give_Focus_Back}},
		{"shown: end gives the code", m(.Shown, .Internal), {kind = .End, code = PROGRAM_CODE}, .Closed, .Internal, PROGRAM_CODE, {.Close_Windows, .Give_Focus_Back}},
		{"moving: the user's close cancels", m(.Moving, .External), {kind = .User_Close}, .Closed, .External, ui.VIEW_CANCELLED, {.Close_Windows, .Give_Focus_Back}},
		{"dragged: the user's close cancels", m(.Dragged, .Internal), {kind = .User_Close}, .Closed, .Internal, ui.VIEW_CANCELLED, {.Close_Windows, .Give_Focus_Back}},
		{"shown: the program's close gives no answer", m(.Shown, .Dialog), {kind = .Program_Close}, .Closed, .Dialog, nil, {.Close_Windows, .Give_Focus_Back}},
		{"opening external: refused, internal", m(.Opening, .External), {kind = .Window_Refused}, .Opening, .Internal, nil, {.Announce_Refused}},
		{"moving to external: refused, back where it was", m(.Moving, .External, from = .Internal), {kind = .Window_Refused}, .Shown, .Internal, nil, {.Announce_Refused, .Remember}},
		{"opening a dialog: a refusal is not its", m(.Opening, .Dialog), {kind = .Window_Refused}, .Opening, .Dialog, nil, {}},
		{"shown: its owner gone cancels", m(.Shown, .Dialog), {kind = .Owner_Gone}, .Closed, .Dialog, ui.VIEW_CANCELLED, {.Close_Windows, .Give_Focus_Back}},
		{"shown: quit says it was open", m(.Shown, .Panel, panel_home = true), {kind = .Quit}, .Closed, .Panel, nil, {.Close_Windows, .Was_Open}},
		{"closed: quit drops the answer", m(.Closed, .Dialog, answer = 1), {kind = .Quit}, .Closed, .Dialog, nil, {.Close_Windows}},
		{"closed: settled does nothing", m(.Closed, .Dialog, answer = 1), {kind = .Settled}, .Closed, .Dialog, 1, {}},
		{"closed: end does nothing", m(.Closed, .Dialog), {kind = .End, code = PROGRAM_CODE}, .Closed, .Dialog, nil, {}},
		{"opening: a drag does not start", m(.Opening, .Dialog), {kind = .Drag_Start}, .Opening, .Dialog, nil, {}},
		{"shown: a drop without a drag does nothing", m(.Shown, .Dialog), {kind = .Drop, as = .Panel}, .Shown, .Dialog, nil, {}},
		// (the External presentation: its window shows, the system closes it, a drag of it docks it)
		{"moving to external: its first frame shows it there", m(.Moving, .External, from = .Dialog), {kind = .Settled}, .Shown, .External, nil, {.Show, .Retire_Old, .Carry_State}},
		{"opening external: its first frame shows it", m(.Opening, .External), {kind = .Settled}, .Shown, .External, nil, {.Show}},
		{"shown external: the system's close re-attaches", m(.Shown, .External), {kind = .Reattach}, .Moving, .Dialog, nil, {.Remember}},
		{"moving from external: settled shows it at home", m(.Moving, .Dialog, from = .External), {kind = .Settled}, .Shown, .Dialog, nil, {.Show, .Retire_Old, .Carry_State}},
		{"dragged external: a drop on a target docks it", m(.Dragged, .External, from = .External), {kind = .Drop, as = .Panel, place = LEFT}, .Shown, .Panel, nil, {.Remember}},
		{"dragged external: a drop elsewhere keeps it", m(.Dragged, .External, from = .External), {kind = .Drop, as = .External}, .Shown, .External, nil, {.Remember}},
		{"dragged external: a cancel keeps it", m(.Dragged, .External, from = .External), {kind = .Drag_Cancel}, .Shown, .External, nil, {}},
		{"shown external: present as a panel moves it", m(.Shown, .External), {kind = .Present, as = .Panel, place = LEFT}, .Moving, .Panel, nil, {.Remember}},
	}
	for r in rows {
		next, fx := ui.view_step(r.from, r.event)
		testing.expectf(t, next.state == r.state, "%s: the state is %v, not %v", r.name, next.state, r.state)
		testing.expectf(t, next.as == r.as, "%s: it is %v, not %v", r.name, next.as, r.as)
		testing.expectf(t, next.answer == r.answer, "%s: the answer is %v, not %v", r.name, next.answer, r.answer)
		testing.expectf(t, fx == r.fx, "%s: the effects are %v, not %v", r.name, fx, r.fx)
	}
}

// Reattach brings a panel homed at the right back there, and a drop remembers the place.
@(test)
reattach_takes_the_home_place :: proc(t: ^testing.T) {
	x := m(.Shown, .Panel, panel_home = true)
	x.place = LEFT
	next, fx := ui.view_step(x, {kind = .Reattach})
	testing.expect_value(t, next.state, ui.View_State.Moving)
	testing.expect_value(t, next.as, ui.View_Presentation.Panel)
	testing.expect_value(t, next.place, RIGHT)
	testing.expect(t, .Remember in fx)
	next, _ = ui.view_step(next, {kind = .Settled})
	testing.expect_value(t, next.state, ui.View_State.Shown)
	_, fx = ui.view_step(next, {kind = .Reattach})
	testing.expect_value(t, fx, ui.View_Effects{})
}

@(test)
the_memory_line_round_trips :: proc(t: ^testing.T) {
	want := ui.View_Memory{as = .External, open = true, dialog = {58, 40}, internal = {120, 80, 700, 480}, window = {1180, 760}, at = [2]int{212, -96}, dock = ui.View_Dock_Memory{place = {space = "mission", edge = .Bottom}, extent_em = 18}}
	text := ui.views_format(want)
	got, ok := ui.views_parse(text)
	testing.expect(t, ok, text)
	testing.expect_value(t, got.as, want.as)
	testing.expect_value(t, got.open, true)
	testing.expect_value(t, got.dialog, want.dialog)
	testing.expect_value(t, got.internal, want.internal)
	testing.expect_value(t, got.window, want.window)
	at, at_ok := got.at.?
	testing.expect(t, at_ok && at == [2]int{212, -96}, "the window's place")
	d, has := got.dock.?
	testing.expect(t, has)
	testing.expect_value(t, d.place.space, "mission")
	testing.expect_value(t, d.place.edge, ui.View_Edge.Bottom)
	testing.expect_value(t, d.extent_em, 18)

	// (a size in ems that has no short decimal comes back the same: one decimal reopened a dialog of 400 px at 401)
	exact := ui.View_Memory{dialog = ui.Vec2{500, 400} / 15, dock = ui.View_Dock_Memory{place = {space = "mission", edge = .Left}, extent_em = f32(250) / 15}}
	back, back_ok := ui.views_parse(ui.views_format(exact))
	testing.expect(t, back_ok)
	testing.expect_value(t, back.dialog, exact.dialog)
	if bd, bd_ok := back.dock.?; testing.expect(t, bd_ok, "the dock comes back") { testing.expect_value(t, bd.extent_em, f32(250) / 15) }

	// (the defaults write nothing but the version and `open`)
	testing.expect_value(t, ui.views_format({}), "v1 open=0")
	empty, eok := ui.views_parse("v1 open=0")
	testing.expect(t, eok)
	testing.expect(t, empty.as == nil && empty.dock == nil && empty.dialog == {} && empty.at == nil)
}

@(test)
a_memory_line_that_does_not_parse_is_refused :: proc(t: ^testing.T) {
	for text in ([]string{"", "v2 as=dialog", "v1 as=window", "v1 open=2", "v1 dialog=12", "v1 dialog=0x3", "v1 internal=1,2,3", "v1 window=10x-2", "v1 dock=:sideways:3", "v1 noequals"}) {
		_, ok := ui.views_parse(text)
		testing.expectf(t, !ok, "%q is refused", text)
	}
	// (a field of a name it does not know is skipped)
	line, ok := ui.views_parse("v1 as=panel later=1")
	testing.expect(t, ok)
	testing.expect_value(t, line.as, ui.View_Presentation.Panel)
}
