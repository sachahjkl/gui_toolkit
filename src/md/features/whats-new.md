# What's new: wide and stacked

The What's new page (`prefs_page/changelog.odin`) shows a program's changelog as a timeline. It has two layouts. The
page chooses one from its own width at the last layout. Both build the same boxes in the same lazy column; only the
card's inside and the rail differ.

## Wide

A rail on the left (2 em) with a dot at each version, then the card. In the card, each kind of change is a row: its
pill in a column of 6.5 em, its bullets beside it. Outside the bullets the row costs 10.5 em of the page: the rail, the
pill column and the card's two insets (`CARD_PAD`, 1 em each).

## Stacked

No rail. Each card fills the page. Its head flows as in the wide layout (the version, the day, Latest). Each kind of
change is its pill on a line of its own, then its bullets at the card's whole inner width (`LINE_GAP` between them).
The groups are `ITEM_GAP` apart, not `LINE_GAP`: at `LINE_GAP` the first kind's pill under the head's Latest read as one
more mark of the head.

The rail goes, not only its gap. A rail thin enough to leave the bullets their room carries a dot and nothing else; the
version pill already says the order, and the newest one is lit in the accent and has Latest. A dot inline before the
version repeats the pill.

## The threshold: 34 em

The bullets need a comfortable measure: 45 to 75 characters a line is the usual range. At the UI font's average of
about 0.48 em a character, 45 characters take 22 to 24 em. The wide layout leaves the bullets the page's width less
10.5 em. Under 34 em of page (24 + 10.5, rounded down), the wide bullets get less than 24 em and wrap every few words:
the page is stacked.

At the default 15 px font: 510 px. The settings in a dialog 660 px wide leave the page about 330 px (22 em): stacked,
its bullets get 20 em instead of 11.5 em. In a dialog 1000 px wide with a 380 px sidebar the page has about 600 px
(40 em): wide.

## The switch

- The width is the page column's (`###whats_new`) at the last layout: `parent_box().size.x` inside its scope, as the
  file browser decides its preview. No card is measured; the choice costs one comparison a build.
- The choice is kept in `Changelog.stacked`. The page goes stacked under 34 em and wide again from 35 em. Without that
  gap, a page near the threshold can flip each frame: a layout of other heights can make the scroll bar appear or go,
  and the bar's room (9 px) changes the page's width.
- A column never laid out (the page's first build, or the page built again after it was left) has no width: the page
  keeps its last choice. The first build of a narrow page is wide, the next one stacked: one frame at most.

## Refused

- A width per card, measured in the build. The cards are all as wide as the page; one value decides them all.
- A layout chosen by the window's or the dialog's width. The sidebar's width is the person's own: only the page's
  share says what the bullets get.
- Squeezing the pill column. Its pill is whole ([least-width.md](least-width.md)), so the bullets pay for each em that is saved.
