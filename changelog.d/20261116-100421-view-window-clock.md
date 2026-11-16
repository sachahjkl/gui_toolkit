type: Changed

**A view's window keeps its owner's time**: a window with no clock of its own (`ui.set_clock`) reads the clock of the window it follows, so `session.advance` moves its delays (a tooltip) too.
