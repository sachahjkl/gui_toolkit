# The frame gate: one state machine for the frames of a thread

`platform/frame_gate.odin`, pure logic (no window, no clock); `tests/frame_gate`.

A thread draws its windows, and several things can ask for a frame while it is making one: a loop of the system that pumps
the thread's messages and paints from `WM_PAINT` (live resize, a menu, Alt+Space, a modal dialog, a drag and drop:
`on_frame`), the application's own preemption of long work (a frame of its interface between two steps of the work), another
window's frame. A frame begun in the middle of another's build builds the interface inside the one being built: the outer
build goes on with what the inner one left. The gate makes such a frame wait: **a frame asked for where none may begin is
deferred (the window repaints at the next pass), never nested.**

```
Idle -> Polling -> [Work] -> Building -> Drawing -> Presenting -> (end: the stage the frame began in)
```

| stage | the thread is | a Full frame may begin | a Light frame may begin |
|---|---|---|---|
| `Idle` | between frames | yes | yes |
| `Polling` (of a Full frame) | waiting and polling: a loop of the system begun here makes its frames first | yes | yes |
| `Polling` (of a Light frame) | the poll of a frame that interrupts work | no | yes |
| `Work` | the application's work for the frame (a browser's page phase) | no | yes |
| `Building`, `Drawing`, `Presenting` | building, drawing, presenting | no | no |

A **Full** frame does the application's work and its interface (`Polling -> Work -> Building -> Drawing -> Presenting`); a
**Light** frame draws the interface alone over the last picture and skips `Work`. A frame may end at any stage.

```odin
g := platform.frame_gate()                         // the calling thread's
tok, ok := platform.frame_gate_begin(g, .Full)     // refused: counted as deferred, ask for a repaint instead
if !ok { w.paint_requested = true; return }
defer platform.frame_gate_end(g, tok)              // the outer frame's stage comes back
events := platform.poll_events(w)
platform.frame_gate_stage(g, .Work)
...
platform.frame_gate_stage(g, .Building)
ui.begin_build(...); ...; ui.end_build()
platform.frame_gate_stage(g, .Drawing)
...
platform.frame_gate_stage(g, .Presenting)
render.frame_end(...)
```

- A move the machine does not have (backwards, a skipped build, a stage set outside a frame, a Light frame doing work, a frame
  ended twice) is a **violation**: counted (`violations`, `last_violation`), and a panic when `g.strict` is set (a debug
  build), so that the mistake fails where it is made.
- The window procedure consults the gate: a `WM_PAINT` where no frame of any kind may begin is deferred without calling
  `on_frame`. A repaint from a loop the toolkit pumps itself (a drag: `drag_start`, `drag_script`) is deferred too.
- An application that never calls `frame_gate_begin` stays `Idle`: everything is admitted, as before.
- `frame_admits(stage, outer, kind)` and `frame_transition_ok(from, to, kind)` are the table and the moves, for tests and for
  an application's own questions (`frame_gate_admits_any` is the window procedure's).
- Statistics: `begun`, `nested` (inside another frame), `deferred`, `violations`.
