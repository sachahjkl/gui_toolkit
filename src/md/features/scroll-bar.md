# The scroll bar: intent

How a program uses it is in [docs/scroll-bar.md](../../../docs/scroll-bar.md). This file keeps the reasons. The code is
`src/ui/scrollbar.odin`; a text area places its own bars (`src/ui/text_edit.odin`) and draws them with the same code.

## Purpose

A view that shows a part of a longer content has a scroll bar. It says that the view scrolls and where the view is, and
the pointer moves the view with it. Every scroll bar of the toolkit is the same bar: a scroll box (lists, menus that
scroll, the palette, a terminal's scrollback), a text area, a bar with marks.

The bar before was a thumb of a few pixels drawn over the content, a tint of the text, which could hide until the
pointer came. A reader did not see it as a control. The arrow buttons were an option, off by default.

**Which boxes have a bar: content that is read.** A list, a text, a table, a page, a log. A row of choices (tabs, a
stack's tabs, chips) is not read: it is a strip ([strip.md](strip.md)), which scrolls with arrows over its edges and
never has a bar nor a bar's room. 0.260 gave every box that scrolls a bar, rows of tabs too; that was the mistake the
strip corrects. A box that scrolls with no bar for another reason (a table's titles, which follow its rows) says
`.Scrollbar_None`, the same flag the strip sets: one mechanism.

## The standard

The form is the scroll bar of the user's desktop, ShojiWM (`shojiwm-desktop`: `crates/shell/src/ui/scroll.rs`), itself
the Windows 7 bar. Its geometry, its states and its gradients are taken as they are. Another project of the same user
took the same standard first (`kernel`: `src/md/features/scroll_bar.md`); the numbers below agree with it.

**The parts**, along the bar: an arrow button, the track, an arrow button. The thumb lies on the track. The trough is
the whole bar behind them.

| Number | Wide | Thin (default) | From the standard |
|---|---|---|---|
| Thickness of the bar, side of an arrow button | 17 px | 9 px | `THICKNESS` |
| Border of the trough, of a button, of the thumb | 1 px | 1 px | `border(1.0)` |
| Inner line of the thumb | 1 px, inside its border | 1 px | the inset shadow |
| Grip | 4 lines of 7 × 1 px, 1 px apart | 4 lines of 3 × 1 px, 1 px apart | the grip of `bar` |
| Grip shown | on a thumb of 20 px or more | the same | `length > 20.0` |
| Arrow triangle | rows of 1, 3, 5, 7 px | rows of 1, 3, 5 px | a glyph at 7 px |
| Least thumb | 8 % of the track, at least the thickness | the same | `MINIMUM_THUMB` |
| Corners | thumb 3 px, button 2 px, times the rounding | the same | `corner(3.0)`, `corner(2.0)` |
| Stops of the trough | 0, 50, 100 % | the same | `horizontal_gradient` |
| Stops of the thumb | 0, 45, 55, 100 % | the same | `horizontal_gradient` |
| Stops of a button | 0, 100 % | the same | `horizontal_gradient` |
| A held arrow button | steps at once, then after 400 ms, then each 60 ms | the same | `REPEAT_AFTER`, `REPEAT_EVERY` |

The pixels are logical: each is multiplied by the window's scale (`State.scale`: the system's scale times the zoom).
The thickness becomes the odd number of pixels nearest below the product (`2 ⌊x/2⌋ + 1`): 17 stays 17, 25.5 becomes 25.
A border, the inner line, a line of the grip, its gap and a row of a triangle are one unit, `max(1, round(scale))`. The
length of a grip line and the base of a triangle are odd too: their middle column is the bar's.

**The gradients go across the bar**: from left to right on a vertical bar, from top to bottom on a horizontal one. They
are interpolated in sRGB values, as the standard's toolkit does.

**The states.**

- Rest: the trough, the thumb with its quiet border and its dark grip, two triangles with no button under them.
- Lit, while the pointer is over the bar or a part of it is held: each arrow button has its border and its fill; the
  thumb has the accent border, the accent fill and the light grip.
- Hot, the part under the pointer: an arrow button takes the accent border and a pale accent fill, its triangle the
  bright one.
- Pressed, the part held: a deeper accent fill, for a button and for the thumb.

**The input.** A press on an arrow button moves the view by one line, then repeats while it is held and the pointer is
on it. A press on the track moves the view by one page toward the press. A press on the thumb holds it, and the thumb
follows the pointer until the button is up, also outside the bar. The wheel over the bar scrolls its view. The bar
takes no key and is not a stop of Tab: the keys of a view belong to what owns the view.

## Shown by default, hidden on request

By default a bar shows whenever its content is longer than its view, and only then. A bar must say that the view
scrolls before a person looks for it.

Hiding stays an option for a person who wants it: `scrolling.scrollbar_autohide` (`ui.set_scrollbar_autohide`), off by
default. On, a bar shows while its view moves (a glide, a drag), while the pointer is over its box, while it is held, and
for a moment after `scrollbar_reveal` (a view the keyboard moved); it fades otherwise (`Box.bar_t`, the theme's state
rate). A hidden bar is still there to take: the pointer that comes over the box shows it. A bar with marks never hides:
its marks are a map of the content. The fade is one alpha over the whole bar (`scrollbar_paint`): the hidden bar is the
same bar, and every bar of the toolkit, a text area's too, hides by the same rule.

The arrow buttons are always there: they are part of the form. `set_scrollbar_arrows` and its setting are gone.

## The bar's room

Nothing is drawn under a bar. A bar drawn over its content hid the end of every row: the words aligned at the right, a
row's buttons, a time ("Esc close", "Open"), and each program left room by hand (`scrollbar_gutter()` spacers in the
palette, the menus, the tables), or forgot to.

**One mechanism, in the layout.** A scroll box's content area is its box less its border and less the room of its bars
(`Box.bar_room`: along X a vertical bar's, along Y a horizontal bar's). Every pass that reads a content area reads it
(`content_pad`): a share (`fill()`, `pct`), what overflows, where children go (a vertical bar on the left, with
`.Scrollbar_Left`, keeps its room at the start). The content's bounds count the room at the end, so the content's end
scrolls clear of the bar across it. A box sized by its children (a menu's panel) grows by the room. Every scroll box is
thus served: lists, virtual lists, tables, markdown views, the settings page, menus that scroll, the palette. No widget
leaves room for a bar any more. A table's titles, outside the rows' list, leave the room that list keeps
(`Table_Layout.bar_room`, `ui.scrollbar_room`), so the columns line up. A text area is not a layout box: it keeps the same
room by the same rule (`Text_Edit.bar_room`, `edit_bar_room`), its text clipped short of it.

**When.** Whenever the bar shows: the content is longer than the view. Then the content is narrower, which can only make
it longer: it still overflows. A layout ends with the decision (`scrollbar_rooms_update`), and when a room changed the
layout runs again in the same build: the frame that first shows the bar has the content beside it.

**No oscillation.** A content measured without the bar that fits does not take the room, even when it would overflow beside
the bar: it was measured without it first. A content that has the room gives it back when it fits beside the bar; wider,
it fits still. A content that fits only without the bar and overflows beside it keeps the room it has: that band is the
hysteresis, and the room never goes and comes from one build to the next. Each change of a layout's rooms follows the
content; at most three layouts in a build (a vertical bar's room can make a horizontal bar come).

**Room only while it overflows, by default; reserved on request.** By default (no flag) a box keeps no room while its
content fits: a list of three rows uses the whole width. `.Scrollbar_Reserve` on a scroll box (`ui.next({flags =
{.Scrollbar_Reserve}})` before the widget that builds it, a text area's box too) keeps the room of each bar it can show
even while the content fits: a list that grows past its view (rows that load, a log that runs) does not narrow under
the reader at that moment. The default is the content's whole width because most boxes never overflow or overflow
from their first frame; the jump is a cost only for a content that grows while a person reads it, and that box's
program knows it. Refused: reserving by default (every short list, every menu that fits, lost a column for a bar it
never shows); a setting of the person's (it is the content's nature, not a taste). With the overlay option no room is
kept, reserved or not. A box with `.Scrollbar_None` keeps none.

**With auto-hide, the room stays.** The bar fades in its own room. A bar that took room only while it showed would move
the content each time the pointer came near: what a person reads would reflow under the pointer.

**Overlay is a person's option**, off by default: `scrolling.scrollbar_overlay` (`ui.set_scrollbar_overlay`). On, no
room is kept and the bar is drawn over the edge of the content, as macOS draws it: for a person who wants every pixel for
the content and accepts that the bar hides the ends of rows. It is one condition in the decision of the room, so it costs
nothing else.

**A bar in its room takes no press beside it.** A bar over the content took a press a few pixels toward it
(`scrollbar_grab`), to make a thin bar easy to catch. In its own room that margin would take the last pixels of a row's
button; it stays for an overlaid bar only.

**A bar with marks keeps its width at rest.** Its widening under the pointer is over the content: a room that grew with it
would reflow the content at each pass of the pointer.

## Two sizes

`scrolling.scrollbar_size` (`ui.set_scrollbar_size`): `thin`, the default, or `wide`. Wide is the standard's 17 px.
The standard's bar is very visible; a bar of 17 px beside every list of a dense program takes much room. Thin keeps
every part and every state, half as wide.

**Thin is 9 px.** Half of 17 is 8.5. An even thickness has no middle column: the point of a triangle and the grip
cannot be on the bar's middle line, and they are a pixel off one side. 9 is odd. Inside its border there are 7 px, and
inside the thumb's inner line 5 px: a grip of 3 px leaves one pixel of the thumb's face at each side, as the grip of
7 px leaves its room in the 13 px of the wide thumb. A triangle of rows 1, 3, 5 is 5 px wide and 3 rows tall, two
pixels clear of each side of its button: the smallest triangle that still reads as an arrow. A bar of 7 px leaves a
grip of 1 px and a triangle of 3: a dot and a smear.

## The colours come from the theme

The standard has two fixed tables, dark and light, in its own blue-grey. The toolkit has themes, each with its accent
(an amber theme, a green one). A blue bar in an amber window is not part of the window. So each colour of the bar is a
mix of the theme's colours, with fractions chosen so that the toolkit's default themes give the standard's bars:
Midnight and Graphite give the dark table, a light theme (Midnight Light, Silver Light) the light one.

The inputs, under the tags of the scrolled box:

- `P`: the opaque surface under the box (`box_under`).
- `T`: `track`, the theme's raised step. `L`: `border`, its line.
- `W`: `weak text`. `X`: `text`. `A`: `accent`. White.

`m(a, b, t)` mixes `a` toward `b` by `t`, in sRGB values (`srgb_mix`), opaque.

| Colour | Dark theme | Light theme | Standard dark | Standard light |
|---|---|---|---|---|
| Trough, its edges | `m(T, L, .5)` | `m(T, L, .5)` | `#26303a` | `#e3e3e3` |
| Trough, its middle | `L` | `m(P, white, .3)` | `#2c3743` | `#f1f1f1` |
| Trough border | `m(P, T, .5)` | `L` | `#1b232b` | `#d7d7d7` |
| Thumb border at rest, button border when lit | `m(L, W, .4)` | `m(L, W, .5)` | `#56687a` | `#9b9b9b`, `#9da8b2` |
| Border of what is hot, thumb border when lit | `A` | `A` | `#4b8fd0` | `#3c7fb1` |
| Button lit (2 stops) | `m(L, W, .2)`, `m(L, W, .1)` | `m(P, white, .5)`, `m(T, L, .6)` | `#3a4855`, `#313e4a` | `#f3f3f3`, `#dcdcdc` |
| Button hot | `m(T, A, .28)`, `m(T, A, .2)` | `m(white, A, .1)`, `m(white, A, .2)` | `#2a4660`, `#223c53` | `#e3f4fc`, `#c6e8fa` |
| Button pressed | `m(T, A, .4)`, `m(T, A, .32)` | `m(white, A, .22)`, `m(white, A, .3)` | `#2d5578`, `#244a6b` | `#c2e4f6`, `#a9d9f2` |
| Triangle | `m(W, X, .3)` | `W` | `#a7b4c0` | `#606060` |
| Triangle hot | `m(X, A, .2)` | `m(A, X, .4)` | `#cfe6fa` | `#1c5180` |
| Thumb at rest (4 stops) | `m(L, W, .3 .24 .18 .12)` | `m(white, D, .2 .45 .7 1)`, `D = m(L, W, .25)` | `#4a5967` … `#36424d` | `#f3f3f3` … `#cdcdcd` |
| Thumb lit | `m(T, A, .45 .38 .31 .24)` | `m(white, A, .12 .2 .28 .36)` | `#365b7d` … `#25415d` | `#e3f4fc` … `#a9dcf6` |
| Thumb held | `m(T, A, .58 .5 .42 .34)` | `m(white, A, .22 .3 .38 .46)` | `#3c6890` … `#284d6f` | `#cde9f8` … `#8ccaec` |
| Inner line of the thumb | white at 12 % | white at 40 % | the same | the same |
| Grip | `m(P, T, .5)` | `m(W, L, .3)` | `#22303c` | `#8e8e8e` |
| Grip lit | `m(X, A, .45)` | `m(A, X, .25)` | `#9cc8ee` | `#3c7fb1` |

Which column applies is the theme's own word (`Theme.dark`). The neutrals come from the theme's surfaces, so Graphite
gives a grey bar and Midnight a blue-grey one, as close to the standard as their greys allow. The blues are the accent:
Midnight's indigo, Graphite's sky blue, Amber's amber.

## Where the toolkit leaves the standard, and why

- **An arrow button moves the view by one line** (the line height of the box's font; a text area's own line), not by a
  tenth of the content. A tenth of a long log is pages; a line is what a reader follows.
- **The thumb is at least as long as the bar is thick**, besides the standard's 8 %. On a short track 8 % is less than
  the thumb's borders and its line, and less than a place for the pointer.
- **A bar shorter than three thicknesses has no arrow button**: two buttons and a least thumb. The track takes the bar.
- **The triangle is rows of pixels**, not a character of a font: its point is on a pixel, at any scale.
- **The corners follow the rounding setting** (`set_rounding`): the standard's 3 and 2 px, times the rounding; square
  in the edged finish. A corner under 3 px is square, as every corner of the toolkit (`ROUND_LEAST_PX`): at scale 1 a
  button's corner is square.
- **The bar is in its box**, not a box beside it as in the standard: the scroll box's layout keeps its room (below,
  "The bar's room"). It lies inside the box's border, and a rounded box keeps its corners: the bar starts and ends the
  box's drawn radius away from them.
- **A bar with marks is wider** (`scroll_marks`): its marks need a lane. It keeps every part of the bar; its thumb has
  no grip, which would cross the marks drawn over it.
- **Every finish draws the same bar.** The flat finish drew a tint of the text before. A scroll bar is a control, and
  the standard's form is the toolkit's form of it. A theme can give another form of the same parts
  (`Theme_Scroll_Bar.form = .Keys`, Old Head's: [theme-design.md](theme-design.md), layer 8); a finish cannot.

## Refused forms

- **A bar that hides by default.** A person who does not know that a view scrolls does not find a hidden bar. Hiding is
  a person's choice (`scrolling.scrollbar_autohide`), never the toolkit's default nor a program's.
- **A second look for a hidden bar** (a thin overlay line). The bar that comes back under the pointer is the same bar.
- **A bar over its content by default.** It hides the ends of rows; a person who wants it chooses
  `scrolling.scrollbar_overlay`.
- **A bar on a row of choices** (0.260's tabs): a strip has arrows instead ([strip.md](strip.md)).
- **Room left by each widget** (a gutter spacer at the end of a row): a widget that forgets it puts its words under the
  bar, and a widget that has it doubles the room when the layout keeps one.
- **The room decided before the layout** (from the content's height of the last frame only): the first frame of a bar
  drew the content under it. And measuring the content twice in each layout, with and without the bar: twice the cost in
  every frame for the frames where the decision changes.
- **Fixed colour tables.** The standard's own blues in every theme: a bar foreign to the window it is in.
- **A width in em**, as before (half an em). The standard's bar is pixels times the scale; a bar must not grow because a
  list's text is larger.
- **An even width** (8, 16 px): the grip and the point of a triangle then have no middle column.
- **A thin bar of 7 px**: its grip is a dot, its triangle three pixels.
- **A press on the track that jumps there.** The thumb went under the pointer. The standard pages: a press on the track
  of a long content does not lose the place.
- **The thumb that follows a press with no move.** The thumb's place is rounded to pixels, coarser than the offsets of
  a long content: a press on the thumb with no move would shift the view. The view follows the thumb only once the
  pointer moved since the press.

## Subtle points

- **One held part.** One button is down at a time: `State.sb_held` holds the part of the bar held (an arrow, the track,
  the thumb, a mark), beside `active_key`, which says which bar. A text area keeps its own (`Text_Edit.sb_part`): it
  hears its pointer in its build.
- **The repeat reads the frame's clock.** A held arrow is a timer of the State (`repeat_fires_every`, the rule of
  `repeat_pressed` with the standard's times): it steps when the build's time passes its next step and asks for a wake
  at that time. Off the arrow it waits; back on it, it goes on. A test moves the clock (`session.advance`) and waits for
  nothing.
- **The press is where the button went down.** The part pressed is found against the layout under the press, before
  the build moves anything.
- **Lit covers the drag.** While the thumb is held the pointer can leave the bar; the bar stays lit, the thumb pressed.
- **The colours are made at each draw of a bar**: a few mixes, the same count for any content.
