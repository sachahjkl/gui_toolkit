package showcase

// The steppers' scene: an installer's list, one horizontal stepper per program, labels below; a release as a vertical
// stepper, labels after; every state, a label in a colour of its own, numbers, labels above, the compact form.

import "core:fmt"
import "core:math"
import lucide "gt:lucide"
import "gt:ui"

// A program of the installer's list and its steps.
@(private = "file")
Install :: struct {
	name:  string,
	steps: [3]ui.Stepper_Step,
}

steppers_build :: proc(app: ^App, em: f32) {
	heading("Steppers", "ui.stepper shows the stages of a long work, each pending, under way, done, failed or skipped. A change animates: the arc turns, the disc pops and its check draws itself, the connector fills. The program gives the states; the words go below, above or beside, in the colours it wants.", em)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###steppers_columns") {
		ui.next({width = ui.pct(0.6), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###left") { installer_card(em) }
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###right") {
			release_card(em)
			forms_card(em)
		}
	}
}

@(private = "file")
installer_card :: proc(em: f32) {
	installs := [?]Install{
		{"papier", {{label = "Unpack", state = .Done}, {label = "Install", state = .Done}, {label = "Check", detail = "3 of 5 files", state = .Active}}},
		{"classeur", {{label = "Unpack", state = .Done}, {label = "Install", detail = "12 MB of 40", state = .Active}, {label = "Check"}}},
		{"cliche", {{label = "Unpack", state = .Done}, {label = "Install", detail = "The disk is full", state = .Failed}, {label = "Check"}}},
		{"inspecteur", {{label = "Unpack"}, {label = "Install"}, {label = "Check"}}},
	}
	if ui.card("Installing the suite", lucide.PACKAGE) {
		for &p, i in installs {
			if i > 0 {
				ui.spacer(ui.px(em * 0.5))
				ui.hline(ui.fill())
				ui.spacer(ui.px(em * 0.5))
			}
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = fmt.tprintf("###install%d", i)) {
				ui.next({width = ui.px(em * 7), height = ui.px(math.round(em * ui.STEPPER_NODE_EM)), text_pad = 0})
				ui.label(fmt.tprintf("%s###name", p.name))
				ui.next({width = ui.fill()})
				ui.stepper("###steps", p.steps[:], {numbers = i == 3})
			}
		}
	}
}

@(private = "file")
forms_card :: proc(em: f32) {
	if ui.card("Above, right to left, compact", lucide.LIST_CHECKS) {
		above := [?]ui.Stepper_Step{{label = "Draft", state = .Done}, {label = "Review", state = .Done}, {label = "Merge", state = .Active}, {label = "Ship"}}
		ui.next({width = ui.fill()})
		ui.stepper("###above", above[:], {labels = .Above, direction = .Left})
		ui.spacer(ui.px(em * 1.2))
		// (compact: the words are in each node's tooltip)
		compact := [?]ui.Stepper_Step{{label = "Read", state = .Done}, {label = "Resize", state = .Done}, {label = "Encode", state = .Active}, {label = "Write"}, {label = "Upload", state = .Skipped}}
		ui.next({width = ui.px(em * 18)})
		ui.stepper("###compact", compact[:], {compact = true, node = math.round(em * 1.2)})
	}
}

@(private = "file")
release_card :: proc(em: f32) {
	if ui.card("A release", lucide.ROCKET) {
		steps := [?]ui.Stepper_Step{
			{label = "Build", detail = "Windows and Linux, 2 min 14 s", state = .Done},
			{label = "Test", detail = "1 412 tests", state = .Done},
			{label = "Sign", detail = "No key on this machine: signed by the CI", state = .Skipped},
			{label = "Upload", detail = "18 MB of 42", state = .Active},
			{label = "Announce", detail = "A label in a colour of its own", color = ui.hue_color(.Purple)},
		}
		ui.next({width = ui.fill()})
		ui.stepper("###release", steps[:], {direction = .Down})
	}
}
