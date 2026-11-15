type: Fixed

**Windows: an offscreen window's placement reads back maximized.** `platform.set_placement` with `maximized` on an offscreen window makes it maximized at once, as on Linux; `get_placement` said it was not until it was shown, which an offscreen window never is.
