# The frame loop and the compositor's word

A program's loop (`host.hosts_wait`, then `host.host_frame`) sleeps until a frame is due: input, a timer, or something
that moves or settles (`ui.needs_frame`, `Host.settle`). Docs: [docs/platform.md](../../../docs/platform.md), "A window
not shown".

## The word that the last picture was shown

On Wayland the compositor says when it showed a window's picture (`wl_surface.frame`). While that word is pending, a
frame due waits for it (`frame_shown_pending`): a picture presented before it would queue behind the last one.

- **The word asks for a repaint only when a picture waits for it** (`frame_shown_held`). A repaint at each word drew a
  window at rest again at every refresh, for ever.
- **What moves waits for the word in `hosts_due`, before any frame, so `hosts_due` says it waits** (`frame_shown_held`,
  `Host.word_due`). Only `host_frame` said it, and the loop never reached `host_frame`: an animation with no input
  moved only when the pointer moved, or at the patience's pace (`FRAME_SHOWN_PATIENCE_MS`, four pictures a second in a
  mailbox), and stopped for good in Fifo. A 300 ms tween took four seconds
  (`tests/linux_desktop`, `an_animation_moves_with_no_input`).
- **A wait for the word with a frame due is no rest** (`Host.slept` false). A frame after a rest takes one refresh as
  its dt, since the time slept is not time the animation lived; Linux measures no refresh (no vblank timing), so that
  dt was 1/60 s, and every frame of an animation on Wayland moved by 1/60 s whatever time passed.
- **The refresh of a frame after a rest is the measured one, else the window's screen's** (`display_info(w).hz`).
  A fixed 1/60 s moved an animation on a 144 Hz screen by more than two refreshes in its first frame. Wayland measures
  it from the compositor's presentation-time answers ([vblank.md](vblank.md)); X11 measures none yet.

## The rate of the output the window is on

`display_info` gives the pacer its plan (`cadence_plan`): the slots no frame starts before. On Wayland it read the
first `wl_output` bound, whatever output the window was on.

- **A wrong rate caps the frames, it does not only mislabel them.** A window on a 144 Hz output with a 60 Hz first
  output got a 60 Hz plan: its loose grid (0.9 of 16.7 ms) delayed every frame the 144 Hz compositor took, and after
  `FRAME_SLOT_ESCALATE` delayed frames the grid went strict. Every animation, scroll and drag ran at 60 frames a
  second. The other way round (a 60 Hz window, a 144 Hz first output) only mislabels `screen.refresh`: the screen
  paces the frames, and the loose grid never delays them.
- **Each output keeps its own mode's refresh** (`Wl_Output_Info.refresh_mhz`), and each surface the set of outputs it
  is on (`wl_surface.enter` minus `leave`, `Wl_Window_State.entered`). An enter, a leave, an output's `done` or its
  removal marks the windows' display stale: the next frame reads the rate again and the pacer replans on its serial.
- **A window on several outputs takes the highest rate.** The plan is a cap: too high, the screen still paces the
  frames and nothing is lost; too low, it caps them, as above. Refused: the output with the largest part of the window
  (what wlroots paces a surface by), since a Wayland client does not know where its window is; the output entered last
  (`window_output_name`), an order of events that says nothing of the rate.
- **A window on no output yet** (never shown, or between a leave and the next enter) reads the first output's, as
  before: it gets the right one with its first `enter`.
- X11 already read the monitor under the window's middle (RandR, `x11_randr_rate`), read again after each move: the
  fault was Wayland's.
- Refused: asking for a repaint at every word (the window at rest drawn at every refresh); a timer at one refresh (the
  compositor's pace is the one to follow, and it may hold the word for a hidden window).
