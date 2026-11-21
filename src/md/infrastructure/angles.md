# Angles: turns

Every angle the toolkit takes or gives is in **turns**: a whole circle is 1, a quarter turn 0.25, half a turn 0.5.
Not degrees, not radians. One unit for every package, so a value read from one API goes into another as it is.

## Why turns

- **No conversion on the way.** A caller that holds a share of a circle (a hue, a progress, a dial) multiplies it by 2π to
  call `sin`, and the trigonometry divides by π at once to reduce its argument. In turns both go: the share is the angle.
- **Exact common angles.** 0.25, 0.5 and 0.75 are exact in floating point; π/2 is not, and `cos(π/2)` gives
  `-4.37e-08` where a matrix wants 0. Rotations by quarter turns stay exact, and tests compare them with `==`.
- **Free wrap-around.** An angle past a turn is its fractional part; no 2π constant to subtract.
- **CSS already has it**: `rotate(0.25turn)`, `hsl(0.5turn …)`. `draw.hsv` already takes its hue in turns.

Sources: Casey Muratori, "Turns are Better than Radians" (computerenhance.com, 2022), and the discussions it raised;
the CSS Values `turn` unit.

## The rule

1. **A public procedure's parameter, a public field, a return value that is an angle is in turns**, an `f32` (or `f64`)
   named `turns`, or named for what it is (`hue`, `tilt`, `twist`, `nib`, `sweep`) with "(turns)" in its comment. Its
   direction and its zero are said beside it, as before (clockwise on screen with y down, from +x, unless a format the
   API mirrors says otherwise: a CSS gradient's 0 is up). A count of quarter turns (an integer) is named `quarters`; an
   angle is named `turns`.
2. **Trigonometry takes turns**: `gt:turn`'s `sin`, `cos`, `sincos`, `atan2` (which gives turns). They reduce the
   argument to the nearest quarter turn first, so a multiple of a quarter gives 0, 1 or -1 exactly; radians exist only
   inside them, at the call to `core:math`.
3. **Degrees and radians live only at the boundaries**, converted once on the way in or out, with
   `turn.from_degrees`, `turn.to_degrees`, `turn.from_radians`, `turn.to_radians`:
   - what a system gives: a pen's tilt and twist (Windows' pointer API, Wayland's tablet protocol, X11 XInput), a
     display's or a video's rotation (DXGI, container metadata);
   - what a file format writes: SVG's `rotate()` and arc flags, CSS text (`hsl(…deg)`, `rotate(…deg)`), a COLR font's
     sweep, a PDF's rotation;
   - what a person reads or types: a settings field or a status line may show degrees; the value behind it is turns.
4. **A test holds the rule** (`tests/angles`, as `tests/globals` holds the globals): no public procedure or field of
   `src/` speaks of radians or degrees (in its name, its parameters' names or its comment) outside the files that are
   boundaries, listed with their reason in `tools/angles_allowed.txt`.

## Refused

- **Radians in the toolkit, degrees at its edge** (most game engines): two units in one code base, the same `f32` for
  both, and a conversion at every call that crosses the edge. Godot's mixed API is the example people cite.
- **Half turns** (CUDA's `sincospi`): one constant less in the library, a circle that is 2 for every reader.
- **A distinct type** (`Turns :: distinct f32`): Odin would refuse a plain number where a turn is asked, so every
  literal angle (`0.25`) would need a cast at every call. The name and the comment say the unit; the test holds it.
- **Vectors instead of angles** (a rotation as cos and sin kept together): right inside geometry, and the toolkit does
  it there (an affine matrix holds no angle). But a person, a theme or a file gives an angle, and that angle is turns.

## Breaking

Before 1.0 nothing is kept for compatibility. The procedures and fields that took radians or degrees take turns, under
their new parameter names, and the programs change their calls. The changelog fragment lists each one.
