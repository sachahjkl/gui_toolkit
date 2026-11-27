# A form's rows

`ui.form_row(label)` puts a label and its widget on one line of a form: settings, a dialog's fields, an export card.
The rows of one form must read as two columns: the labels, then the fields. Every field starts at one x, with no void
after the labels, and every label sits on its field's first line.

## The label column

- **A form is the rows of one parent box.** No scope to open and no state for the program to keep: two cards are two
  forms, a dialog's body is one.
- **The column is as wide as the form's longest label and a gap.** The need of a label is its inset, its words on one
  line and `CONTROL_GAP` (the gap between words and their control). The column is the widest need of the form,
  `FORM_LABEL_MIN_EM` (3 em) at least, so that a form of one-letter labels does not put its fields against them.
- **At most `FORM_LABEL_CAP` (40 %) of the form's width.** A longer label wraps on more lines within the column: a
  label a user must read is never cut, and a cut label with a tooltip hides words that a form exists to show. Its
  first line is where a label of one line sits. The width is the form's width in the last layout: no cap before the
  form's first layout.
- **Resolved in the build that makes the rows.** Each row puts its label in `State.form_labels`. `form_columns`, in
  `end_build` before the layout (and after the dialogs' builds), gives every label of a form the column. The words
  were measured when the label's box was built, so the pass reads them: one pass over the labels built, nothing kept
  from one build to the next, no build late, no build asked again. Until that pass, a label's width is its own need.
- **A panel that grows to what is in it settles its own forms first.** A dialog (`modal_fit`) and a view's panel
  (`view_internal_fit`) measure their content during the build, before `end_build`. Measured with each label's own
  need, a short label beside a wide field asked for its words only: the field then ended past the dialog's edge (95 px
  in the test). So each calls `form_columns` for the forms inside it, whose rows are all built when it ends, and then
  measures. The pass takes those labels out of `State.form_labels`: each label is settled once. Their cap is of the
  most the panel can be (a dialog's `most`, the window's width while a panel fits), not of its last width: a width
  measured from the cap would move the cap at the next build, and the dialog would shrink one build after another.

Refused:

- **A share of the row** (`pct(0.34)`, the first version). Every field started at one x, but short labels ("Name",
  "Team") left a third of the row empty after them: space lost on every row. Before that, the share was not strict,
  and the fields did not even line up: beside a `fill()` field the row overflowed, and a share of words gives first
  what it has beyond its words (least-width.md), so the label shrank to its words; beside a dropdown of its own width
  it kept its 34 %.
- **A column kept across builds, as `ui.Dense_Labels`**, with an explicit scope and one more build when it moves. The
  build already has every label of the form before its layout: memory and a second build would only add a frame
  where the column is wrong. The debug panel keeps its own, because its rows are built in passes of their own.
- **A label cut with "…" and a tooltip.** The words of a form are what a person reads to fill it.

## The label on the field's first line

- The label is one control's height (`control_height`), so its words sit on the middle of a field of one line.
- The line's children start at its top (`.Start`). A widget of several lines (a `text_edit`) grows the row
  downward, and the label stays on its first line. Before, the row centred the label on a tall field.
- A widget shorter than a line (a progress bar, `px` under `control_height`) is centred on the label's line, not put
  at its top. `form_row_end` reads the widget's height when the widget is built and sets the line's cross alignment.
- The room between two rows does not change: a row of one line is still `FORM_ROW_EM` (2.5 em, with the density)
  tall. The room above and below the line is two spacers in the row (`###frow_%s` is a column, `###frow_line` the
  line in it).

## A field and its note

A hint or a validation message under a field belongs to the field: it starts at the field's left edge, not under the
label nor centred in the row. The program builds the field and its note in a box of their own, one under the other, as
the row's widget: the top alignment keeps the label on the field's first line. `form_row_end` names the field by the
label through such a plain box (no accessible node, not a Tab stop): its first box. Refused: a note slot in
`form_row`. A box the program builds already holds it, and a slot would fix where the note goes and what it holds.
Fidget's first version put its notes in rows of their own after the form row, behind a spacer of the old 34 %:
centred under the whole row, read as the form's and not the field's.

## The tests

`tests/scenarios/form_row_test.odin`:

- Three rows (a dropdown 150 px wide, a `fill()` line edit, a text edit 120 px tall): every field starts at one x,
  at the end of its label; every label's top is its field's top; the longest label's words end one `CONTROL_GAP`
  (± 1 px) before its field; the row of the text edit is as tall as the text edit.
- `tests/examples/fidget_test.odin`, `fidget_field_notes_start_at_their_field`: a note's box starts at its field's
  x, under it, and the field is named by its row's label.
- A form 360 px wide with a label longer than its cap: the label wraps on more than one line, the column is within
  40 % of the form, the fields still start at one x.
- A dialog that grows to what is in it, with a long label beside a `fill()` field and a short one beside a field
  320 px wide: the wide field is within the dialog, at its width.
