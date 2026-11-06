type: Fixed

**DevTools**: `Page.startScreencast` on a window served with no `ui.State` is refused. It woke the window for good, and an ack dereferenced the missing state.
