# The width a content needs

`layout_least` (layout.odin) gives each box the width its content needs, from its children up: `Box.least_x`. A
parent too narrow for its children shrinks none of them under it. What is in a box never spills past its edge, a word
never breaks between its letters, and the overflow goes up to the nearest box that scrolls or lets it pass. It is CSS's
`min-width: auto` for flex items.

## The rule

- Wrapped words (`.Text_Wrap`): the widest word, held under `WRAP_LONG_WORD_EM` (8 em). A longer "word" is a path, an
  address or a name made of names: it may break, as CSS's `overflow-wrap: anywhere`.
- A box of its own size (pixels, text): what its strictness keeps of it. A label that may be cut with "…" keeps none,
  a button's words all.
- A box of boxes: in a row the sum of its children's, in a column or a `.Wrap` box the widest; its border, its bars'
  room and its gaps added.
- None of its content for a box that scrolls along X, lets its children overflow (`.Allow_Overflow_X`) or fits them to
  its width itself (`.Fits_Width`: a tool bar that folds; with its content's least, it would never be narrow enough to
  fold).
- Never under the program's own `Size.least`.

A box whose width comes from a split, never from its content, has `.Fits_Width` too. The views' frame and docks
(`views_frame`, `views_dock`) set it on their central content, their zones, their stacks and their panels' bodies: the
zones' extents and what they leave decide those widths. Without it, a tool bar or a wide row in the content pushed the
right zone out of the window (0.297.0). A program's own boxes inside them keep their least.

`shrinkable` and `wrap_room` read `least_x`. Before, they read `Size.least` alone, which a program almost never sets:
a card shrank to its share of a row, then its children overflowed it or were squeezed to nothing. A slider kept a knob
and no track. A stepper's words broke one letter per line ("Unp", "ack"). The old floor of a wrapped line, 3 em, broke
any longer word.

## Shares that wrap

In a `.Wrap` box (`ui.flow`), a child sized as a share of the width (`fill()`, `pct`) is a flex item with a basis, as
CSS's `flex: 1 1 <basis>`. Its basis is `least_x`, at least its own `Size.least`. `layout_wrap_shares` puts on a line as
many children as fit at their bases, then the shares of the line split what is left by their values. The columns of a
page stand side by side while the page holds them at their least, one under the other when it does not. The lines are
made as `layout_wrap_positions` makes them: the same widths in the same order give the same lines.

A share of the width starts at the top of its line. An item of its own size, such as a button, is centred in its line.
A column of cards lined up on the middle of its line next to a taller one read as a mistake.

## A share of words gives first

A `fill()` share asks for the whole row, then gives way when the row is too narrow. A share of boxes gave first what it
had beyond its natural width (`share_slack`); a share of words gave by its size, with every other box that may shrink.
A setting's name in `fill()` beside a segmented control that may give way: both gave in proportion, and the control
turned into a dropdown in a row that held it. A share of words now gives first what it has beyond its words, as CSS's
`flex: 1` has a basis of 0: it takes only the room that is left.

## Gaps in rows and columns

`Box.gap` was the gap of `.Wrap` boxes only. A row or a column now puts its gap along its axis between two children
that do not float, as CSS's `gap`. It is counted in the box's size, its least and the room its children share. A stack
of cards takes `gap = {0, ITEM_GAP}`, not a spacer between each two: a card adds nothing after itself (spacing.md), and
a forgotten spacer let two cards touch.

## What it does not do

- It changes no choice of the program's. A segmented control of seven words that cannot fit stays as wide as its
  words. The program chooses a list instead, from the room its row had in the last layout (the showcase's Values
  scene: `choose`).
- Heights: only the width has a least. A height follows the width's lines.

## Refused

- A least computed on demand at each shrink (`natural_width`'s way): a pass per level of the tree for each box. One
  value per box, kept by the downward pass, costs one visit.
- Letting the old shrink stand and wrapping every row: a row of a label and a field must not wrap, it must stay whole
  and make its card wider.
