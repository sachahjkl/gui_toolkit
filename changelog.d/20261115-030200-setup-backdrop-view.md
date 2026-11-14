type: Changed

**setup's backdrop knows where the dialog is**: `Setup_Options.backdrop` is now `proc(v: ^ui.View, user: rawptr)`, so a program paints its scrim only when `v.presentation == .Dialog` (floating, docked or in a window of its own, the setup has none).
