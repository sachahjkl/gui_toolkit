# preview: content that zooms and pans

`ui.preview` shows content (a picture, a page, a diagram) in a box: it fits there first, then the user zooms and moves
it. Every program that shows a picture or a document has the same gestures, and none draws them again.

```odin
app.pv: ui.Preview                                        // one per thing shown: ui.preview_reset when another comes
ui.next({width = ui.fill(), height = ui.fill()})
r := ui.preview_image("###shot", &app.pv, tex, {f32(w), f32(h)}, {buttons = true, radius = 6})
// or any drawing: the content's size in its own units, and a proc that draws it into a rectangle of the screen
r = ui.preview("###doc", &app.pv, {doc_w, doc_h}, draw_doc, doc, {buttons = true})
// r.percent: the zoom shown; r.changed: it moved this frame; r.fit: device pixels per unit when it fits
```

| Gesture | What it does |
|---|---|
| the wheel | zooms by `PREVIEW_ZOOM_STEP` a notch, around the pointer; with `wheel_pans`, moves the content (Shift: across) |
| Ctrl and the wheel | with `wheel_pans`: zooms around the pointer (a touchpad's pinch, which Windows sends as Ctrl and the wheel); the interface keeps its own zoom (`.Ctrl_Wheel`) |
| a drag | moves the content, when it is larger than the box (the pointer is a hand); never past its edges |
| a double click | from what fits to the content's pixels (twice them when it fits at its pixels), and back |
| +, −, 0, the arrows | with the keyboard on it (a click gives it): zoom in, out, fit, move by `PREVIEW_KEY_PAN` of the box |
| the bar (`buttons`) | over the bottom right corner: the zoom in percent, −, +, 1:1, Fit |

The content's unit is a device pixel at 100 %: an image's pixel. Fitted, it is no larger than that unless `grow`
(a small picture is not blown up). `Preview_Options`: `buttons`, `grow`, `zoom_min` (of what fits, `PREVIEW_ZOOM_MIN`
by default), `zoom_max` (device pixels per unit, `PREVIEW_NATIVE_MAX`), `radius` (an image's corners), `no_keys` (the
keys are the program's), `wheel_pans` (the wheel moves, Ctrl and the wheel zoom: a diagram or a document larger than its
box, read by moving through it). `preview_fit`, `preview_zoom_to` and `preview_pan_clamp` are its steps, for a view of a
program's own. `tests/preview` tests them, and the gestures in a session.

The keys need the keyboard on the preview. A dialog that is all preview gives it at once: `ui.set_focus(r.box.key)` in
the build that opens it.

`Preview` is the caller's state: a dialog's size and the preview's zoom and pan are separate, so the person makes the dialog
any shape, and the content fits it again (`preview_reset`) or keeps its zoom. The node graph (`node_graph`) keeps its own
view (`Graph_View`): a canvas without edges, whose zoom glides; it does not use `Preview`.
