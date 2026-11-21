# turn: angles in turns

`import turn "gt:turn"` (or the relative path of the submodule). Any target.

Every angle the toolkit takes or gives is in **turns**: a whole circle is 1, a quarter turn 0.25, half a turn 0.5. A
value read from one API goes into another as it is. The design and its reasons: `src/md/infrastructure/angles.md`.

Each procedure takes an `f32` or an `f64` and gives the same type.

## Trigonometry

| Procedure | Result |
|---|---|
| `sin(turns)`, `cos(turns)`, `tan(turns)` | the sine, cosine, tangent of the angle |
| `sincos(turns)` | the sine and the cosine together: `s, c := turn.sincos(a)` |
| `atan2(y, x)` | the angle of the point (x, y) from +x towards +y, -0.5 .. 0.5: clockwise on a screen whose y points down |
| `asin(x)`, `acos(x)` | the angle whose sine (-0.25 .. 0.25) or cosine (0 .. 0.5) is x |
| `wrap(turns)` | the same direction in [0, 1) |

A multiple of a quarter turn is exact: `sincos(0.25)` is `(1, 0)`, `cos(0.5)` is -1, `sin(1)` is 0, and
`atan2` of a point on an axis is 0, 0.25, 0.5 or -0.25. The trigonometry reduces the angle to the nearest quarter turn
first, then turns the rest's sine and cosine by that quarter with swaps and signs. A rotation by a quarter turn is
therefore an exact matrix, and a test compares it with `==`. Elsewhere the result agrees with `core:math` within 1e-6
(`f32`) and 1e-12 (`f64`).

## Conversions

Degrees and radians are for the boundaries only: a system, a file format or a person gives them, and they become turns
once, where they come in.

| Procedure | Result |
|---|---|
| `from_degrees(d)`, `to_degrees(turns)` | 360 degrees to a turn |
| `from_radians(r)`, `to_radians(turns)` | 2π radians to a turn |

```odin
// A pen's tilt from the system, in degrees: turns from here on.
info.tilt.x = turn.from_degrees(f32(pen.tiltX))
// A rotation by an eighth of a turn, clockwise on screen.
draw.push_transform(dc, draw.affine_around(draw.affine_rotate(0.125), center))
```

## The rule's test

`tests/angles` reads `src` and fails on a public declaration whose name, parameters, fields or comment speak of
radians or degrees, and on code that uses `math.PI`, `math.TAU`, `RAD_PER_DEG` or `DEG_PER_RAD`. A file that is a
boundary is listed in `tools/angles_allowed.txt` with its reason.
