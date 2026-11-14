type: Changed

**The file browser is a view**: the toolkit's file dialog (`ui.file_dialog`) is now the view `"file_dialog"`, one per window, as every other dialog: its header is the views' (its title and its icon), its size is remembered, and the person can float it, dock it or open it in a window of its own from its header's menu. Its question before saving over a file is a confirmation over it. What it does is unchanged: its sources, its path bar, its keyboard, `done` called once (the close cross and a press outside are Cancel).
