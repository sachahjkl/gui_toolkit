# The strip

A strip is a set of choices that a person picks from: tabs, a stack's tabs, a program's server tabs, chips, a
sidebar's buttons, a block of them. When its choices do not fit its room, it scrolls: on each side that hides choices an
arrow button lies over the edge (nothing of the content shows under it), and the content fades out beyond it. A strip
never has a scroll bar. Why it is so: the intent, [src/md/features/strip.md](../src/md/features/strip.md).

```odin
ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
if ui.row(.Center, id = "###server_row") {
	if ui.strip("###servers") {
		ui.a11y_default(ui.parent_box(), {role = .Tab_List, orientation = .X})
		for srv, i in servers {
			sig := ui.button(fmt.tprintf("%s###srv_%d", srv.name, i))
			if i == chosen { ui.strip_reveal(sig.box) }   // (brought into view when the chosen one changes)
			if sig.clicked { pick(i) }
		}
	}
	if ui.button("+###add").clicked { add_server() }   // (right after the last tab; at the strip's end when it scrolls)
}

// a sidebar's column of choices
ui.next({width = ui.px(em * 14), height = ui.fill()})
if ui.strip("###places", {axes = {.Y}}) { for p in places { place_button(p) } }
```

`ui.tabs` is built on a strip, and so are the tabs of a stack of views: a program that uses them has nothing to do.

## What it does

| Input | The strip |
|---|---|
| Its choices fit | a plain row (column, block): no arrow, no fade, no bar; the wheel goes to the page around it |
| Its choices overflow | an arrow on each side that hides choices only (at the start: the end one), the content faded beyond it |
| A click on an arrow | the nearest choice the arrow covers or that lies past it comes fully into view, clear of the arrow and the fade (`Strip_Step.Item`); `.Page`: the view moves by its clear part |
| An arrow held | it steps again after the Feel's repeat delay, then at its interval |
| One axis: the wheel, Shift+wheel, a sideways delta | each scrolls it along its axis (down: toward the end), by the wheel's step, smoothly |
| Both axes: the wheel / Shift+wheel / a touchpad | Y / X / both at once, as a page |
| Ctrl+wheel | never the strip's: the zoom |
| Tab or an arrow key moves the focus to a choice off view | the strip scrolls to show it, clear of the arrows |
| `strip_reveal(choice)` names a new chosen one | it comes into view, once |

The arrows are not Tab stops: the choices are. A screen reader names them "Scroll left", "Scroll right", "Scroll up",
"Scroll down"; they have no tooltip. They take no room in the layout: the choices never move when an arrow comes or
goes. Each is a small plate of the strip's surface in the ink of the text around the strip, the same for both arrows at
rest and under the pointer (the hover shows by its plate). Beyond an arrow, a clear gap (`ui.STRIP_GAP_EM`, 0.3 em) shows
nothing but the surface, then the content fades in: a choice cut at the arrow, its own drawing included (a custom draw's
bevel, a glow), never touches it.

## Its size

Along an axis it scrolls, with no size given (`next`), a strip is as long as its choices, and it is the first to give
way in a parent that is short: what is built after it (a "+") follows the last choice while they fit, and stays at the
strip's end when they do not. Its choices give way first, each by what it may give (its strictness, never under the
width its content keeps: a tab's words cut with an ellipsis down to `ui.TAB_TITLE_LEAST_EM`, `ui.tab_title_width`), and
only then does the strip scroll; a choice of a fixed size gives nothing. It never gives way under its largest choice (as
small as it may be) and one arrow (a size in `px` excepts it): in a parent too short for that, what comes after the
strip is cut. When its room changes (a window resized), its chosen choice comes into view again. A size given (`fill()`, `px`) is kept. Across, a strip
is as large as its parent (`pct(1)`), and its choices are often `pct(1)` of it: give the row (the column) a size of its
own, never `children_sum`.

Its choices are the clickable boxes built in it, at any depth (a choice's own parts, a tab's close button, are not
choices); with none clickable, the boxes built directly in it. On one axis they are laid out along it; on both, in a
column of rows, unless `next` gives another axis.

## API

| Call | What it does |
|---|---|
| `if ui.strip(id, o) { choices }` | A strip. `Strip_Options`: `axes` (`{.X}`, the default, also `{}`; `{.Y}`; `{.X, .Y}`), `step` (`.Item`, the default, or `.Page`), `fade` (how far the content fades out beyond an arrow, ems; 0: `ui.STRIP_FADE_EM`, 1), `edge` (frame px along the strip's bottom, its right side for `{.Y}`, that its arrows leave showing: a line drawn there, as `ui.tabs` draws its Folder's). |
| `ui.strip_reveal(choice)` | In the strip's block, at each build: the chosen choice. Each time it changes, and in the strip's first frame, it is in view along each axis, clear of the arrows and the fade, in that same frame (no jump a frame later). |
| `ui.strip_view(id)` | The box that holds the choices of the strip built last with `id` in the current parent: its role for a screen reader goes there (a tab list's), and a test reads its offset (`view_off`) and its limit (`ui.view_limit(box, axis)`). |
| `.Strip_Wheel` | The box flag a strip's view has: it takes the wheel only while it overflows the way the wheel scrolls it, never with Ctrl; on one axis every wheel scrolls along it. |
| `.Scrollbar_None` | The box flag a strip's view has: no bar, no room for one ([scroll-bar.md](scroll-bar.md)). |
| `Box.edge_hold` | Beside `edge_fade`: a band at each edge of a `.Clip` box where its content does not show at all, before the fade (`draw.mask_edge_fade`'s `hold`). A strip sets both: the hold is its arrow and the gap beyond it. |
| `ui.STRIP_GAP_EM` | The clear gap between an arrow and the first pixel of the content, ems. |
| `ui.STRIP_SLIVER_EM` | A choice cut by an arrow's band that would show less than this before it is held whole, with no fade: a sliver showed its rim and none of its words. |
| `ui.tab_title_width(text, pad, text_pad)` | The width of a tab's words: their own, giving way down to `ui.TAB_TITLE_LEAST_EM` (3) ems, cut with an ellipsis, in a strip too short for its tabs. |

The boxes a test finds by name: `strip_left`, `strip_right`, `strip_up`, `strip_down` (the arrows, inside the strip),
`strip_view`. Every arrow is built at every build; one whose side hides nothing has no place after the layout (nor a
press, nor a node for a screen reader): `session.find` does not find it. The arrows and the least size are right from
the first frame a strip is in.

## The look of a row of tabs

`ui.tabs`, a stack of views and a dock's stack show their tabs one way. A line in the border's colour runs along the
row's bottom; the chosen tab rises out of it as one shape with the panel it shows: concave fillets at its feet, rounded
top corners (the theme's control radius), the page's colour inside with the finish's light at its top, no line under
it. The others have a faint rounded outline on the line, filled with the hover tint under the pointer. Every tab has its
whole silhouette; the first starts a few pixels from the row's edge, the room of its left foot. The words sit in
the middle of the shape. The theme's entries: `tab_on background` and the states of `tab` ([themes.md](themes.md)).

A program that puts `ui.tabs` in a row of its own and wants the line across the whole row makes that row's custom draw
`ui.tab_line_draw` (the debug window, fidget): not `.Draw_Side_Bottom`, which is drawn over the chosen tab.

## When a row is not a strip

- A bar of tools that wraps onto more lines or folds its rare tools into a menu: `ui.toolbar` ([toolbar](widgets.md)).
- A path whose leading folders fold into a "…" menu: `ui.path_bar` ([path-bar.md](path-bar.md)).
- A few equal choices that always fit: `ui.segmented`.
- Content that is read (a wide table, a code block, a long list): a box that scrolls, with its scroll bar.
