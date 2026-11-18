package views_test

// The fold of a side panel (ui/side_panel.odin, src/md/features/side-panels.md) as a state machine of two bits, with no
// window: a crossing of the threshold, either way, gives the automatic state; a manual act holds until the next
// crossing; the band of the gap keeps the state; an unknown room changes nothing; a restart keeps a choice on its side;
// the words of the memory.

import "core:testing"
import "gt:ui"

// (units of one em: the panel open at 14, the content's least 26, the gap 1; the threshold is a room of 40)
@(private = "file") OPEN :: 14
@(private = "file") LEAST :: 26
@(private = "file") GAP :: 1

@(private = "file")
follow :: proc(f: ^ui.Side_Fold, room: f32) -> bool { return ui.side_fold_follow(f, room, OPEN, LEAST, GAP) }

@(test)
a_crossing_gives_the_automatic_state :: proc(t: ^testing.T) {
	f: ui.Side_Fold
	testing.expect(t, !follow(&f, 60), "wide from the start: no crossing")
	testing.expect_value(t, f, ui.Side_Fold{})
	testing.expect(t, follow(&f, 39), "under the threshold: a crossing")
	testing.expect_value(t, f, ui.Side_Fold{folded = true, narrow = true})
	testing.expect(t, follow(&f, 41), "past the threshold and the gap: a crossing")
	testing.expect_value(t, f, ui.Side_Fold{})
}

@(test)
the_gap_keeps_the_state :: proc(t: ^testing.T) {
	f: ui.Side_Fold
	testing.expect(t, !follow(&f, 40), "at the threshold: wide")
	testing.expect(t, follow(&f, 39.9), "just under: narrow")
	for room in ([]f32{40, 40.5, 40.99, 39, 40.9}) {
		testing.expectf(t, !follow(&f, room), "%v: within the gap, narrow stays", room)
	}
	testing.expect(t, follow(&f, 41), "past the gap: wide")
	testing.expect(t, !follow(&f, 40.2), "within the gap from wide: wide stays")
}

@(test)
a_manual_choice_holds_until_the_next_crossing :: proc(t: ^testing.T) {
	f: ui.Side_Fold
	_ = follow(&f, 60)
	testing.expect(t, ui.side_fold_set(&f, true), "a manual fold while wide")
	testing.expect(t, ui.side_fold_manual(f), "a choice of the person's")
	testing.expect(t, !follow(&f, 70), "another wide room: no crossing")
	testing.expect(t, f.folded, "the fold holds")
	testing.expect(t, follow(&f, 30), "narrow: a crossing")
	testing.expect(t, !ui.side_fold_manual(f), "the automatic state")
	testing.expect(t, ui.side_fold_set(&f, false), "a manual opening while narrow")
	testing.expect(t, !follow(&f, 35), "another narrow room")
	testing.expect(t, !f.folded, "the opening holds")
	testing.expect(t, follow(&f, 60), "wide: a crossing")
	testing.expect(t, follow(&f, 30), "narrow again")
	testing.expect(t, f.folded, "folded by the rule: the opening ended at the crossing")
	// (a manual act that asks the automatic state is the automatic state)
	testing.expect(t, !ui.side_fold_set(&f, true), "a fold while folded: no change")
	testing.expect(t, !ui.side_fold_manual(f), "still the automatic state")
}

@(test)
an_unknown_room_changes_nothing :: proc(t: ^testing.T) {
	f := ui.Side_Fold{folded = true}
	testing.expect(t, !follow(&f, 0), "no room yet")
	testing.expect_value(t, f, ui.Side_Fold{folded = true})
}

@(test)
a_restart_keeps_a_choice_on_its_side :: proc(t: ^testing.T) {
	f: ui.Side_Fold
	_ = follow(&f, 60)
	_ = ui.side_fold_set(&f, true)
	text := ui.side_fold_format(f)
	testing.expect_value(t, text, "folded")
	same, ok := ui.side_fold_parse(text)
	testing.expect(t, ok, "read back")
	testing.expect(t, !follow(&same, 60), "restarted wide")
	testing.expect(t, same.folded, "the fold holds")
	other, _ := ui.side_fold_parse(text)
	testing.expect(t, follow(&other, 30), "restarted narrow: a crossing")
	testing.expect(t, !ui.side_fold_manual(other), "the automatic state")
	testing.expect(t, follow(&other, 60), "wide again")
	testing.expect(t, !other.folded, "open: the choice ended")
}

@(test)
the_fold_s_words :: proc(t: ^testing.T) {
	for f in ([]ui.Side_Fold{{}, {folded = true}, {narrow = true}, {folded = true, narrow = true}}) {
		back, ok := ui.side_fold_parse(ui.side_fold_format(f))
		testing.expectf(t, ok && back == f, "%v: read back as %v", f, back)
	}
	testing.expect_value(t, ui.side_fold_format({folded = true, narrow = true}), "folded narrow")
	_, ok := ui.side_fold_parse("folded sideways")
	testing.expect(t, !ok, "a word it does not know")
}
