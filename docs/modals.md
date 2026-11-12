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
the dialog's radius (`radius = em * DIALOG_RADIUS_EM`) and its background (`bg`; none: a field's darker one). Its top
corners are the dialog's as drawn, it begins inside the dialog's rim, and a line parts it from what is under it. A raised
dialog's rim and edge are drawn over what is in it (`machined_plate_frame`): a child's background or line never covers
them.
