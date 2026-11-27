# A box dragged out

The code is `src/ui/drag_out.odin`; a program's author reads [docs/dragdrop.md](../../../docs/dragdrop.md).

## Why

galerie drags a picture's file out of its strip, its grid and its picture to another program. It wrote the steps
itself (`Drag_Out`: the threshold, one drag a press, a record in its tests), as the file tree had written its own. A
third program would write them again: they belong here.

## Decisions

- **The threshold is the system's** (`platform.drag_threshold`), measured from the press (`Signal.drag_delta`):
  a click's wobble is no drag. `drag_past_threshold` is the one test; the tree's rows use it too.
- **One drag a press.** `Drag_Out` keeps the box whose press started a drag until that press is let go. The system's
  drag holds the thread until the drop, so a working drag ends with the button up; a drag the system refuses
  (Wayland without a serial) or an offscreen window's returns at once, with the button still down. Without the rule,
  the next build started it again, every frame: the file tree did (seven drags in one gesture in its test).
- **An offscreen window records.** `platform.drag_start` refuses there (no script); the files go to
  `Drag_Out.recorded` so a test checks what would have gone, with no system's drag. A scripted drag
  (`drag_script`) still runs as before: it is a drag that succeeds. Refused: a `headless` flag that the program sets
  (it is the window's to know), a callback (a test reads a list).
- **The data is made at the start only** (`drag_out_files`): a strip builds every cell each frame; a `Drag_Data` for
  each would be made for nothing.
- **A program that decides when the drag leaves** (the file tree: rows moved inside the tree, the system's drag past
  the window's edge) calls `drag_out_start` itself and keeps the press rule (`Tree.drag_spent`).

## The state machine

Idle -> Pressed (`sig.dragging`, under the threshold) -> Out (`key`, `started`: the drag ran or was recorded) -> Idle
when that press is let go.
