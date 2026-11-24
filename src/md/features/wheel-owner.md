# Who takes the wheel

One box takes the wheel of a build: `scroll_hit_test` picks the innermost box under the pointer that scrolls the way the
wheel goes. It decides before the build, from the last build's boxes. A box cannot give the wheel back during the
build: the boxes around it had their chance before it.

So a box that leaves part of the wheel says it with a flag, which the hit test reads:

- `.Ctrl_Wheel`: Ctrl+wheel is the box's own (a zoom of its content), not the interface's zoom.
- `.Shift_Wheel_Free`: Shift+wheel is not the box's. It goes to the box around it that scrolls, else to the program.

`ui.wheel_free` gives the program the wheel that no box took, with its modifiers. A viewer reads Shift+wheel there to go
to the next picture, over a preview that zooms with the wheel (`Preview_Options.shift_wheel_free`).

Refused: an option of the preview that drops `sig.scrolled` with Shift. The preview's box still takes the wheel then:
`wheel_consumed` says true, and nothing else gets it.
