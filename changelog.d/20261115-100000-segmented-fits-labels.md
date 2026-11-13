type: Changed

**A segmented control is as wide as its labels.** With no width given, `ui.segmented` makes every segment as wide as its widest label with its padding: no label is cut, in any language. A width given is kept. `ui.segmented_width(labels)` gives that width to a layout that places the control before it is built. The settings' choices use it.
