# Transitions

Two pieces for a place whose content changes: `ui.tween`, a value that goes to its target along a curve in a set time,
and `ui.swap`, a place that shows one face at a time and morphs from one to the next. The first user is the update
badge (`prefs_page.update_badge`): "Install 0.42.0", then the download's bar, then "Restart to update to 0.42.0", in one
place of a program's bar.

## Why

`ui.anim` eases a value exponentially: fast at first, then a long tail. It suits what follows the pointer (a hover, a
drag's ghost): it answers at once and never overshoots. It does not suit a change that has a beginning and an end. The
last pixel of a width arrives many frames after the eye saw the move end, and anything that waits for that pixel (a face
that shows once its place is ready) waits for nothing. A change of face also needs what the old face looked like, and a
widget that is no longer built has nothing left to draw.

The update badge tried it by hand: a width eased by `anim`, a green pill while it moved, the new face shown once the
width settled. It showed eight frames of a wordless pill, then a pop. A button cannot be narrower than its words, so a
place narrower than its new face cut it.

## ui.tween

`tween(key, target, ms, ease) -> f32`: the value goes from where it is to `target` in `ms` along `ease`. A new target
starts a new run from the value shown now, so a change in the middle of a run never jumps. The first call shows `target`
(or `initial`). The animations off: the value is its target. A running tween keeps frames coming (`anim_busy`).

The frame that starts a run from rest moves nothing: the time since the last frame was a rest, not part of the run (a
dialog's fade, after a long idle, would jump by a third). A target turned during a run moves in that frame: a target that
changes at every frame (a download's share) would else never move.

The curves are few on purpose: `Linear`, `Out` (cubic: the start quick, the landing soft, for what appears or grows) and
`In_Out` (cubic: for a place that moves from one rest to another), `Sine` (gentle at both ends, its middle half as
steep as `In_Out`'s), and `Emphasized`: cubic-bezier(0.2, 0, 0, 1), Material 3's emphasized curve, a quick start and a
long soft landing, for a morph. It is evaluated as the bezier it is: x(t) = p solved for t (Newton's steps, bisection
when a step leaves the interval or the slope is flat), then y(t). A polynomial that looked like it was refused: the
curve is a named one, and its look is its numbers. A spring was refused: it needs a velocity kept and a stiffness to
tune, and nothing here asks for an overshoot.

A program's own transition takes its own curve: `tween_curve` runs as `tween` along a `Cubic_Bezier` (CSS's four
numbers), which the debug window's easing editor tunes (curve-editor.md). The toolkit's named curves stay few: a
program's curve is its own, not a sixth name. `ease_bezier` gives each named one as a cubic-bezier, the start of a
program's (Out, In_Out and Sine as CSS approximates them: their polynomials are not cubic-beziers).

## ui.swap

`if ui.swap(id, face) { ... }`: a box sized by what is built in it. `face` names what it shows now: "install",
"downloading", "restart". A swap's face is the first box built in it. Its **shape** is that box's own look: its rect, its
drawn radii, its face (box_face: colour, sheen, sunk) and its border. Its **content** is all the rest it draws: its words,
its custom draw's content, its children. Two things happen when the face changes:

- **Its size glides.** The layout computes the size of what is in it, as for any box sized by its children; a swap shows
  a size tweened from its size of the last frame to that one (`Emphasized`, `SWAP_MS`). Its neighbours move with it, frame
  by frame, as a place that grows. Only a change of face glides: a face whose own size changes (a count that grows by a
  digit) takes its new size at once, as any box.
- **The shape morphs, the content crosses.** Each frame the swap keeps its face's shape (a few numbers) and records its
  content bare (`draw.Picture`: the face box drawn without its shape, `box_bare`). On the frame the face changes, it keeps
  the old face's shape and record (two of each, the index of the current one flips: the draw context holds the pictures'
  addresses, so they are never moved or copied). During the run (p from 0 to 1, k = `Emphasized(p)`):
  1. one shape, from the old one to the new face's, its radii, colour, sheen and border on k, its rect along the axis
     the new face's own (below): the one thing the eye follows from the button to the bar;
  2. the old content, its main words hidden, fading out: `1 - k`;
  3. the real new face, whole, its main words hidden, fading in: `k`. Its edge and its relief come with it, a little
     each frame: a version that brought the new content bare and the whole face over the second half showed the bar's
     rim all at once at the end, and the person saw the border change by a step;
  4. the main words, once: the old face's rolling out, the new face's rolling in, character by character (below).
  The old face is not built again: a widget's state, its signals and its keys belong to the face that is now.

**The face is drawn at the swap's size during a run.** Its layout is its natural one (its children, its words, its
spacers: nothing wraps or reflows), then its rect along the swap's axis is set to the swap's glided rect, after its
children are placed. So its own drawing is right at every frame: its rounded ends, its border, a key's bevel, a well's
rim. The person saw "the square thing": the new face drawn at its natural size and cut by a clip the shape's width
showed a square end, or a body wider than the shape. Its input box is that rect: it is the real widget. At rest the
face has its natural rect again, the swap's.

**The words roll, character by character**, as an odometer. A swap finds each face's main words: the box with the
widest text in the face's subtree (an icon's glyph is narrower; the bar's label is the face itself, its words drawn by
`progress_fill`). It keeps them, cloned on the heap when they change, with their ink and their place, for the face it
records. During a run the old record and the new face are drawn with those words hidden, and the words are drawn by
the swap: each old character rises out of its slot and fades, the first on the left first (`SWAP_WORDS_OUT_*`); each
new character comes up from below into its slot, a little later, left to right (`SWAP_WORDS_IN_*`). They are clipped
to the line's band, so they roll under its edges rather than float. A character's place is the width of the words
before it, measured whole, so the font's kerning is kept. The old characters stay at the old words' place (moved with
the old record), the new ones at the new words' place.

The way there, each tried on the film and refused by the person:
- **A fade of the whole words**: two texts at half alpha over each other.
- **The flip of `morph_label`** (characters through random glyphs, settling left to right), then a split-flap board
  (each place flipping only in its turn): "explosive", then "buggy". Random letters read as a glitch, however few.
- **A magic move of glyphs** (the characters both texts share sliding to their new place, the others fading): glyphs
  set one by one by the sum of their own advances lost the font's kerning ("Down bading"), and the sliding ones
  crossed the fading ones. A scattered middle.
- **A roll of whole words** (the old words up and out, the new up into place): clean, but the person asked for the
  roll by character, and chose it.

The icon and the rest still cross with their faces, on their own times (`SWAP_OLD_GONE`, `SWAP_REST_FROM`).

`progress_fill` gives its box the ink its words show on average (the well's ink mixed with the green's by the share),
as it gives its background: a full bar's words are the green's ink, so the morph from them starts with the colour seen.

A face with no shape (no background, no border) has a shape of alpha 0: the morph comes from, or goes to, nothing in
the other face's colour. A custom draw that paints its own ground (`progress_fill`'s well) gives its box a background, so
that its shape is read, with `.Custom_Ground`, so that the background is not painted under its own; drawn bare, it skips
its ground (`box_bare(b)`). `progress_fill`'s shape colour is the well mixed with the fill's green by its share: the fill
is content, and a full bar whose shape was the dark well morphed into "Restart" through black (the green fading out
over a dark shape that turned green only later).

`SWAP_MS` is 600, on `Emphasized`. At 280 the person saw a change, not a morph. At 450 on `In_Out` the cubic put most
of the colour's change in some 130 ms of the middle, and the person saw a jump. At 700 on `Sine` it was smooth but "too
linear": a symmetric curve moves at the same pace into its middle as out of it, and reads as mechanical. The
emphasized curve starts at once and lands slowly: the change answers the click, and settles. The size's glide, the
shape and the alphas take the same time and curve, so the place and the shape move as one.

What is in a swap keeps its own size, never squeezed and never wrapped. It holds at the swap's start by default: a place
in a bar is read from its start, and a face centred on a growing place stood past its start, then slid toward its end as
the place grew (the first film showed "Restart" slide right). `.Center` and `.End` are there for a place centred or ended
in its line.

During a run, the contents (the old one, the new face, the morphing words) are clipped to the morphing shape along the
swap's axis, a few pixels wide of it (`SWAP_EDGE_ROOM`), and loosely across it (`SWAP_ACROSS_ROOM`). The face now fits
the shape, so the clip is for what stands past it: the morphing words of a face whose words are longer than the shape
("Restart to update to 0.42.0" coming out of the bar), the face's children at their natural places, and the old record. Not to its rect and corners: what a
face draws outside its rect (a well's lit rim and lip, a key's shadow) was cut for the whole run and came at once on
its last frame, and the person saw the bar's border go from nothing to full between two frames. The words of a face wider than the shape are revealed as the shape grows, and those of a face that
shrinks are covered as it shrinks: the shape is the container the eye sees, and words standing past it read as
overflow (the third film: "Restart to update to 0.42.0" spilled past the green shape for several frames). At the end of
the run the shape is the face's own rect, so nothing stays cut. A face with no shape (alpha 0) is clipped to its
morphing rect too.

Every part moves at once, on the shape's curve, from the first frame to the last. A first version ran them one after
the other (the old words gone by 45 %, the new ones from 30 %, the real face over the last fifth): the person saw steps,
the shape, then the words, then the face, not one change. The shape is under both texts all the time, so no frame shows
the ground through the change.

What the new face does once shown is its own: the update bar shows its share from its first frame, 0 when the download
starts. The button's green shape morphs into the bar's well, and the share's green grows in it as the program comes.

## Costs and limits

- A swap records its drawing every frame it draws, so that the old face is there whenever the face changes. A record
  is the instances of what it holds. The swap is meant for a small place (a badge, a button, a status word), not a page.
- It draws what it holds twice: once to the frame, once bare into the record. Recording and replaying the record instead
  would upload it at every frame, and a replay is redrawn at every frame by the partial redraw; drawn as boxes, an idle
  swap is compared as any box. Only a running swap replays (its old face).
- A swap inside a picture being recorded is drawn into it and keeps no record (recordings do not nest): its faces do not
  cross.
- The layout: a swap lets what it holds overflow on both axes (layout_violations never shrinks it), its least width is
  the width it shows, and its words never wrap to fit it (wrap_room: none).
- A record holds no offscreen layer (draw.Picture): a face with effects is replayed without them during its fade.
- A record made for one scale or text setting is stale at another: `replay` says `.Stale`, and the old face is then not
  drawn. The change shows the new face alone, which is what the animations off show anyway.
- The animations off: no glide, no cross. The face changes in one frame.
- The memory of a swap goes with its last build, as an animation's: its record is destroyed then.

## Refused

- **A width eased by `anim` and a stand-in while it moves.** The badge's first try: a long tail, a wordless pill, a pop.
- **Clipping the new face to the swap's rect** (the first version, with no shape that morphs). It cut the words with
  nothing to show why: an invisible edge. Clipped to the morphing shape, the cut is the shape's edge, which the eye
  follows, and it moves.
- **Words standing past the shape** (the third version). Without a clip, the new face's words spilled past the shape
  while it grew.
- **Scaling the faces to the swap's rect** (the web's view transitions scale their snapshots): words stretched sideways
  read worse than words that stand out by a few pixels while they fade.
- **The old face built again during the run.** It would need the program's code for a face it has left, and its widgets
  would answer clicks while fading.
- **Two faces cross-fading whole** (the second version). The person saw two shapes, one fading over the other, not one
  thing changing: a button's green rectangle and a bar's well were both on screen, each at half alpha. Only the content
  crosses now; the shape is one, and morphs.
- **The bar starting full** (the button's green, draining to the share). It said "done" when nothing was downloaded yet,
  then went back; held full during the cross, it still emptied right after. A bar shows its share from its first frame.
- **Symmetric curves for the run** (`Sine`, 700 ms; `In_Out` before it): "too linear". The emphasized curve answers
  at once and lands slowly.
- **The new face at its natural size, cut by the shape** (the fourth version): its end showed square, a body wider than
  the shape. The face is laid out naturally and drawn at the swap's size.
- **The face laid out at the swap's size** (its size, not its rect): its words wrapped onto two lines and its spacers
  took the room, a reflow at every frame of the run.
- **Words fading, flipping or moving glyph by glyph**: see "The words roll" above. They roll by character.
- **Pairing characters by index** (morph_text's first version, morph_label's): "Install 0.42.0" to "Downloading
  0.42.0…" flipped the version, which both say. morph_text pairs by the longest common subsequence now; above 128 runes
  either side its table costs too much for a frame, and the pairing goes back to the index.
- **A transition per widget** (a button that knows it becomes a bar). The swap knows nothing of its faces, and any place
  that changes what it shows can use it.
