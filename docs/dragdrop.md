# Drag and drop, fingers and pens (`platform`)

The API is the same on every system (`platform/dragdrop.odin`, `platform/pointer.odin`). Windows implements it
(`dragdrop_win32.odin`: OLE; `pointer_win32.odin`: `WM_POINTER`). Other systems build with `dragdrop_stub.odin`, which
answers "not supported" (`drop_target_enable` returns false, `drag_start` returns `ok = false`) and send no `Pointer_*`
events.

## Receiving drops

```odin
platform.drop_target_enable(win, true)        // false: refused (no OLE on this thread, an elevated process)
for e in platform.poll_events(win, false) {
	#partial switch e.kind {
	case .Drop_Enter, .Drop_Over:
		d := platform.drop_data(win)          // files, text, html, url (+ url_title), image (PNG), custom entries
		platform.drop_set_effect(win, accepts(d, e.pos) ? platform.drop_effect_for(e.drop_allowed, e.mods) : nil)
	case .Drop:
		handle(platform.drop_data(win)^, e.pos)
		platform.drop_data_release(win)
	case .Drop_Leave:
	}
}
```

- Events come at the pointer's position (client pixels), with the modifiers held and `drop_allowed` (what the source
  allows). The data is read once when the drag enters (and again at the drop, for sources that render late).
- The system asks synchronously what a drop would do; the app answers in its next frame with `drop_set_effect`. The
  window gives the system the app's last answer (nil = refused). This is what browsers do with their renderer.
- `drop_effect_for(allowed, mods, preferred)`: the usual convention (Ctrl copies, Shift moves, Ctrl+Shift or Alt
  links).
- Formats on Windows: `CF_HDROP`, `CF_UNICODETEXT`, `HTML Format` (the fragment is returned without its header:
  `html_format_fragment`), `UniformResourceLocatorW` / `UniformResourceLocator`, `PNG`, and a private format for the
  app's own MIME types (`Drag_Data.custom`, `drag_custom_encode`).

## Starting a drag

```odin
d: platform.Drag_Data
d.url, d.text = "https://example.com/", "Example"
effect, ok := platform.drag_start(win, d, {.Copy, .Link}, platform.Drag_Image{rgba, {w, h}, {w / 2, h / 2}})
```

`drag_start` blocks while the user drags (the system's loop runs) and returns the effect the target chose, nil when
the drag was given up. Call it between frames, from the press-and-move that started the drag; an app that wants
in-window drags without the system's loop handles those itself and calls `drag_start` when the pointer leaves the
window. `drag_threshold(win)` is the distance the system uses before a press becomes a drag.

## Tests and remote control

- `drop_inject(win, kind, pos, &data)`: the same events with data of the app's choice, through `inject_event`.
- `drop_self_test(win, data, pos, allowed)` (Windows): the data object `drag_start` would build goes through the window's
  own drop target, so both conversions and the events are tested without a mouse (`tests/dragdrop`).

## Fingers and pens

`Pointer_Down`, `Pointer_Move`, `Pointer_Up`, `Pointer_Cancel` carry `Event.pointer` (`Pointer_Info`: `id`, `kind`
touch or pen, `primary`, `pressure` 0..1, pen `tilt` / `twist` / `barrel` / `eraser`, touch `contact` size). The mouse
keeps `Mouse_*`, which now also carry `buttons` (the buttons held after the event). The system's emulation of the mouse
for a finger or a pen still arrives, marked `emulated`: an app that only knows the mouse works unchanged, one that
follows pointers skips those. `pointer_buttons` and `pointer_pressure` give the Pointer Events values.
