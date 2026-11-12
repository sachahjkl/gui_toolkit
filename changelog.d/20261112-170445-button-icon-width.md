type: Added

**`ui.button_icon` takes a width and an icon font**: `width = fill()` shares the row as `flex: 1` does (two buttons side by side, or one across the whole width), `px(...)` gives it a width of its own, the default stays as wide as what is in it; its content stays centred. `icon_font` draws the glyph in another font than `State.icon_font` (`lucide_icons()`).
