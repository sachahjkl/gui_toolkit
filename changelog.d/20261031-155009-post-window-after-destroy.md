type: Fixed

**`ui.post` through a window**: after `ui.destroy` every window the State was built for returns false, not only the last one (the others used a queue that was gone).
