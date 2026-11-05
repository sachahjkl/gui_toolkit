# Modal dialogs (`ui/overlays.odin`)

`ui.modal(id, width, &open, y_fraction)` dims the page and shows a panel as tall as what is in it. It stays in the window: narrower than `width` if it must, higher than `y_fraction` says when what is in it would pass the bottom.

`ui.modal_sized(id, preferred, &size, &open, min_size)` is a dialog of a size of its own, what is in it filling it (`height = fill()`):

- centered, and always within the window however small: the window has the last word over `min_size`;
- `preferred` is what it opens at, in pixels (in em, it follows the text);
- the person resizes it by its edges and corners; it stays centered, so the opposite side moves too, and the side held stays under the pointer;
- a double click on an edge or a corner goes back to `preferred`;
- `size` is the application's to keep (logical pixels, `{}`: `preferred`): a window made smaller does not change it.
