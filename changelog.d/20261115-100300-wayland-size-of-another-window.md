type: Fixed

**Wayland: a window takes the size the compositor gives it while another window is shown.** A program's loop waits for all its windows on one of them; a new size for another one (a tiling compositor placing a window shown beside the first, or resizing it later) did not end that wait, and the window kept drawing at its old size, cropped by the compositor, until something came for the first one. That size now ends the wait and the window is drawn at once at its new size.
