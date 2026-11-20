# The wheel picker (`ui.wheel`, `ui.wheels`) and the parts field (`ui.parts_field`, `ui.duration_field`)

A column of values on a drum that turns: the row under the band in the middle is the value. A person spins it with the
wheel of the mouse or a touchpad, drags it and lets it go, clicks a row, or uses the keys. A value of a few parts (a
duration, a time of day, a date) is a field whose parts are typed or stepped one by one, and whose drums open below it
on a click. Its first user is socle's screen lock delay: hours and minutes.

## The field

- **The field is the value; the drums are a way to set it.** A field of parts reads as one value in a line ("1 h 30
  min") and takes the keyboard as a time field of a web page: Left and Right choose a part, Up and Down step it, digits
  replace it. A click opens the drums below it, on the part clicked. Refused: drums always shown (five rows of height
  for a value of one line, in a page of settings), and drums only (no way to type 45 without a spin).
- **Digits go on by themselves.** Digits typed replace the active part; once no more digit fits (a second one would
  pass its end, or it has as many digits as its end), the next part becomes active. "1", "3", "0" typed in an hours and
  minutes field gives 13 h then 0 min, with no key between.
- **One description, two controls.** A part (`Field_Part`: its bounds, its step, its format or labels, its unit, a
  separator before it, whether it wraps) makes both its piece of the field and its drum. A duration, a time of day and
  a date are lists of parts, not three widgets.
- **The field shows the drum as it turns.** While a drum turns, its part in the field shows the row at its band; the
  value changes when the drum rests (below). The field and the drum never disagree on screen.
- **A value the keys change turns the drum.** With the drums open, Up on the field's minutes turns the minutes' drum,
  through the drum's "the program chose another row" path: one source of truth, the values.
- **It closes by itself.** A press outside the field and its drums, Escape, Enter or Alt+Up close the drums; the
  program may own whether they are shown (`Parts_Field_Options.open`), to open them from elsewhere.
- **A duration's bounds are on its sum.** `ui.duration_field` keeps its total between `least` and `most`: 0 h 00 min
  with `least` one minute becomes 0 h 01 min, and the drum turns to 01.

## The drum

- **One continuous position, two motions.** The drum keeps a fractional row (`pos`), a speed (rows per second) and a
  target row. A drag sets `pos`; a notch, a key, a click or the program moves the target, and a damped spring carries
  `pos` there from wherever it is, at whatever speed it has. A new aim during a motion starts from that motion's speed:
  notches in a row add up into one smooth turn.
- **A throw picks its row at release, then glides to it.** The target is the row where the speed would carry the drum
  (`pos + speed × WHEEL_THROW_S`), rounded. The drum goes there on a cubic ease-out whose length makes its start speed
  the hand's: no jump and no brake when the finger lets go, and it ends on the row in a known time (at most
  `WHEEL_GLIDE_MOST_S`). Refused: a soft spring for the throw (its exponential tail kept the drum creeping for 1.5 s,
  so the value came long after the drum looked still), and a free deceleration then a snap (a second, visible motion).
- **The spring is slightly under-damped** (`WHEEL_SNAP_DAMPING` < 1). The drum passes its row by a few hundredths and
  comes back: the click of a detent, seen. More reads as a wobble; critical damping reads as glue.
- **The value changes when the drum comes to rest**, not at each row it passes. A spin through forty rows to reach one
  gives the program one change, not forty: a program that builds or saves on each change (socle's draft) does it once.
  A row passing the band is still felt: its text takes the band's colour as it crosses it, and the band's rim lights
  for an instant (the tick).
- **A value the program changes moves the drum.** When the program's index differs from the row the drum rests on
  (a preset chosen beside it), the drum turns to it with the same spring. Nothing is fed back as a change.
- **The drum is drawn as a cylinder.** Row `d` rows from the band is at angle `d × 2 / rows` on a cylinder whose radius
  is half the box's height: its centre is at `R sin θ`, its height scaled by `cos θ`, its alpha by `cos θ`. A row at
  90° or more is not drawn. The rows keep their size at the band and crowd at the edges, as a real drum's.
- **Each row is drawn twice, cut by the band.** Weak outside the band, the text's colour inside (two clips). A number
  that crosses the band changes colour along a straight line, as on a physical picker under a lens. A colour that
  depends on the distance fades instead and the chosen row does not stand out.
- **Ends: a bounded drum stretches, a wrapped one loops.** Past its first or last row a drag moves the drum by a third
  of the hand's motion and the spring brings it back. With `wrap`, rows are indexed modulo their count: minutes go from
  59 to 00.
- **The wheel turns it in a view that scrolls too.** `ui.slider` takes the wheel there only once focused (wheel_steps),
  so that a page scrolls past it. A drum is the opposite: the wheel is its main input, and it sits in a popup or in a
  short form. The drum takes the wheel whenever the pointer is over it. A program that puts drums in a long page that
  scrolls sets `Wheel_Options.wheel_when_focused`.
- **Fractions of a notch move it.** A touchpad's deltas add to the target as fractions, then the target is rounded when
  the deltas stop: a slow swipe moves the drum smoothly instead of row by row.
- **Labels on demand.** `ui.wheel` takes the labels of a short list; `ui.wheel_number` makes the text of the rows it
  draws only (seven at most): a drum of 0 to 999 costs the same as one of 12.
- **A group shares one band.** `ui.wheels` is a row whose drums draw no band of their own: the group draws one plate
  across them, so "1 h 30 min" reads as one value. A drum alone draws its own band.
- **Typing goes to a row.** Digits or letters typed while the drum has the keyboard find the first row that starts with
  them (a list's type-ahead, reset after `WHEEL_TYPE_MS`): "45" goes to 45 without a spin.
- **Animations off: no motion.** The drum is at its target at once; a drag still follows the hand.

## Subtle points

- The speed of a drag is an average of the last moves (an exponential of the frame's motion), not the last frame's: a
  hand stops a frame before it lets go, and the last frame alone reads zero.
- A press that does not move more than a few pixels is a click: the row under the pointer becomes the target. A press
  that moves is a drag and never a click.
- The rows' positions come from `pos`, not from the target: what is drawn is where the drum is.
- The field finds the part under a press by the parts' boxes of the last frame: the boxes of this frame have no place
  yet.
