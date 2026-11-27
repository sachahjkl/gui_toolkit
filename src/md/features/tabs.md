# The look of a tab: intent

The code is `src/ui/tab_face.odin` (`tab_box`, `tab_body`, `tab_draw`, `tab_line_draw`). Every row of tabs of the
toolkit is built with it: `ui.tabs`, a dock's stack (`docking.odin`), a stack of views (`views_panels.odin`), a dense
view's header (the debug window). How a row of tabs scrolls is the strip's ([strip.md](strip.md)). How a program uses
them is in [docs/strip.md](../../../docs/strip.md) and [docs/docking.md](../../../docs/docking.md).

## The fault

Up to 0.363 the chosen tab was a raised plate: the face of a button (a bevel when machined, a sheen), rounded, 80 % of
the strip's height, with a gap of the strip's colour all round it. With the close button inside it, a stack of tabs read
as a row of buttons. The owner, on plume's editor: "not good, a toolkit problem, fix the tabs' look". A flat look (the
page's colour, an accent line at the top, dividers) was tried next and judged "meh": it read as nothing. A strip also lost
room before its first tab ("and the void? wtf").

## The rule

A tab is the label of the panel under it, and one shape with it.

- **One line.** The strip's bottom edge is a line in the border's colour, from edge to edge: the top border of the
  container under it. The box the tabs stand in draws it as its custom draw (`tab_line_draw`), before its children: a
  box's sides (`.Draw_Side_Bottom`) are drawn after its children, and the chosen tab could not cover it.
- **The chosen tab rises out of the line.** Its outline leaves the line through a concave fillet, climbs, rounds over its
  top and comes down through the other fillet into the line again (the Chrome tab's silhouette). Inside it is the page's
  colour (`tab_on background`: a panel's content is drawn on the page) down past the line, so the tab and its panel are
  one shape with no line between them.
- **In the theme's finish.** With a finish that has a sheen, its face is a step lighter at its top; machined and edged,
  a lit rim runs under its top edge. Flat: the colour alone. Its top corners take the theme's control radius
  (`shape_of(.Control)`): a dense scope's smaller em gives a tighter one, a square theme square tabs and no fillet.
- **The other tabs have no face.** A faint rounded-top outline sits on the line (the border at 45 %, a little lower than
  the chosen tab), inside the room the chosen tab's feet take. Under the pointer the same shape fills with the theme's
  hover step (`tab hover_fill`), pressed its press step. No dividers: each tab's outline already separates it.
- **A tab at an end of its strip has a straight side there.** No fillet: its side goes straight down the strip's end, in
  line with its panel's edge. The first tab stands at the strip's left edge: no room is lost before it.
- **The words sit in the middle of the shape.** `tab_body` is a row as tall as the visible part of the shape (the
  strip's ground shows above it), the tab's content centred across it, not across the strip.
- **A panel's content aligns with its tab's words.** A dock tab's words start `DOCK_TAB_PAD_EM` from its edge;
  `dock_content_inset()` gives that distance to a panel. A pane adds no inset of its own: only the splitter separates two.
- **The close button (a dock's ×) shows on the chosen tab and under the pointer only.** Its room is kept on every tab,
  so no tab moves when the pointer goes over it. The keyboard and a screen reader still close a tab: the button stays in
  the accessibility tree, the stack's menu has Close, a middle click closes.

## Subtle points

- The chosen tab's feet reach beyond its box, over its neighbours' padding: an unchosen tab's outline keeps clear of
  them (the foot and a pixel), so the shapes never touch.
- "An end of its strip" is the end of the outermost box on the tab's baseline that draws the line, not of the strip's
  view: the view is as wide as the tabs, and its last tab would always count as the last. `ui.tabs` draws a line under
  its own strip; a program's row around it (fidget, the debug window) draws the whole one, and decides.
- The strip's view clips, and as wide as its tabs it cut the chosen last tab's right foot. A chosen tab gives the view a
  clip overhang of its foot (`Box.clip_overhang`), used only while all the tabs show: scrolled, what lies past an end is
  hidden and must not show beside it, and an arrow covers that end anyway.
- The keyboard's focus ring goes round the visible shape (`Box.ring_at`: from the shape's top, its top corners
  rounded), not round the box, which is the strip's whole height for its clicks.
- Every part of a tab is clipped at the line's top edge: an outline that ended on the line's middle spilled its round
  end into the line and under it, and the chosen tab's fill hid the line under its feet. The line goes only under the
  chosen tab's own width, which a rect of the page covers. `tests/scenarios/tab_face_test.odin` checks every column.
- Every stroke of a tab is opaque, its colour mixed over what it lies on (`face_over`): a translucent `path_stroke` draws
  through a layer of its own, a render target per unchosen tab in every frame that draws them.
- The chosen tab's fill is the page's colour, not the content's. A panel that paints its own ground in another colour
  shows a seam; such a program builds its tab with `Dock_Options.tab` or gives the theme its own `tab_on background`.
- A strip that has its own line under it must not draw it as a side: the tab cannot cover a side. The debug window's
  row and fidget's draw `tab_line_draw` on the row they put `ui.tabs` in.
- The shapes are paths (`draw.path_arc`, `path_fill`, `path_stroke`): antialiased at any scale.

## History

- An accent underline under the chosen tab's words: three px of accent under a word in a dark bar did not read as the
  page in front.
- The raised plate (the segmented control's chosen segment): it said which tab was in front, but as a button.
- The flat tab, the page's colour with an accent line at its top and dividers between the others: correct, and read as
  nothing.
- Before all of them, the views had their own look: a block tinted with the accent for the shown tab and ghost buttons
  for the others. A tinted block reads as a selected row of a list.

## Refused

- **A button's face for the chosen tab** (the plate): it is what made tabs read as buttons.
- **An accent line on the chosen tab, dividers between the others**: the flat look; the silhouette says both.
- **A padding before the first tab, a margin round a pane**: room lost for nothing; the first tab's straight side is its
  alignment with the panel.
- **A look per row of tabs** (dock, views, `ui.tabs`): one look in one file, so a program's tabs and the toolkit's agree.
