type: Changed

**Middle-click autoscroll** (`ui.autoscroll_axis_speed`): the speed grows geometrically with the distance from the anchor, `V * (2^(x/D) - 1) / (2^(F/D) - 1)` (`x` past the dead zone, `D` = the new `Autoscroll_Settings.doubling`, `F` = `full_dist`, `V` = `max_speed`): it doubles every `D` px and reaches `max_speed` at `full_dist`. `exponent` (a power curve) is gone.
