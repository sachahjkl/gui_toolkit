type: Fixed

**`font.color_glyph_rgba`**: emptying the outline cache of the COLR interpreter freed heap memory with the allocator of the caller: a caller with its own allocator got bad frees.
