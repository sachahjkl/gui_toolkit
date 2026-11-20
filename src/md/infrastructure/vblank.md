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

Today no backend starts a frame late. Windows' frame waits for its latency object, which the WebGPU backend arms to the
vblank that shows the previous frame (`wgpu_present_done`): the frame then starts at the beginning of its period, and
its input waits there a whole period minus the build. The late start is the next step; it reads the same two facts on
every system, so Linux gets them first.

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
  the counts of shown and discarded pictures). The renderer reads them at its next present
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

## X11

Next round: the Present extension's `CompleteNotify` gives the same (ust, msc) pair; it fills the same fields.
