# The strip: intent

How a program uses it is in [docs/strip.md](../../../docs/strip.md). This file keeps the reasons. The code is
`src/ui/strip.odin`.

## Purpose

A row of items that a person picks from (tabs, a stack's tabs, a program's server tabs, chips) is not a document. When
it is wider than its room, it must still give every item. Since 0.260 every box that scrolls drew the standard scroll
bar in a room of its own (scroll-bar.md): a row of tabs gained a bar under it, as tall as a third of a tab, for a row
that holds three words. The user called it inappropriate, and asked for left and right buttons, one design for the
whole toolkit.

A strip is that design: `if ui.strip("###id") { items }`. Its items are the boxes built directly in it, in one line.
When they fit, a strip is a plain row. When they do not, it scrolls sideways, the edge that hides items fades, and an
arrow button stands on that edge.

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

## Decisions

- **No scroll bar, ever.** A bar is the sign of content that is read: its thumb says how much is left of a long text.
  A strip has a few items; its arrows say the same and are a larger target. The strip sets `.Scrollbar_None` on its
  view: the one mechanism every scroll box has to show no bar. No room is kept for a bar either.
- **The arrows lie over the faded edge.** They do not take room from the items. An arrow that took room when it came
  would shift every item by its width each time the view left the start or reached the end, under the pointer that
  was about to click. An arrow room kept at both ends at all times would cost two buttons in every strip that fits.
  Over the fade, the arrow covers only what the fade already hides, and the layout never changes with the scroll.
- **An arrow shows on a side only when that side hides items.** At the start, only the right arrow; at the end, only
  the left one. A strip that fits has none. This is decided by the last layout (as the fades are) and checked again
  after the layout of the build (`strips_settle`): when the decision changed, another build comes at once, so a strip
  never stays with an arrow that has nothing to show.
- **A click brings the next hidden item fully in view.** A fixed step in pixels left an item cut at the edge, under
  the arrow. The step is the next item past the clear part of the view, the part outside the fades: the item lands
  just inside it. `Strip_Step.Page` moves by the clear part instead, for a long strip of small items (chips).
- **Held, an arrow repeats**, by the rule of every held button (`repeat_pressed`, the Feel's times). Each repeat
  brings one more item.
- **The wheel works over a strip.** A sideways wheel (a touchpad) and Shift+wheel scroll it, as any box that scrolls
  sideways. An up-and-down wheel scrolls it sideways too (`.Wheel_Sideways`): over a row of tabs there is nothing to
  scroll up and down. A strip that fits lets the wheel through to the page around it.
- **The keyboard reveals.** The items are the Tab stops; the arrows are not (a person with a keyboard moves through the
  items). The focus that lands on an item off view scrolls the strip to it, clear of the fade
  (`scroll_focus_into_view`, on both axes now). The arrows have a name for a screen reader ("Scroll left", "Scroll
  right") and no tooltip: the chevron says what it does.
- **The fades stay.** The edge that hides items fades over `Strip_Options.fade`, at least the arrow's width: the arrow
  stands on the faded part, and an item brought in view stops at the fade's inner end.
- **The strip hugs its items unless told otherwise.** With no width given, a strip is as wide as its items and gives
  way first in a row that is short (`children_sum(0)`): a "+" built after it stays right after the last tab while
  they fit, and at the strip's end when they do not. A width given (`fill()`, `px`) is kept.

## One look for every row of tabs

`ui.tabs`, a dock's stack and a stack of views are three rows of tabs; they have one look, `tab_box`
(`src/ui/widgets_ext.odin`): the chosen tab in the text's colour over the accent underline, which grows when it is
chosen; the others weak, lit by the theme's "tab" hover; each a Tab stop. The stack of views drew its own before: the
shown tab a block tinted with the accent ("selected"), the others ghost buttons. The user called it "ugly and flat": a
tinted block reads as a selected row of a list, not as the page in front, and it was a look no other row of tabs had.
Refused: a raised plate for the chosen tab (the segmented control's key). A segmented control is a few equal choices
in a well; a row of tabs is open pages in a bar, often many, of unequal widths, and a plate under each chosen tab of
every stack would be the heaviest thing on the screen.

## Refused

- **A scroll bar under a strip** (0.260): see the purpose. Thin or wide, it is a document's control.
- **Wrapping tabs on more lines**: the content under the strip moves down each time a tab opens, and the order of the
  tabs breaks across lines.
- **A "more" menu for a strip**: it hides the order and the places. The path bar keeps its "…" (its hidden part is the
  ancestors of a folder, read from the top) and the toolbar its fold (its rare tools).
- **Arrows that take room when they show**: the items move under the pointer (see the decisions).
- **A step of a fixed number of pixels**: an item cut under the arrow.

## Subtle points

- **The arrows float in the strip's box, not in its view**: the view scrolls, the arrows stay at the edges. The right
  arrow's place is the strip's width, known after the layout: `strips_settle` puts it at the right edge of the layout
  of this build, so a strip that changes width (a window that is resized) has its arrow at its edge in that frame.
- **The height is the row's.** A strip is `pct(1)` tall by default and its items `pct(1)` of it: give the row a height
  of its own (`px`), never `children_sum`.
- **Items are the direct children of the view.** The arrow's step reads their rects; an item wrapped in a box of its
  own counts as that box.
