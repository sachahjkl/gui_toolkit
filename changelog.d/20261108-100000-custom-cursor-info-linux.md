type: Fixed

**`platform.custom_cursor_info` on Linux** says the size and hotspot of the cursor as it is shown, the image at the scale it is shown at (`scale`, or the window's: `custom_cursor_scale`), as on Windows; it said those of the source image whatever the scale. The scaling is shared with the pixels made for X and Wayland (`custom_cursor_geometry`).
