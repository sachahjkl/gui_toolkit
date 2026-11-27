# The curve editor

A program's value animated over time, edited in the debug window (debug-panel.md): keys on a timeline, Bézier handles
dragged, the curve played on the program's object while it is edited, printed as Odin source to paste back. Beside it, an
easing editor for one transition from 0 to 1 (CSS's cubic-bezier), the form `ui.tween_curve` plays.

```odin
Drone :: struct {
	hover: debug.Curve,          // the height over time
	turn:  [3]debug.Curve,       // a lean and a turn, one channel per axis
	land:  ui.Cubic_Bezier,      // how it lands
	play:  debug.Playback,       // where the curves are: the program's clock
}

// each frame, a release build too
debug.playback_step(&d.play, dt, debug.curves_span(d.turn[:]))
height := debug.curve_eval(d.hover, d.play.time)
lean := debug.curves_eval(d.turn, d.play.time)

// in the panel's procedure
debug.curve("hover", &d.hover, &d.play)
debug.curves("turn", d.turn[:], &d.play)
debug.easing("land", &d.land)
```

## Decisions

### The model is the program's, the editor the surface's

`debug.Curve` is plain data the program owns: up to `CURVE_KEYS_MAX` (32) keys sorted by time, each a time, a value, an
in and an out handle, and the interpolation of the segment that leaves it. `curve_eval`, `curves_eval`, `curve_span`,
`playback_step` and the key operations (`curve_insert`, `curve_remove`, `curve_smooth`) are in `gt:debug` and compiled in
every build: a release animates its objects with them. Only the editor (`curve`, `curves`, `easing`) is empty without the
devtools, as every other call of the package.

Why `gt:debug` and not a package of its own: the curve is what the editor makes, its Print is the package's Odin text,
and one import gives both. A curve does not depend on the surface; `gt:debug` in a release costs its few procedures.

A fixed array, not a dynamic one: a key list that allocates cannot be a constant, and Print gives a literal the program
pastes as a constant (`HOVER :: debug.Curve{count = 3, keys = {0 = {...}, 1 = {...}, 2 = {...}}}`). Odin refuses an
array literal with fewer items than the array: the keys are written by index. 32 keys cover a hand-made animation;
more is a recorded one, another tool. The editor refuses a key past the limit.

Refused:

- **Handles as slopes and weights** (Unity's tangents): a weight is a third number per side that nobody reads. A handle
  is the control point itself, an offset (time, value) from its key: what the person drags is what is stored.
- **A key per vector** (one time, N values): an axis often needs a key another does not. Several channels are several
  curves (`[3]debug.Curve`), edited together by `curves`.
- **A colour or a vector kind of curve**: `curves` with the channels' names (`"rgba"`) is the same with one concept.

### Evaluation

- Before the first key, the first key's value; after the last, the last's. No key: 0. One key: its value.
- Between two keys, the left key's interpolation: `Constant` holds its value, `Linear` goes straight, `Bezier` (the zero
  value: the editor's default) follows the cubic through the out handle of the left key and the in handle of the right.
- A handle longer in time than its segment is shortened to it, its slope kept: the cubic's time then grows with its
  parameter (the control points' times within the segment, as CSS requires of x1 and x2), so a time has one value.
  Time is solved for the parameter by `ui.bezier_param` (Newton's steps, bisection when a step leaves the bracket), the
  solver of `ui.cubic_bezier_at`.
- A key is found by binary search: a call costs O(log keys) and a few multiplications. Nothing is cached: a curve
  edited live has no stale cache.

### The program's clock

`debug.Playback` (time, speed, paused, once) is the program's, and the program steps it (`playback_step`) once per
frame: the program decides what time drives what. The editor shows its time as the playhead and changes it: play and
pause, loop or once, speed, a scrub. Two curves that share a Playback play together. Without one, the editor keeps its
own, paused until the person plays it: only a playhead that plays asks for frames.

Refused: a time the editor drives behind the program's back (`debug.curve_time(&c)` read by the program): the program
would ask the surface each frame, and in a release, with no surface, the same call would mean something else.

### The editor

Its rows spend no room on nothing (debug-panel.md, "aligned without losing room"). The row over the graph and the row
under it share their columns: two glyphs, then two numbers of one width (cut from the graph's last width), then the row's
end. The first number column of each row starts on one edge, and so does the second.

- **The head**, labelled by the curve's name: play or pause, loop, the playhead's time, the speed (it takes what the
  row's end leaves: its left edge is the one of the value under it), frame all, Print. A row of its own for the time
  under a row of its own for the name was a row of nothing.
- **The graph**, as wide as the panel (a timeline needs the width): the curves over a grid, the time's ruler under it,
  the values' ruler at its left as wide as its longest number, labels in the mono face, the playhead across it. The
  channels' letters (x y z, each in its axis's colour as `drag_vector`'s marks) sit in its top right corner; a click
  shows or hides one (`curve_channel_at` for a test). A row of three letters was a row of nothing. Each letter is a
  box of its own, a check box to a screen reader, reached by Tab and toggled by Space: drawn by the graph, hit-tested
  by it, they were invisible to both.
- **The key**, with a key selected: smooth its handles, break or align them, its time and value (`drag_number`;
  several selected: a change moves them all by as much), its interpolation (a dropdown as wide as its longest word).

The easing editor is one row: its label, the square as tall as the three rows beside it (the presets and Print, then
the two handles' numbers).

In the graph:

| Act | Gesture |
|---|---|
| select | click a key; Shift or Ctrl adds it or takes it away; a box dragged from an empty place selects what it holds |
| move | drag a key: the keys selected follow; Shift keeps the main direction, Ctrl snaps to the grid |
| handle | drag a handle of a selected key: aligned, the other turns with it, unless the key's handles are broken; Alt breaks them; Shift flattens it |
| add | double click: a key at that time and value, on the channel whose curve passes nearest, its handles smooth |
| delete | Delete or Backspace |
| view | the wheel zooms about the pointer (Ctrl: time only, Shift: value only), the middle button pans, F frames all |
| time | drag in the time ruler: the playhead; Space plays or pauses |
| undo | Ctrl+Z; Ctrl+Shift+Z or Ctrl+Y redoes |

A key moved past another is sorted at once, its selection with it. Each frame of a move applies the whole delta to the
keys as they were at the press, then sorts them: no drift, and an Escape puts them back. Undo uses `gt:undo`: a step is
the curves before a gesture, an add, a delete, or a field's change (one per field and drag); fifty steps.

The view (its time and value ranges) and the selection are the surface's, by the item's path: they last while the
program runs, as a section's open state. The first view frames the curve.

Handles show on the keys selected: the curve stays readable with many keys, and a handle is grabbed on purpose.

### Drawing

The graph is one box drawn by a procedure (`ui.custom`). The curve is sampled every `CURVE_SAMPLE_PX` (2) pixels of the
graph's width: its cost is the pixels shown, whatever the keys. The keys and the handles drawn are those in the view.
The program's curves are copied into the frame's arena for the draw: a pointer of the program is not kept past its
procedure.

The grid's step is 1, 2 or 5 times a power of ten, the least that keeps the labels apart. The labels are the weak ink
moved until it reads at 4.5:1 on the graph's ground (`ui.readable`), as a dense label. The channels' colours are the
axes' hues; a selected key is the accent ringed in the text's colour.

### The easing editor

`debug.easing(label, &e)` on a `ui.Cubic_Bezier`: a square graph of the curve from (0, 0) to (1, 1) with its two
handles (x held in 0..1, y free: an overshoot is allowed), the presets of the toolkit's easings (`ui.ease_bezier`:
Linear and Emphasized exact; Out, In_Out and Sine as CSS approximates them; shown as words in the person's language,
"In out", and a tool names one either way), the four numbers, and a dot that runs along it. The dot runs while the
pointer is on the square and for one period after the curve changed, then rests at its end: a dot that ran whenever
the row showed made the window draw a frame after another. The square is no Tab stop: its four numbers are the
keyboard's way to the same handles. `ui.cubic_bezier_at(e, p)` evaluates it; `ui.tween_curve` tweens along it: a program tunes its
transition here and keeps the four numbers.

### The tools

A curve's item is of kind `curve` in `Toolkit.debugPanels`: its value is the list of its channels, each a list of keys
`{"time","value","in_handle":[t,v],"out_handle":[t,v],"interp":"bezier|linear|constant","broken"}`: Print's names
(`CURVE_KEY_FIELDS`), one set of names for the text a person pastes and the JSON a tool sends. `Toolkit.debugSet` takes
the same list (for one channel, its key list alone) and replaces the keys: a missing field is its zero, the keys are
sorted; a field of another name (a tool's typo would set nothing and say done), more than 32 keys or a number not
finite is refused, its reason named. Through `debug.set`, the text is that JSON: the devtools pass a JSON
value that is not a number, a bool, a string or a list of numbers as its JSON text. An easing is of kind `easing`: four
numbers, or a preset's name.

Refused: a method of its own (`Toolkit.debugCurve`). The paths, the List and the Apply passes are the panels'; a curve
is one more kind of value.

### Print

The head's Print writes the curves as Odin source (`debug.curve_text`) to the standard output and the clipboard: a
`debug.Curve{...}` or, for several, a `[N]debug.Curve{...}`. A key writes its time and value, then only what is not
zero. `debug.odin_text` writes a curve the same way inside a program's struct.

## Cost

- A release build: `curve`, `curves` and `easing` are empty; `curve_eval` is a binary search and a cubic.
- The window closed: nothing runs, nothing is allocated.
- The editor shown: its state is made once (its view, its selection, the curves at a gesture's start) by the surface's
  allocator; a frame copies the curves for the draw into the frame's arena. Undo allocates a step per change.
