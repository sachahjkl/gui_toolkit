# The cadence model: when a frame starts and how it is shown

`platform/pacing.odin` (with its clock, `platform/frame_slots.odin`), pure logic (no window, no clock, no swap chain);
`tests/pacing` and `tests/frame_slots`.

An application that draws only when something moves has to decide, for each frame, when it starts, whether it waits for
the screen, and whether it is shown at once. Those decisions used to be a pile of special cases and switches added one
problem at a time; the real defect was that the model had no variable refresh screen in it. Here the model is explicit:
**a clock, a state per frame, and one pure decision**. The application executes the decision; the decision never looks at a
window or a clock.

## The clock

`cadence_plan(display, choices)` turns the screen (`Display_Info`: the rate it reports, its top mode) and the application's
choices (`Cadence_Choices`: a target rate, a ceiling, `Variable_Refresh`, tearing) into a plan:

- the rate aimed for: the target, else the screen's top useful rate (on a variable or dynamic refresh screen, its top mode,
  not the 60 Hz it reports at rest), under the ceiling; its period is the frame budget;
- vsync refreshes per frame (`interval`), and whether the application times the frames itself (`timed`: tearing, a variable
  screen, a rate the screen's does not divide);
- `slots` (`Frame_Slots`): a grid of slots one period apart that no frame starts before. Strict where the application is
  what paces (timed); a loose net (0.9 of a period) where the screen's refresh does, which tightens by itself when it finds
  nothing else pacing.

## The states

Each frame is in the first state that applies:

| state | when | slot | waits for the swap chain | Present | frames queued |
|---|---|---|---|---|---|
| `Resize_Step` | the window has a new size (after the first present) | no | no | at once | 2 |
| `Input_Answer` | user input, and the window was at rest (the loop slept, or nothing presented for `CADENCE_INPUT_REST_PERIODS` = 1.5 periods) | no (the next slot is a period after it) | no | at once | 2 |
| `Resize_Burst` | within `CADENCE_RESIZE_HOLD_NS` = 120 ms of a size change | yes | yes | at once | 2 |
| `Rest` | the loop slept and no input woke it: a new run of slots starts | yes (now) | yes | at the refresh | 1 |
| `Drag` | a pointer drags something inside the window (splitter, panel handle, tab) | yes | yes | at the refresh; **at once on a variable refresh screen** | 1; 2 at once |
| `Continuous` | frames follow one another (animation, wheel, a pointer sweeping the window) | yes | yes | at the refresh | 1 |

Nothing waits for the swap chain before the first present (a swap chain never shown releases nothing), nor when the frame
already holds its slot (`slot_held`: a wake that made no frame).

Why each one:
- **Resize step**: the composer would stretch the last frame, drawn for the old size, over the new one until a frame at the
  new size reaches the screen.
- **Input answer**: a click or a key answered at the next composition, not one or two refreshes later. Only the frame that
  *starts* an answer: during a drag every frame was shown at once, hundreds a second piled up in the swap chain, which
  showed them one per refresh, and the picture advanced in jumps.
- **Resize burst**: a program that resizes the window from outside (AltSnap) waits for the thread at every step; a frame
  asleep in Present for a refresh stalled each step.
- **Drag**: a panel dragged inside the window keeps the window's size; as a resize step it would skip the slot, a frame a
  millisecond under a 1 kHz mouse. On a variable refresh screen (`Cadence.variable`, the plan's) its frames are shown at
  once, two queued, as a resize's burst: there a frame that waits for a refresh waits for the rate the system reports, which
  a dynamic refresh rate keeps at 60 Hz at rest, while a frame shown at once is on screen when it comes (G-Sync, FreeSync:
  the screen follows the frames up to its top rate). The slot still paces them: one frame per period of the top rate,
  whatever the mouse's rate. Measured on a 180 Hz G-Sync screen that Windows reports at 60 Hz (Wren's window not shown,
  a 1 kHz pointer on a splitter): 62 frames a second, 16.6 ms apart, every one waiting for the 60 Hz refresh, before;
  183 a second, 5.5 ms apart, after. On a fixed refresh screen a drag still waits for the refresh (at once, a frame would tear and
  come no sooner). The other runs of frames (`Continuous`: an animation, the wheel) are not changed.
- **Continuous**: one frame per slot, whatever the input rate: a mouse at 1 kHz makes one frame per period, not per move.

## Use

The renderer does all of it for a window (render/pacer.odin): the plan adopted when the display changes, the swap chain's
slot waited for, its latency set:

```odin
at_once := render.pace_frame(&pacer, &r, win, idled = slept, dragging = ui.active_key() != 0)
events := platform.poll_events(win, false)
// ... build, draw ...
render.frame_end(&r, !at_once)
render.paced_present(&pacer)
```

It does not show input after a rest at once (`input = false`): measured in opencode native (RENDER_PROBE, a fast hand
over a list, six runs each way), presenting that one frame without a wait for the refresh left the swap chain a frame
deeper for the rest of the session: 45 to 60 ms from input to screen instead of 29 to 30. (`platform.input_pending`
says whether input waits, for an application that measures otherwise.)

By hand:

```odin
plan := platform.cadence_plan(platform.display_info(w), {target_hz = 0, max_hz = 0, variable = .Auto, tearing = false})
platform.cadence_adopt(&c, plan)           // its slots and its screen (again when the monitor or its rate changes: Display_Info.serial)

d := platform.frame_decision(&c, {now_ns = now, idled = idled, input = input_waits, presented = shown_once,
                                  resized = size != last_size, dragging = dragging, slot_held = slot_held})
// wait d.wait_ns (taking input meanwhile); if d.wait_swap_chain, wait for the swap chain's latency object;
// set the swap chain's maximum latency to d.latency; make the frame;
// Present with no wait for a refresh when d.present_at_once
platform.cadence_presented(&c, now)
```

- `cadence_inner_frame(c, resized, presented)`: a frame made inside another one's work or a loop of the system (an
  interface-only frame): no slot of its own, only a new size changes its state; returns whether it is shown at once.
- `cadence_echo(c, step, events, tasks, wants)`: a frame of a resize's burst that would only show the step's picture again
  (nothing came, nothing wants a frame): the application does not make it. One picture per step instead of three.
- `cadence_at_once(c)`, `cadence_resizing(c)`: the last decided frame's.
- `Cadence.counts`: frames decided in each state (statistics).

## The frame's time

`frame_clock_advance(clk, now_ms, period_ms, grid_last_ms, grid_period_ms, slot_ms, has_slot)`: the time the frame shows
(animation timestamps, a CSS clock, smooth scrolling). On a screen with a vblank grid it is the vblank the frame starts at,
so motion advances by whole refresh periods whatever the jitter of the thread's wake-ups; on a timed cadence, the slot the
frame was timed for. Never before the previous frame's; `dt` is clamped to 0.5 .. 100 ms.

## What is a choice and what is not

The application's choices are the target rate, the ceiling, `Variable_Refresh` and tearing. The rest follows from the
screen and the model: there is no switch to turn a resize step or an input answer off, and the constants
(`CADENCE_INPUT_REST_PERIODS`, `CADENCE_RESIZE_HOLD_NS`, `FRAME_SLOT_*`) are part of the model, tested by its simulations
(`tests/pacing`: fixed refresh, variable refresh, tearing, a 1 kHz mouse, a resize, a panel dragged, a splitter dragged on
a variable screen that rests at 60 Hz, AltSnap).
