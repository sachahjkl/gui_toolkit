# Modal dialogs (`src/ui/overlays.odin`)

`ui.modal(id, width, &open, y_fraction)` dims the page and shows a panel as tall as what is in it. It stays in the window: narrower than `width` if it must, higher than `y_fraction` says when what is in it would pass the bottom.

`ui.modal_sized(id, preferred, &size, &open, min_size)` is a dialog of a size of its own, what is in it filling it (`height = fill()`):

- centered, and always within the window however small: the window has the last word over `min_size`;
- `preferred` is what it opens at, in pixels (in em, it follows the text);
- the person resizes it by its edges and corners; it stays centered, so the opposite side moves too, and the side held stays under the pointer;
- a double click on an edge or a corner goes back to `preferred`;
- `size` is the application's to keep (logical pixels, `{}`: `preferred`): a window made smaller does not change it.
- `top` (0 to 1, a fraction of the window's height; default centered): its top is held there, as a command palette's is; its bottom edge and corners follow the pointer, the top has no grips.
- its bottom right corner is square, with the resize grip in it: a bevel in the theme's `resize_grip shade` (the border colour: darker on a light theme, lighter on a dark one) and dots on it. A floating panel of the dock has the same grip.

Several dialogs may be open, one in another or one after the other; the one built last is on top. It has the keyboard: Tab goes round its own stops and Escape closes it, the ones under it wait (it is known at the end of the build, so `open` turns false at the next one: an Escape read as a dialog opens is that dialog's). A dialog that opens takes the focus from what had it, and gives it back when it closes, unless something else took it meanwhile.

## A control in a dialog's corner

A close control (or any other) in the top right corner of a dialog comes with the row across its top:

```odin
if ui.modal_sized("files", preferred, &size, &open) {
    if ui.modal_header("###head", side, inset) {   // first in the dialog
        ui.label("Files")                           // the title, the header's controls
    }
    ...                                             // what is in the dialog
    b := ui.modal_corner({.Clickable, .Focusable}, "###close")
    if ui.signal(b).clicked { open = false }        // its look is the program's: children, a custom draw
}
```

- `modal_header(id, side, inset)` is a row `side` tall, `inset` below the dialog's top: what is in it is centered with
  the control. Its right end, `inset + side + inset`, stays free: the control is never on the header's controls. Build it
  first in a box whose top right corner is the dialog's (the dialog itself, or a column along its top and right edges).
- `modal_corner(flags, id)` builds the control's box: a square of `side`, `inset` from the dialog's top and from its right
  edge, its corners concentric with the dialog's (`corner_place`, [themes](themes.md#corners-in-corners)), as drawn
  (`Fixed_Radius`: a custom draw rounds with `b.radius`). Its place is the dialog's wherever it is built; what `next`
  said is kept, but for its place, size and radius.
- A program that gives every dialog the same side and margin wraps it once:
  `@(deferred_none = ui.modal_header_end) my_header :: proc(id: string) -> bool { return ui.modal_header_begin(id, SIDE, INSET) }`
  (`modal_header_begin`, not `modal_header`: that one ends its header in the scope it is called in, and the header would end twice).
- The grips of a resized dialog leave the corner to it: at its top and right, they are no deeper than `inset`.

## A confirmation (`src/ui/confirm.odin`)

`ui.confirm(id, &open, options)` is the question before an act that is not taken back: a title, a note in the weak text
(what comes of it), what it acts on one per line when there is more than one (`CONFIRM_LINES_MAX` shown, the others
counted), then Cancel and the act's button in the danger colours. It answers `.Confirmed`, `.Cancelled` (the Cancel
button, Escape, a press outside) or `.None` while it waits.

- Enter answers what is safe: Cancel, and the act only with `enter_confirms` (an act that is safe and was asked for). The
  button Enter presses says so: "Cancel (Enter)".
- Its words other than the caller's (`Confirm_Labels`: Cancel, "and %d more", "%s (Enter)") are set once by a program
  that translates them.

## A strip across a dialog's top

A strip across the top of a dialog (its title, a search field) is a box whose custom draw is `dialog_top_draw`: give it
the dialog's radius (`radius = em * DIALOG_RADIUS_EM`) and, for a colour of its own, a `^Color` in `custom_user` (none: a
field's, `input background`, the colour of a menu's search band: every place that searches looks alike; not the box's
`bg`, which inside a dialog is the dialog's). Its top
corners are the dialog's as drawn, it begins inside the dialog's rim, and a line parts it from what is under it. A raised
dialog's rim and edge are drawn over what is in it (`machined_plate_frame`): a child's background or line never covers
them.

## A dialog's header (`src/ui/dialog_parts.odin`)

`dialog_header(id, title, icon, icon_font)` is that strip with a title: a shade darker than the dialog
(`DIALOG_HEADER_DARKEN`), `DIALOG_HEADER_EM` tall, an icon of the accent at its start. Build it first in the dialog,
before the body's scroll, so that it stays on top while the body scrolls. A program that sizes its dialog from its body
adds the header's height (`dense(em * DIALOG_HEADER_EM)`).

## A list to choose from (`src/ui/dialog_parts.odin`)

`choice_row(id, index, &sel, title, detail, icon, icon_font)` is one row of a list a dialog asks to choose from (the
accounts of a security key, the passkeys of a site). The row `index == sel` is drawn as the command palette's selected
line: sunk in a well with a bar of the accent, its words in the theme's own colours. The pointer moving over a row
selects it: the highlight follows the pointer, and Enter takes what it shows. Up and Down are the caller's. It returns
true when the row is clicked.

## A dialog's body and buttons (`src/ui/dialog_parts.odin`)

`if dialog_body("id") { ... }` holds what a dialog says and asks, with its margins (`DIALOG_MARGIN_EM`) and gaps
(`DIALOG_GAP_EM`); `if dialog_buttons("id") { ... }` is its row of buttons, at its right end, the main act last. With
`dialog_header`, every dialog has the same three parts.

## A dialog's body and buttons (`src/ui/dialog_parts.odin`)

`if dialog_body("id") { ... }` holds what a dialog says and asks, with its margins (`DIALOG_MARGIN_EM`) and gaps
(`DIALOG_GAP_EM`); `if dialog_buttons("id") { ... }` is its row of buttons, at its right end, the main act last. With
`dialog_header`, every dialog has the same three parts.
