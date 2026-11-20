# When a picture reaches the screen: the vblank timing

The pacer and the frame statistics need two facts from the screen: the time of a recent vblank and the period between
two. Windows reads them from the compositor (`DwmGetCompositionTimingInfo`, `wgpu_latency_windows.odin`; DXGI's frame
statistics on Direct3D 11, `present_collect`). Linux read none: `measured_refresh_hz` was 0, `vblank_grid` said unknown,
and a frame after a rest took the output's announced rate as its dt.

## The rule: latency first

When a frame on time and a frame on the grid conflict, the frame on time wins.

- **A frame starts as late as it can and still reach the next vblank.** Its input is read as close to the display as
  possible. The start is the next vblank minus the time the frame takes to build and draw, minus a margin.
- **A late frame is shown as soon as it is ready.** It is never held a whole period to land on the grid: a frame held
  shows input one refresh older than it needs to. `frame_slot_wait` already does not catch up a late slot
  (`frame_slots.odin`: "a frame later than a whole gap does not try to catch up"); the Wayland window presents in a
  mailbox, which the compositor shows at its next repaint with no barrier (`wgpu_pick_present_mode`).
- The vblank timing feeds that start. It never delays a frame by itself.

Before the start just in time, Windows' frame waited for its latency object, which the WebGPU backend arms to the vblank
that shows the previous frame (`wgpu_present_done`). The frame then started at the beginning of its period, and its
input waited there a whole period minus the build.

## The start just in time

`frame_decision` (`platform/pacing.odin`, `jit_start`) times a frame of a continuous run (an animation, a scroll, a
drag) to the deadline of the refresh after the previous picture's:

    start = vblank of the previous picture + period − lead − cost − margin

- **The vblank of the previous picture** is the grid's (`render.vblank_grid`: the last vblank shown, the period)
  projected to the first vblank whose deadline its present made.
- **The lead** is how long before a vblank a present must be made to be shown at it. The compositor sets it, and it
  differs by a whole period between compositors. Sway composes at the vblank before (a lead of about a period), KWin and
  Mutter a few ms before the vblank, and DWM at the vblank. It is learned from the display server's answers (each
  picture's present time against its vblank: `Vblank_Timing.lead_ns`):
  - a picture shown one refresh later than the lead predicted proves the deadline was earlier: the lead jumps past that
    bound, plus half a millisecond;
  - a picture shown earlier than predicted proves it was later: the lead drops to what that picture took;
  - each picture on time lowers the lead by a twentieth of a percent of a period. It probes later, so input is read
    later, and a change of the compositor is followed. The price is one picture a refresh late every few seconds. The
    person's priority accepts it: latency over frame-perfect sync.
  - a picture two refreshes late or more is a hiccup or a queue, not a deadline: no sample.
  Direct3D 11 learns it the same way from DXGI's frame statistics (`present_collect`). Windows' WebGPU backend has no
  answer per picture: its lead is the model it already presents with (the GPU margin plus the lag it learns from its
  acquires).
- **The cost** is the time from a frame's start (its waits done, its input about to be read) to its present
  (`Frame_Cost`): the 90th percentile of the last 32 frames, not the mean. Half the frames of a mean are slower than
  it, and each of those misses its refresh.
- **The margin** (1 ms) covers what the cost does not see: the GPU after the present call, the scheduler's wake.
- **A frame later than its start goes at once.** It is never held to the next deadline: it may still make its refresh
  (the cost is a high percentile), and if it does not, it is shown at the next one, as soon as it can be.
- **A key or a button ends the wait** (`wait_slot`, as the slot's): a press is answered now.
- **The start paces the frames, not the slot's grid.** A frame timed so counts no delay of the loose grid, and its next
  slot counts from its start. Otherwise the grid sees itself delaying every frame (the decision comes just after the
  previous present, a period before the start), and after `FRAME_SLOT_ESCALATE` frames it becomes strict. A strict grid
  means "nothing else paces the frames" and turns the start just in time off.
- **Only in a run.** The first frame after a rest goes at once, with no previous picture to time it from. So do a
  resize's steps and burst, the frames shown at once, a screen that does not pace the frames (variable refresh,
  tearing: `Frame_Slots.strict`), a frame every n-th refresh, and a window whose timing, lead or cost is not known yet.
  The slot grid keeps its role there.
- **No setting.** One rule serves the person's priority on every screen. A choice "steady" (a fixed early start)
  would only trade latency for the rare repeat that the lead's probe costs.

Refused:

- **The mean of the frame times.** Half the frames would miss their refresh.
- **A fixed margin with no estimate of the frame's cost.** A margin large enough for a heavy frame wastes the latency it
  is meant to win on a light one, and one small enough for a light frame misses with a heavy one.
- **The next vblank after now as the target.** A Windows frame decides just after its previous present, before the
  vblank that shows it: that vblank's deadline is past, and the frame started at once. The target is one refresh after
  the previous picture's, wherever the decision is made.
- **A fixed lead per system.** It is wrong by a period on one compositor or the other, and a wrong lead costs a whole
  period on every frame.
- **Holding a late frame for the next deadline.** See the rule.

## Wayland: the presentation-time protocol

`wp_presentation` (stable) gives, for one commit, either `presented` (the time the picture turned to light, the
refresh counter of the output, `refresh`: the period in ns, 0 when unknown or variable) or `discarded` (a later commit
replaced it before any repaint, or the surface was not shown).

- **The renderer asks one feedback just before each present** (`platform.vblank_ask` in `wgpu_frame_end`), which
  commits the surface. That gives exactly one feedback per commit, for any program's loop, even while the word of the
  last picture is still pending (a window whose presents do not wait). Refused: asking it with the frame word
  (`frame_shown_ask`, [frame-loop.md](frame-loop.md)). The host gives that word up while its picture is on its way (its
  patience). A frame that asks the word and then presents nothing would leave its feedback to the next commit, and that
  commit would be counted twice.
- **The answer is kept in the window, as numbers** (`platform.Vblank_Timing`: the last vblank, its counter, the period,
  the lead, the counts of shown and discarded pictures). The time of each present is kept with its feedback, for the
  lead. The renderer reads them at its next present
  (`platform.vblank_timing`, `wgpu_compositor_timing`) and fills the fields Windows fills (`period_ns`, `sync_tick`,
  `sync_count`, `displayed`, `missed`).
- **The answer ends no wait.** It changes nothing on screen and asks for no repaint: `wl_wait` returns only on what
  `wait_is_over` sees. A window at rest gets one answer for its last picture, then nothing.
- **The time is moved to the toolkit's clock.** The compositor announces its clock (`clock_id`, CLOCK_MONOTONIC on
  sway, KWin and Mutter); `core:time`'s ticks are CLOCK_MONOTONIC_RAW. The timestamp is moved by the distance of the two
  clocks read at the answer. The two drift by parts per million (NTP's slew): nothing over the frames that use it.
- **The period is the compositor's `refresh` when it gives one, else measured** from two answers' (counter, time) pairs,
  as `present_collect` measures DXGI's. A jump of the counter over a long rest is no sample. A compositor may give
  neither (sway's headless output answers with `refresh` 0 and `seq` 0): then the gap between two pictures shown is a
  whole number of refreshes, counted against the period known, first the output's mode, and a gap of more than four
  refreshes or off by a fifth measures nothing. Refused: the smallest gap seen as the period (one early answer and the
  rate is wrong for good).
- **`shown` counts the pictures the compositor says it showed**, not the presents. `missed` counts, in a run of
  continuous frames, the refreshes that the counter moved beyond what the frames explain, as on Windows. A discarded
  picture is not a missed refresh: a window that presents faster than the screen (a mailbox, a window that does not
  wait) has some by design. It has its own count (`Vblank_Timing.discarded`).
- **A compositor without the protocol** leaves the numbers at 0:
  `measured_refresh_hz` stays 0 and everything falls back to the output's mode, as before.

## Refused

- **Holding a late frame until the next slot of the grid.** It keeps the frames evenly spaced and adds up to a period of
  latency to the frame that a person waits for.
- **A timer at an assumed rate.** The announced mode is not the rate a compositor shows a window at (variable refresh,
  a covered window, an output it does not repaint). Only the compositor's answer says when a picture was shown.
- **The `wl_surface.frame` time as the vblank.** Its `time` is in ms, on an unspecified base, and a compositor sends it
  when it repaints, not when the picture is on the screen.
- **Reading the timing in the renderer from Vulkan** (`VK_GOOGLE_display_timing`, `VK_KHR_present_wait`): wgpu-native
  exposes neither, and Mesa builds them on this same protocol.
- **Counting a discarded picture as a missed refresh.** See above.

## X11: the Present extension

`PresentCompleteNotify` gives, for each picture of a window, the time it reached the screen (ust, µs, CLOCK_MONOTONIC),
the refresh counter (msc), and its mode: Copy, Flip and SuboptimalCopy were shown, Skip was never shown.

- **One selection per window, at its making** (`x11_present_select`, under an event id of ours). Vulkan's WSI presents
  on our connection and reads its own answers under its own id, in a queue of its own (`xcb_register_for_special_xge`).
  The server sends each answer to every selection on the window, whoever presented (xserver's
  `present_send_complete_notify`): ours comes to the connection's general queue.
- **The answers are matched to the presents in order.** The renderer notes each present's time (`vblank_ask`); each
  Pixmap answer takes the oldest. The answer's own serial is the WSI's, not ours. A NotifyMSC answer (a wait for a
  refresh, no picture) is not counted.
- **The answers end no wait.** `x11_wait` sleeps on while only they come (`X11_Conn.loud` counts every other event).
  Before, any event ended it, and the WSI's own traffic did too.
- **A software WSI draws with PutImage** (lavapipe on Xvfb): no answer comes, and the numbers stay 0. The desktop test
  says so and checks nothing more there.
