package scenarios_test

// A form's rows (ui.form_row): the labels are one column as wide as the longest label and a gap, whatever the field
// beside them is, so every field starts at one x with no void after the labels, and a label sits on its field's first
// line (src/md/features/form-row.md).

import "core:math"
import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file") FORM_WIDTH :: 600
@(private = "file") NARROW_FORM :: 360   // (its column's cap, 40 %, is narrower than LONG_LABEL)
@(private = "file") LONG_LABEL :: "Where the pictures are kept between two exports"
@(private = "file") EPS :: 0.5   // (a rect rounded to whole pixels)

@(private = "file")
Form :: struct {
	team:  int,
	title: ui.Line_Edit,
	about: ui.Text_Edit,
	width: f32,
	long:  bool,   // a fourth row whose label is longer than the column's cap
}

@(private = "file")
form_build :: proc(s: ^session.Session) {
	f := (^Form)(s.user)
	ui.next({width = ui.px(f.width), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###form") {
		if ui.form_row("Team") {
			teams := [?]string{"Design", "Engine", "Research"}
			ui.next({width = ui.px(150)})
			ui.dropdown("###f_team", teams[:], &f.team)
		}
		if ui.form_row("Title") { ui.line_edit("###f_title", &f.title) }
		if ui.form_row("About") {
			ui.next({height = ui.px(120)})
			ui.text_edit("###f_about", &f.about, {wrap = true})
		}
		if f.long {
			if ui.form_row(LONG_LABEL) { ui.line_edit("###f_long", &f.title) }
		}
	}
}

// Each field starts at the column's end, at one x; each label's top is its field's top; every field is within its row.
@(private = "file")
expect_aligned :: proc(t: ^testing.T, s: ^session.Session, rows, fields: []string) -> (column_end: f32) {
	column_end = session.get(s, fields[0]).rect.min.x
	for name, i in rows {
		row := session.get(s, name)
		label := session.get(s, "lbl", within = row)
		field := session.get(s, fields[i])
		testing.expectf(t, abs(field.rect.min.x - column_end) < EPS, "%s starts at %v, %s at %v", fields[i], field.rect.min.x, fields[0], column_end)
		testing.expectf(t, abs(label.rect.max.x - field.rect.min.x) < EPS, "%s: the field starts where the label column ends: %v and %v", name, label.rect.max.x, field.rect.min.x)
		testing.expectf(t, abs(label.rect.min.y - field.rect.min.y) < EPS, "%s: the label's top at its field's top: %v and %v", name, label.rect.min.y, field.rect.min.y)
		testing.expectf(t, field.rect.max.x <= row.rect.max.x + EPS, "%s: the field within its row: %v in %v", name, field.rect, row.rect)
	}
	return
}

// A dropdown of its own width, a field that fills the row, a field of several lines: the fields start at one x, the
// longest label's words a gap (CONTROL_GAP) from its field: no void after the labels.
@(test)
form_rows_share_a_column_as_wide_as_their_longest_label :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	f := Form{width = FORM_WIDTH}
	defer ui.line_edit_destroy(&f.title)
	defer ui.text_edit_destroy(&f.about)
	s := session.start(t, {size = {800, 500}, no_renderer = true, user = &f, build = form_build})
	session.frames(s, 2)
	rows := []string{"frow_Team", "frow_Title", "frow_About"}
	fields := []string{"f_team", "f_title", "f_about"}
	column_end := expect_aligned(t, s, rows, fields)
	words_end: f32
	gap: f32
	for name in rows {
		label := session.get(s, "lbl", within = session.get(s, name))
		words_end = max(words_end, label.rect.min.x + label.text_pad + label.text_dim.x)
		gap = math.round(label.font_size * ui.CONTROL_GAP)
	}
	testing.expectf(t, abs(column_end - words_end - gap) <= 1, "the longest label's words a gap from its field: %v, the gap %v", column_end - words_end, gap)
	// (the row of several lines is as tall as its field, not centred on it)
	about := session.get(s, "frow_About")
	testing.expectf(t, about.rect.max.y - about.rect.min.y >= 120 - EPS, "the row as tall as its field: %v", about.rect)
}) }

// A label longer than the column's cap (40 % of the form) wraps within the column: never cut, the column no wider than
// the cap, every field still at one x.
@(test)
a_form_label_longer_than_the_cap_wraps :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	f := Form{width = NARROW_FORM, long = true}
	defer ui.line_edit_destroy(&f.title)
	defer ui.text_edit_destroy(&f.about)
	s := session.start(t, {size = {800, 600}, no_renderer = true, user = &f, build = form_build})
	session.frames(s, 3)
	long_row := "frow_" + LONG_LABEL
	expect_aligned(t, s, {"frow_Team", "frow_Title", long_row}, {"f_team", "f_title", "f_long"})
	form := session.get(s, "form")
	label := session.get(s, "lbl", within = session.get(s, long_row))
	testing.expectf(t, label.rect.max.x - form.rect.min.x <= NARROW_FORM * 0.4 + EPS, "the column within its cap: %v", label.rect)
	testing.expect(t, .Text_Wrap in label.flags, "the long label wraps")
	one := session.get(s, "lbl", within = session.get(s, "frow_Team"))
	testing.expectf(t, label.size.y > one.size.y + EPS, "on more than one line: %v, one line %v", label.size.y, one.size.y)
}) }
