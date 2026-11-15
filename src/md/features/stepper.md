# The stepper (`ui.stepper`)

A row or a column of nodes joined by connectors: the stages of a long work (unpack, install, check), each pending,
under way, done, failed or skipped. The first user is atelier, the suite's installer: one stepper of three or four
nodes per program, in a row of a list, several programs installing at once.

## Decisions

- **The program owns the states; the stepper owns the motion.** A step is a value the program gives at each build
  (`Stepper_Step.state`); the stepper keeps nothing of the program's. What it keeps is when each node entered its state,
  in the State's animations (`State.anims`), keyed by the node's key and the state. A new state is a new key, so its
  clock starts at 0 by itself: no "previous state" to remember, no comparison, no reset. The key of the state left is
  not touched any more and the State drops it after a build, as every animation.
- **A node seen for the first time is settled.** A stepper that opens on a program already half installed shows its
  done steps done, not a cascade of checks. "First time" is the node's box's first build: a row that scrolls back into
  a list does not play its checks again either.
- **The clock is the build's `dt`, as `tween`'s**, not a start time stored in the animation: a `f32` cannot hold a
  `time_ms` to the millisecond, and `session.advance` moves `dt` frame by frame, so a test steps the animation exactly.
  With animations off (`anim_rate` 0) every clock is at its end: states jump, nothing asks for a frame.
- **What a node draws is a pure function of its state and two clocks** (`stepper_look`): the ring, the turning arc,
  the disc's scale, the mark and how much of its stroke is drawn, the share of the connector after it that is filled.
  The tests check that function and the clocks; the draw procedures only read a look.
- **Frames only while something moves.** An Active node asks for frames as `ui.spinner` does (and none with animations
  off); a mark or a connector asks while its clock runs. A stepper at rest with no active step costs no frame.
- **Equal columns in a horizontal stepper.** Each step is an exact share of the stepper's width, its node at the
  middle of its column and its words wrapped under (or above) it. The nodes are then evenly spaced whatever the words,
  and a long word is cut by its column, never pushing its neighbours. Refused: nodes at the ends of the width (the
  first label then hangs out of the stepper, or is not centred under its node), and columns as wide as their words
  (connectors of every length).
- **Nodes and words are two rows** (horizontal) so that words above the nodes keep the nodes on one line whatever the
  number of lines of each label: the row of words aligns its columns at the nodes' side.
- **The connectors are drawn by the stepper's box**, from the edge of a node to the edge of the next, after the layout,
  from the nodes' rects. One procedure serves every direction: a reversed stepper only builds its steps in the other
  order.
- **One node for a screen reader**: a progress indicator whose value says the step in words ("Step 2 of 4: Install,
  in progress") and whose number is the share of the steps finished. Its labels are not read again as loose text.
- **Colours from the palette, overridable per stepper** (`Stepper_Colors`) and **per label** (`Stepper_Step.color`, or an
  intent's hue made readable on the page). Done words are a tint of the text toward the success hue, not the hue: a
  list of green labels shouts. Failed words are the danger hue made readable: a failure must be seen.
- **The disc is a face of the finish** (`paint_rect_corners` without a rim), flat with Glass, whose two halves are not
  a disc.

## Subtle points

- The disc pops with a small overshoot (ease out back) during the first part of the mark's time; the stroke starts
  before the pop ends. A disc that overshoots draws a little outside its box: the gap to the connector leaves room.
- The compact stepper keeps the words: they go to each node's tooltip, on a timer of its own (as `label_tip`), since
  a node takes no press: in a list, a press on it selects the row.
