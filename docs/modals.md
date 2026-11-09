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
