# The strip

A strip is a row of choices that a person picks from: tabs, a stack's tabs, a program's server tabs, chips. When its
items are wider than its room, it scrolls sideways: the edge that hides items fades, and an arrow button lies on that
edge. A strip never has a scroll bar. Why it is so: the intent, [src/md/features/strip.md](../src/md/features/strip.md).

```odin
ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
if ui.row(.Center, id = "###server_row") {
	if ui.strip("###servers") {
		ui.a11y_default(ui.parent_box(), {role = .Tab_List, orientation = .X})
		for srv, i in servers {
			if ui.button(fmt.tprintf("%s###srv_%d", srv.name, i)).clicked { pick(i) }
		}
	}
	if ui.button("+###add").clicked { add_server() }   // (right after the last tab; at the strip's end when it scrolls)
}
```

`ui.tabs` is built on a strip: a program that calls it has nothing to do.

## What it does

| Input | The strip |
|---|---|
| Its items fit | a plain row: no arrow, no fade, no bar, the wheel goes to the page around it |
| Its items overflow | the edge that hides items fades; an arrow on that edge only (at the start: the right one) |
| A click on an arrow | the next hidden item comes fully into view, clear of the fade (`Strip_Step.Item`); `.Page`: the view moves by its clear part |
| An arrow held | it steps again after the Feel's repeat delay, then at its interval |
| The wheel, up and down | scrolls it sideways (down: toward the end) |
| A sideways wheel, a touchpad, Shift+wheel | scrolls it sideways |
| Tab or an arrow key moves the focus to an item off view | the strip scrolls to show it, clear of the fade |

The arrows are not Tab stops: the items are. A screen reader names them "Scroll left" and "Scroll right"; they have no
tooltip. They lie over the faded edge and take no room: the items never move when an arrow comes or goes.

## Its size

With no width given (`next`), a strip is as wide as its items, and it is the first to give way in a row that is short:
what is built after it (a "+") follows the last item while they fit, and stays at the strip's end when they do not. A
width given (`fill()`, `px`) is kept. A strip is as tall as its parent (`pct(1)`), and its items are usually `pct(1)` of
it: give the row a height of its own, never `children_sum`.

The items are the boxes built directly in the strip. The arrow's step reads their places: an item wrapped in a box of
its own counts as that box.

## API

| Call | What it does |
|---|---|
| `if ui.strip(id, o) { items }` | A strip. `Strip_Options`: `step` (`.Item`, the default, or `.Page`), `fade` (the width each edge that hides items fades over, ems; 0: `ui.STRIP_FADE_EM`, never less than an arrow). |
| `ui.strip_view(id)` | The box that holds the items of the strip built last with `id` in the current parent: its role for a screen reader goes there (a tab list's), and a test reads its offset (`view_off.x`) and its limit (`ui.view_limit(box, .X)`). |
| `.Wheel_Sideways` | The box flag a strip's view has: a `.View_Scroll_X` box that an up-and-down wheel scrolls sideways while it overflows. |
| `.Scrollbar_None` | The box flag a strip's view has: no bar, no room for one ([scroll-bar.md](scroll-bar.md)). |

The boxes a test finds by name: `strip_left` and `strip_right` (the arrows, inside the strip), `strip_view`.

## When a row is not a strip

- A bar of tools that wraps onto more lines or folds its rare tools into a menu: `ui.toolbar` ([toolbar](widgets.md)).
- A path whose leading folders fold into a "…" menu: `ui.path_bar` ([path-bar.md](path-bar.md)).
- A few equal choices that always fit: `ui.segmented`.
- Content that is read (a wide table, a code block): a box with `.View_Scroll_X` and its scroll bar.
