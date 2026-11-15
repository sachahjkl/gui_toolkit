# The exploded view

`ui.set_exploded(s, on)` draws the window's boxes as layers in depth instead of the page: one plane per depth of the
box tree (the root at depth 0, its children at 1, ...), each parent behind its children, the whole turned with the
mouse. The nesting of a page, the views over it and the overlays (menus, toasts, tooltips) read at a glance, as a
browser's 3D view of its layers shows them. It is the author's tool, as the wireframe is (spacing.md, "The wireframe").

## How it draws

- A dark ground over the window, then the planes.
- A plane holds the boxes of one depth, each drawn as the page draws it but without its children: `draw_box` with
  `children = false` draws the box's face, text, custom draw, scrollbars and border, and skips its subtree. A thin
  outline goes round each box, so that a box that draws nothing (a row, a column of the layout) still shows.
- A box keeps the clips of its ancestors (`.Clip`): the rows of a scrolled list stay inside their view, as on the page.
  The alpha, fade and squish of its ancestors are not applied: each plane shows its boxes at full strength.
- Each plane is a layer (`draw.push_plane` over the window's rect, at the window's own scale), drawn through a matrix:
  moved along z by `depth × spread`, the stack centred on z = 0, turned by `yaw` (about y) and `pitch` (about x)
  round the window's centre, shrunk to fit, with a perspective. `draw.draw_planes` orders them (bsp.odin): parallel
  planes never cut each other, so the painter's order holds and nothing is split.
- Overlays are boxes of the tree: menus, toasts and tooltips come out on their own depths. A view drawn in another
  window (a view window, views.odin) has its own state and its own exploded view: one window shows only its own tree.

## Modes

- Depths: a plane per depth of the tree, as above, each box tinted in its plane's colour.
- Outlines: the depths' planes, each box only its outline.
- Layers: a plane per layer, as a browser's view of its layers. A box starts a plane in front of its parent's when it
  paints a surface (a background, a drawing of its own) and is at least 3 em on both sides
  (`EXPLODED_LAYER_LEAST_EM`). What it holds without one (text, icons) stays on its plane. A smaller surface (a pill,
  a button, a toggle's track, a strip of a gradient band) stays on its parent's plane too: on a plane of its own, a
  thin strip of a band crossed the words beside it, and each button floated apart from its row.

## The way in and out

`t` goes from 0 (the page) to 1 (the view) in `EXPLODED_TRANSITION_MS` (600 ms) while `on`, and back while not, by
the frame's `dt` (held under 50 ms a step: a frame after a long rest does not skip the way). The drawing takes the
eased `t` (a smoothstep): the angles and the spread from 0, the zoom from 1, the ground, the outlines and the tints
faded in (Outlines: the boxes faded out). At t = 0 the planes lie on one another at z = 0, unturned, at the window's
scale, in the tree's order: the picture is the page's, so the way in starts with no jump. While `t` moves,
`anim_busy` keeps frames coming; the page is drawn again once `t` is back at 0. With animations off, `t` jumps.

`exploded(s)` says the switch (`on`), not the picture: it is false from the moment the view is turned off. The
picture and the input stay the view's until `t` is 0 (`exploded_shown`).

## The panel

A floating box at the window's right (`###exploded_panel`, 18 em wide, at most half the window), built at the end
of the build (end_build, after the toasts) while the view is shown, of the toolkit's own widgets: the mode
(`segmented`), a slider each for the yaw, the pitch, the spread and the zoom (`fit`), "Reset view" and "Close", and
one line on what the pointer does on the planes. It slides in from past the right edge with the eased `t`. The
sliders write the view's fields: the view drawn after the build shows them in the same frame.

`exploded_draw` skips it in the planes and draws it flat (`draw_box`) after `draw_planes`: it is the view's control,
not a part of the page to look at. The key legend drawn at the top left is gone: the panel says the mode and the
values, and its line says the rest.

## Input

While the view is shown, the page takes no input: `exploded_events` takes the pointer, the wheel and the keys from the
frame's events before `process_events` sees them. What else comes (a resize, a close, the window's activation) passes.

- The pointer over the panel (its rect in the last layout) is the panel's: its moves, presses and releases pass to
  `process_events`, so its widgets work as on a page. A press there keeps the pointer the panel's until its release
  (a slider's drag goes off its edge). The wheel over it goes nowhere: the page's scrolling views under it would take
  it. When the pointer leaves the panel for the planes, a `Mouse_Leave` passes: nothing of the panel stays hot.
- A drag with the left button on the planes turns it: across changes `yaw` (held in -180..180, round the other side),
  along changes `pitch` (held under 85°).
- The wheel changes `spread`, the distance between two planes.
- Escape, or the key again, turns it off. The key on the way back turns it on again from where it is.
- The pointer on the planes counts as gone (`mouse_valid = false`): no box stays hot under it.

The keys go to the view, not the panel: a focused slider takes no arrow. The key is Ctrl+Alt+Shift+E in a build with
the devtools (`TOOLKIT_DEVTOOLS`), as the wireframe's.

## Cost

Only while shown. Off (`t` at 0 and not on), `draw_tree` draws as before, `exploded_events` hands the events back
untouched and no panel is built: no extra pass. Shown, every frame is whole (`damage_whole`), and it holds one layer
of the window's size per depth: a deep tree holds many, so the boxes past depth 47 share the last plane
(`EXPLODED_MAX_PLANES`). Turning it on, and its end at t = 0, forget what partial redraw remembered, so the next frame
is whole.

## Refused

- A plane per box: a page has thousands of boxes, each a texture and a matrix, and the bsp would sort them all. A
  plane per depth keeps the count at the tree's depth and draws each box once.
- Drawing the subtree into each plane (a parent with its children, as `draw_box` does): the children would show twice,
  flat on their parent and again on their own plane in front.
- The panel as a plane of the stack: it turned with the page, and its sliders were hard to reach at an angle.
- A key legend drawn with `draw.text` over the planes: it said again what the panel says.
