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
- Refused: asking for a repaint at every word (the window at rest drawn at every refresh); a timer at one refresh (the
  compositor's pace is the one to follow, and it may hold the word for a hidden window).
