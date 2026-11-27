# The strip: intent

How a program uses it is in [docs/strip.md](../../../docs/strip.md). This file keeps the reasons. The code is
`src/ui/strip.odin`.

## Purpose

A set of choices that a person picks from (tabs, a stack's tabs, a program's server tabs, chips, a sidebar's buttons)
is not a document. When it does not fit its room, it must still give every choice. Since 0.260 every box that scrolls
drew the standard scroll bar in a room of its own (scroll-bar.md): a row of tabs gained a bar under it, as tall as a
third of a tab, for a row that holds three words. The user called it inappropriate, and asked for arrow buttons, one
design for the whole toolkit.

A strip is that design: `if ui.strip("###id", {axes = ...}) { choices }`. When its choices fit, it is a plain row (a
plain column, a plain block). When they do not, it scrolls; on each side that hides choices an arrow button lies over
the edge, and the content fades out beyond it.

## Which answer for which row

The toolkit has three answers for a row that is too narrow. Each is right in its place.

- **Wrap** (`toolbar` `.Wrap`, `ui.flow`): every item stays in view, the row grows by a line. Right where height is
  cheap and every item is a tool used often: cliche's bars around a picture.
- **Fold into a menu** (`toolbar` `.Fold`, the path bar's "…"): the row keeps one line, the rare items go to a menu,
  in an order of their own (priority, the ancestors of a folder). Right when what folds is less used than what stays,
  and a menu row says more than the item (a tool's name, its key).
- **Scroll with arrows** (the strip): the row keeps one line and its order. Right when every item is the same kind of
  choice and the place of each matters (the tabs a person opened, in the order opened). A menu would break the
  order, a wrap would push the content down each time a tab opens.

## Axes

`Strip_Options.axes` is a set: `{.X}` (the default, also `{}`), `{.Y}` (a sidebar's column of choices), or `{.X, .Y}`
(a block of choices that overflows both ways). One code path serves all three: every value along an axis is indexed by
the axis, a side is an axis and an end. Refused: a vertical strip as a second widget, a copy that would drift.

- On one axis the choices are laid out along it; on both, in a column (its rows one under the other), unless `next`
  says another axis.
- With both axes, up to four arrows. Each spans its side short of the other axis's arrows' thickness at both ends: the
  corners stay clear, and an arrow never covers another.

## Decisions

- **No scroll bar, ever.** A bar is the sign of content that is read: its thumb says how much is left of a long text.
  A strip has a few choices; its arrows say the same and are a larger target. The strip sets `.Scrollbar_None` on its
  view: the one mechanism every scroll box has to show no bar. No room is kept for a bar either.
- **An arrow is a real small button over the edge.** An opaque plate of the strip's own surface, as thick as 1.6 em
  along its axis and as long as the side, its chevron in the middle, a hover plate. Under it nothing of the content
  shows (`Box.edge_hold`: the mask holds that band clear), and the content fades out beyond it (`edge_fade`, 1 em by
  default). Before, the arrow stood on the fade itself: the fade starts half-seen at the edge, and the words under the
  arrow showed glued to its chevron ("log>"). It takes no room from the layout: an arrow that took room when it came
  would shift every choice by its width each time the view left the start, under the pointer about to click.
  `Strip_Options.edge` keeps it off a line along the strip's bottom (a Folder's, `tab_panel`'s frame): as tall as the
  strip, the opaque plate cut that line where the tabs overflowed.
- **A clear gap beyond the arrow** (`STRIP_GAP_EM`, 0.3 em): the band held clear is the arrow and that gap, and the fade
  begins past it. A choice cut at the arrow showed, glued to it, the first pixels of its own drawing (in opencode
  native, the tail of a raised tab and its "⌄"), faint but seen at the start of the fade. Everything the view's content
  draws, a custom draw (a bevel, a glow, a lamp's halo) as well as text, is under the strip's mask (`draw_box` pushes it
  before the content's draws); the gap is what keeps a cut choice from touching the arrow. The step and the reveal keep
  a choice clear of the arrow, the gap and the fade.
- **One ink for both arrows**, at rest and under the pointer: the text's of where the strip is, read before the arrow's
  own tags. The weak ink, lit as "hot text" under the pointer, made the arrow at rest look faint beside the one just
  clicked. The hover shows by the plate.
- **An arrow shows on a side only when that side hides choices.** At the start, only the end arrow; at the end, only
  the start one. A strip that fits has none. Every arrow is built at every build; right after the layout, by the layout
  that is drawn, each is put on its edge or hidden (`strips_place`: no place, no press, nothing drawn, nothing read
  aloud), with the band and the fade of its side. So the first frame a strip is in has its arrows. Decided at the build
  from the last layout, as first written, the first frame had none: there is no last layout then. After the scroll step,
  an offset that makes an arrow come or go asks for one more build (`strips_settle`).
- **A click brings the next hidden choice fully in view.** The step is the nearest choice that the arrow covers or that
  lies past it; it lands wholly in the clear part of the view (the view less the arrow and the fade at each side), at
  its far end. A choice only in the fade counts as shown: taking it moved the view by a few pixels, and the click did
  not show what the arrow hid. A fixed step in pixels left a choice cut under the arrow. `Strip_Step.Page` moves by the
  clear part instead, for a long strip of small choices.
- **Held, an arrow repeats**, by the rule of every held button (`repeat_pressed`, the Feel's times).
- **The wheel over a strip.** It scrolls while the pointer is over it, the way the strip goes, as smoothly as a scroll
  area (the wheel's own step, a touchpad's fractions, the glide).
  - On one axis every wheel scrolls along it: the up-and-down wheel, Shift+wheel, a sideways delta. Over a row of tabs
    there is nothing to scroll up and down, and nobody should need Shift. The step is that of the wheel that moved (the
    vertical wheel's lines for an up-and-down turn): the sideways wheel's setting, often absent, made a page a notch.
  - On both axes the wheel is the page's: the plain wheel scrolls Y, Shift+wheel X, a touchpad's 2D delta both at once.
  - A strip takes the wheel only while it overflows the way the wheel would scroll it: one that fits lets the wheel
    through to the page around it. It never takes Ctrl+wheel, the zoom's (`.Strip_Wheel`, read by the wheel's hit test).
- **The keyboard reveals.** The choices are the Tab stops; the arrows are not. The focus that lands on a choice off view
  scrolls the strip to it, clear of the arrow and the fade (`scroll_focus_into_view`, on both axes).
- **The chosen choice is brought into view when it changes** (`strip_reveal`): a tab its "+" opened at the end, or one
  a command showed, is not left hidden behind the arrow. Only when it changes: the person scrolls away freely. The shot
  of the six terminals showed the content of the sixth while its tab was out of view.
  The move happens in the layout that first shows it (`strips_place`, after the layout, before the draw: the view
  jumps there and the boxes in it move by as much). Done at the build, it read the last layout's rects, none at a
  first build: a row of tabs whose chosen tab is not the first showed its start for a frame, then jumped, and a click
  in that frame landed on another tab. A jump, not a glide: what is shown first, or chosen elsewhere, is where it is.
- **A strip hugs its choices unless told otherwise.** With no size given along an axis it scrolls, a strip is as long
  as its choices and gives way first (`children_sum(0)`): a "+" built after it stays right after the last tab while
  they fit, and at the strip's end when they do not. A size given (`fill()`, `px`) is kept.
- **Its choices give way before it scrolls** (`strip_give`, in the layout's violations of the view). A row of tabs too
  long for its stack showed some tabs whole and the rest behind an arrow, while every tab cut a little would all have
  shown (galerie's panels; Chrome and the systems' tab bars shrink their tabs first). Each choice gives what its
  strictness lets it, never under the width its content keeps (`least_x`); a tab's words keep `TAB_TITLE_LEAST_EM`
  (`tab_title_width`: a short title keeps all of it, `Size.least` would grow it). A chip or a button of a fixed size
  gives nothing: those strips scroll as before. The strip's own least counts each choice at what it keeps.
- **A sliver is held whole** (`STRIP_SLIVER_EM`). A choice cut by an arrow's band that showed under 1.5 em before it
  showed its rim in the fade and none of its words: an empty outline beside the arrow. The band then reaches over that
  choice, with no fade (a fade there would dim the whole choice before it).
- **A change of room shows the chosen choice again.** A window narrowed left the chosen tab behind the arrow (it had
  been brought into view at a wider size). The reveal keeps the room it was made in (`Box.strip_room`) and is made
  again when it changes.
- **It gives way, but not to nothing.** Along each axis it scrolls, a strip is never shorter than its largest choice
  and one arrow (by the last layout), nor longer than its choices: a stack of views in a side zone of 180 px gave its
  tabs 21 px to its strict buttons, and the press meant for a tab landed beside it. A size in pixels is the caller's.
  The layout computes that least itself, from the choices' sizes of the same layout (`strip_least`, called by
  `layout_downward` on a box with `Box.strip_arrow`), for the strip's view and the strip: taken from the last layout, it
  was none at a strip's first build, and the strip gave way to nearly nothing for one frame, a flash at every first show.
  Refused: an unseen first frame (a dialog's way): the strip would come one frame after the rest of its row.
- **The choices are the clickable boxes in it**, at any depth, not those inside a choice (a tab's close button is the
  tab's). A block's rows are not choices; their buttons are. With none clickable, the boxes built directly in it.

## One look for every row of tabs

`ui.tabs`, a dock's stack and a stack of views are three rows of tabs, each on a strip (a dock's stack: its tabs on a
strip, its fold and menu buttons after it, always in view); they have one look, `tab_box` (`src/ui/widgets_ext.odin`),
whose rule and history are in [tabs.md](tabs.md): the chosen tab rising out of the strip's line as one shape with its
panel, the others a faint outline in the weak ink; each a Tab stop.

## Refused

- **A scroll bar on a strip** (0.260): see the purpose. Thin or wide, it is a document's control.
- **Wrapping tabs on more lines**: the content under the strip moves down each time a tab opens, and the order of the
  tabs breaks across lines.
- **A "more" menu for a strip**: it hides the order and the places. The path bar keeps its "…" (its hidden part is the
  ancestors of a folder, read from the top) and the toolbar its fold (its rare tools).
- **Arrows that take room when they show**: the choices move under the pointer.
- **An arrow over the faded content**: the words under it showed beside its chevron.
- **A step of a fixed number of pixels**: a choice cut under the arrow.

## Subtle points

- **The arrows float in the strip's box, not in its view**: the view scrolls, the arrows stay at the edges. Their places
  depend on the strip's size, known after the layout: `strips_place` puts each on its side of this build's layout, so a
  strip that changes size (a window that is resized) has its arrows on its edges in that frame.
- **Across, the size is the parent's.** A strip is `pct(1)` across by default and its choices often `pct(1)` of it:
  give the row (the column) a size of its own, never `children_sum`.
- **The arrow's band and the fade are on the view (`edge_hold`, `edge_fade`), set after each layout by the same
  decision as the arrows**: the reveal of the keyboard and of `strip_reveal` keeps a choice clear of both.
