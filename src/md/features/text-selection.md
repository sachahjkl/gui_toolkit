# Text selection

Every text that a person reads as content can be selected and copied, in every program: a drag selects across lines
and boxes, Ctrl+C copies, a drag near an edge scrolls ([drag-autoscroll.md](drag-autoscroll.md)). The code is
`src/ui/selection.odin`; a box takes part when it has `.Selectable`.

## Content and controls

The line between the two is what the text is for, not how it is drawn.

- **Content** is selectable: what a program shows to be read. A paragraph, a rich paragraph, a file's text in a
  preview, code, Markdown, a diff, a terminal, a message, an error, a note, a setting's description, a value in a list
  of properties, a log line, a history item's text.
- **A control's label** is not: the words of a button, a tab, a menu item, a field's name, a check box's label, a
  section's title, a list row's name. They name an act or a place. A drag on them is a press on the control (a tab
  moves, a row is picked), and a person who wants a field's name copies it from the documentation, not from the field.
- **Transient text** is not: a tooltip or a toast goes when the pointer moves, so no drag can reach its end.

## Defaults

The widgets follow the line, so a program gets it without a flag:

- `paragraph` and `rich_paragraph` are selectable by default: they are the widgets of prose. `selectable = false` is
  for a paragraph that is a control's part (a list row's lit name: `matched_label`, a table's lit cell).
- `label` is not selectable by default: most labels name controls. A label that shows content takes `next({flags =
  {.Selectable}})`. `empty_state`'s title is content (the file browser shows a file's name there).
- `gt:markdown`, `gt:diff` (no option: a diff is never a control), the file browser's preview and `gt:term` select
  always. `line_edit` and `text_edit` have their own selection.

## A click acts, a drag selects

Text inside a clickable box (a history item, a card that opens its file) is still selectable. A press on it goes to the
box, as before, and the selection waits:

- if the button comes up before the pointer moves `SEL_DRAG_SLOP_PX`, the box gets its click, its double click;
- if the pointer moves farther first, the selection starts at the press, and the box loses its press (its
  `active_key` goes), so its release is no click and its drag ends.

A button's own label is never selectable (`sel_kind`: `.Clickable` on the box itself), so a button keeps its drag
(a tab that moves, a slider). Only text a program marked as content inside a clickable box waits this way.

Refused: selecting at once on a press in a clickable box. A click on a history item then pasted nothing. Refused too:
a modifier (Alt+drag) to select there; no person finds it.

## Ctrl+C: the selection's or the program's

A program has its own Ctrl+C (classeur copies files, papier an entry). The selection takes the chord when the last
left press made it, text is selected, and no text field has the keyboard (`selection_takes_copy`); `chord_pressed`
then gives the program's command nothing. A press anywhere else (a row of the list) gives the chord back to the
program, and the selection still shows: a Copy button reads it on its release.

Refused: the selection takes Ctrl+C whenever it shows. A person who selected words in the inspector, then picked
files in the list, copied the words.

## Subtle points

- A copy joins two boxes by a line break, and by a blank line before a box with `.Selection_Block`: a block of a
  document. Markdown marks each block (two items of one list stay a line apart), so a copy across a paragraph and a
  code block reads as its source. The refused alternative, a blank line where the boxes are apart on screen, put one
  between a label and the paragraph under it, and changed with the theme's spacing.
- A list's Ctrl+A selects its rows. A row's name built with `matched_label` is not selectable, so Ctrl+A over a row
  is the list's alone.
- A double click in a clickable box is the box's (open), not a word's selection.
- The text cursor over content in a clickable box stays the box's: the click is what the pointer offers first.
