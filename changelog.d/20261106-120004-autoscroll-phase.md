type: Changed

**`ui.Autoscroll`** says where a session is in one field, `phase` (`Autoscroll_Phase`: `Off`, `Holding`, `Latched`), in place of `active`, `held` and `latched`; every end zeroes it, with the box it scrolls (`box`). `State.auto_box` and `State.auto_pressed` are gone.
