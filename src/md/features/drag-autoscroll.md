# Drag autoscroll

A selection that a person drags to the edge of a scroll view scrolls that view, so a selection can span several
screens. The code is `src/ui/drag_autoscroll.odin`.

## The mechanism

One call marks a drag as selecting: `ui.drag_autoscroll(key)`, in every build while the drag is held. The widget
does not compute a speed, does not keep a timer and does not end anything: the mark lives one build. When the button
comes up, the widget stops calling, and the scroll stops with it. No other state exists, so no other end can be
missed (a release outside the window, a lost capture, a box that goes).

`update_animations` reads the mark of the build, after the middle-click autoscroll and before the ease of the
offsets. For each axis, it walks from the marked box up to the root and takes the first box with a view offset on
that axis (`.View_Scroll_X`, `.View_Scroll_Y`) for which:

- the pointer is inside the band at that edge of the visible rect of the box, or past the edge;
- the box can still scroll in that direction (its target is not at 0 or at its limit).

That box's `view_target` moves by `speed * dt`, as a wheel notch moves it. The marked box itself is a candidate:
the terminal's grid is its own scroll view. If no box moves, nothing wakes a frame. If one moves, the build asks for
the next frame.

A widget that scrolls itself (`.Scroll_Self`: `text_edit`, `line_edit`) calls `ui.drag_autoscroll_own(key, view,
&scroll, limit, axes)` instead. It moves the widget's own offset with the same speed, and passes each axis that its own
offset cannot move to the views around it. An `auto_height` editor in a page therefore scrolls the page.

The selection extends to what scrolled in without any help from the scroll code. Each widget already recomputes the
moving end of its selection from the pointer in every build of the drag. It clamps the pointer into its visible text
first, so the moving end is on the last line shown, and the next line becomes that end when it scrolls in.

## The speed

The band is 1.5 em of the marked box's font, inside each edge of the visible rect. The speed on an axis is
`autoscroll_axis_speed` (the middle-click curve, one implementation) of the distance past the inner edge of the band,
with no dead zone. Its settings are `DRAG_AUTOSCROLL`, in logical pixels, scaled by the window's scale:

- at the view's edge (one band deep): about 70 px/s, a few lines per second, to pick a line;
- 100 px past the edge: about 560 px/s;
- 280 px past the edge or more: the cap, 3000 px/s.

A view smaller than two bands splits its size between its two bands, so a short view still has a middle where
nothing scrolls.

## Decisions

- **A mark per build, not a session.** The middle-click autoscroll has a session because it outlives its press (the
  toggle mode). A selecting drag never outlives its button, and the widget knows its button. A session with its own
  ends duplicates the widget's state and can disagree with it.
- **Innermost that can still scroll.** A list in a page, dragged past its bottom, scrolls the list to its end, then
  the page. The refused alternative, the view under the pointer, scrolls nothing when the pointer is past every edge.
- **The visible rect, not the box's rect.** A view clipped by its parent has its edge where the person sees it.
- **No timer.** The speed is per second and the step uses the frame's `dt`, so the travel is the same at 60 Hz and at
  180 Hz.
- **Not while the middle-click autoscroll runs.** Both write the same targets; the session the person started last
  with the middle button wins.

## Subtle points

- `sel_nearest` skips a selectable box with no visible part. A box scrolled out of the view had a clamped rect at the
  view's edge, and the moving end could jump to the end of a paragraph that no one sees.
- Lists and tables have no range selection by drag (a press marks, Shift and Ctrl extend). If one comes, it calls
  `drag_autoscroll` with its list's box.
- A virtual list builds only the rows it shows. A text selection whose anchor box is no longer built ends, as it did
  before this feature.
