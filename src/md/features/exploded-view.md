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

## Input

While the view is on, the page takes no input: `exploded_events` takes the pointer, the wheel and the keys from the
frame's events before `process_events` sees them. What else comes (a resize, a close, the window's activation) passes.

- A drag with the left button turns it: across changes `yaw`, along changes `pitch` (held under 85°).
- The wheel changes `spread`, the distance between two planes.
- Escape, or the key again, turns it off.
- The pointer counts as gone (`mouse_valid = false`): no box stays hot under it.

The key is Ctrl+Alt+Shift+E in a build with the devtools (`TOOLKIT_DEVTOOLS`), as the wireframe's.

## Cost

Only while on. Off, `draw_tree` draws as before and `exploded_events` hands the events back untouched: no extra
pass. On, every frame is whole (`damage_whole`), and it holds one layer of the window's size per depth: a deep tree
holds many, so the boxes past depth 47 share the last plane (`EXPLODED_MAX_PLANES`). Turning it on or off forgets what partial redraw remembered, so the next frame is whole.

## Refused

- A plane per box: a page has thousands of boxes, each a texture and a matrix, and the bsp would sort them all. A
  plane per depth keeps the count at the tree's depth and draws each box once.
- Drawing the subtree into each plane (a parent with its children, as `draw_box` does): the children would show twice,
  flat on their parent and again on their own plane in front.
