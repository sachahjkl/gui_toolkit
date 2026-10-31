# What changed in gui_toolkit 0.57

**0.57.1: closing DevTools is safe.** In 0.57.0 the connection could be freed while the DOM side still held it: the edits could
stay, and the program could hang. Only a program driven by DevTools is concerned. The screencast could also miss its last frame.
No code to change: take 0.57.1 rather than 0.57.0.

For an application on the toolkit (Wren first). **Nothing breaks and nothing is required**: an application that already calls
`devtools.start_from_env` and `devtools.service` has all of this with no change of code.

## Chrome's DevTools on a window

`node tools/cdp.mjs inspect` prints an address to paste in Chrome or Edge (docs/devtools.md).

- **Elements**: the box tree, followed as the window changes. The tag says what a box does, its name is its `id`, its flags its
  `class`. Hovering a node lights its box in the window.
- **Styles, Computed, Layout**: a box's rect and colours, in sRGB as on the screen.
- **Accessibility** tab: what a screen reader gets for the box.
- **Editing, live**: colours, sizes, font size, padding, radius, opacity, a box's text, removing a box. An edit lasts as long as
  DevTools is attached.

A box with its own `custom` drawing does not follow the colours edited: it paints with what it has. Its size and text do.

## New in the API

- `ui.set_inspected`: a box lit over everything.
- `ui.Box_Edit`, `ui.box_edit`, `ui.box_edits_clear`: what a tool imposes on a box, applied after each build, before the layout.

## What changes for security

The server used to refuse every request with an `Origin`. It now takes one, on the WebSocket only: `devtools://devtools`, which
a web page cannot send. Everything else is refused as before, and the random id of the target is still needed.

## What was checked, and what was not

- tests/e2e runs in the CI: the tree, a change of page followed, a colour against the pixel on screen, a style, a text and a box
  edited, and all of it gone with the client.
- Chrome's frontend was used by hand on `examples/whatsnew`: unfolding, selecting, Computed, Accessibility, a colour typed in Styles,
  a text. The CI does not run it, and opencode native was only checked for its tree.
- Not tried: the colour picker with a mouse, the tick boxes, the element picker, `chrome://inspect`, Wren.
- Elements gets the whole tree at once: with `DOM.requestChildNodes` the frontend had the children and did not show them, for a
  reason not found.
