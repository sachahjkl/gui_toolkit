type: Changed

**A tool bar's tools in words have no face at rest**: `ui.toolbar_tool` with `words` shows its face only under the pointer, pressed, focused or lit, as a glyph tool does, so a bar reads as one surface instead of a box per word. The bar's main act, words of intent `.Primary` (Done, Send), stays raised. `Toolbar_Tool.face` chooses `.Ghost`, `.Raised` or `.Link` for one tool.
