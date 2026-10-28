type: Added

**`font.glyph_outline` and a neutral `font.color_renderable`**: `glyph_outline(state, face, gid, tolerance, out)` hands a 2D canvas (or any glyph-path consumer) a glyph outline through the active backend (DirectWrite or the native Fontations backend) rather than a DirectWrite-only entry point, and `color_renderable` now answers on every system (off Windows the built-in COLR / CPAL interpreter draws colour faces). Both let an application draw glyph paths and build colour-font cascades the same way on every platform.
