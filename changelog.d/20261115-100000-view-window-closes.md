type: Fixed

**A view in a window of its own closes again on Linux (Wayland)**: its window's close button, or the compositor's, left the window on the screen. The close of one window is read in another window's frame there, and the window marked closed was skipped before its own frame, the one that takes the close back and puts the view back in place. A window with a `close_asked` hook keeps its frame until it took the close back, and the loop does not sleep over it.
