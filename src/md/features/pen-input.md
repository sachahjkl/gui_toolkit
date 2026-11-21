# A pen's pressure in a program

A drawing program (feuille's signature pad over `gt:ink`) needs the pressure of a pen at each sample. The user docs are
[docs/dragdrop.md](../../../docs/dragdrop.md) ("Fingers and pens") and [docs/ink.md](../../../docs/ink.md).

## One path for every system

A pen is a pointer of its own (`Pointer_*`, `Event.pointer`), and the mouse's emulation of it comes after it, marked
`emulated`. That was Windows' shape (the system emulates the mouse after `WM_POINTER*` reaches `DefWindowProc`), and
Wayland takes the same: a client that binds the tablet protocol gets the pen only as a tablet tool, never as
`wl_pointer`, so the backend makes the emulated mouse events itself. Widgets go on reading the mouse; a program that
wants the pen reads its info. Refused: a pressure field on the mouse events. It would make a pen a mouse with extras,
and a finger's or a pen's id, tilt and cancel would have no place.

## The device in `ui`

`ui` does not follow pointers; it keeps one `Pointer_Info`: the device that moved the pointer last in the build
(`pointer_device`). A `Pointer_*` event sets it; a mouse event that is not emulated makes the mouse the device again;
an emulated one changes nothing (Windows' carries only the kind). The value is the last event's of the frame, as
`mouse_pos` is: a pad samples once per build. Refused: a list of the frame's samples. No program asks for it, and
feuille samples per build.

## Two meanings of "no pressure"

Pointer Events say 0.5 for a contact whose device measures nothing, and `Pointer_Info.pressure` keeps that.
`gt:ink`'s `Sample.pressure` says 0 for "unknown", and then follows the speed. A constant 0.5 would give a constant
width, which is worse than the speed. So `Pointer_Info.measured` says whether the device gave the value, and
`ui.pointer_pressure` returns 0 unless it did and the tip is down.

## Wayland's tablet

- Version 1 of tablet-unstable-v2. Its tables are by hand, as every protocol's here (`wl_protocol_linux.odin`). The
  tablets and pads have tables too: the seat announces them with new ids, and libwayland must have an interface to
  make their objects. Nothing of them is read but their removal.
- The facts of a tool come one by one, then `frame`. `tablet_tool.odin` keeps them and gives the steps of the frame in
  order (move, down, up, cancel, leave). It touches no system, so a test drives it. A proximity out with the tip still
  down (no up came) cancels the press: the release is `lost`, as when a capture is taken away.
- The tip is the left button. Its press on the integrated title bar moves the window, with the down's serial.
- The pen's cursor goes through `wp_cursor_shape_v1.get_tablet_tool_v2`. Without that protocol, the compositor's own
  cursor shows: an image cursor on the tool's own surface was not worth its weight.
- The barrel button sets `barrel` only. It is not emulated as a right button: no compositor's convention was found to
  follow.

## X11

The toolkit's X11 backend uses no XInput 2. A pen there is the core pointer that the server makes of it, with no
pressure. XI2 for one valuator was refused for now: it takes a new extension's setup, device listing and event
selection. See [ROADMAP.md](../../../ROADMAP.md).
