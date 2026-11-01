type: Added

**Color glyphs off Windows**: the COLR interpreter gets its tables from the native backend, and CBDT bitmaps (Noto Color Emoji on most Linux systems) are drawn from their PNG images (`font/cbdt.odin`). `font.glyph_is_color` and `font.color_glyph_rgba` work there.
