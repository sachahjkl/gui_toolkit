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

- **One face, public.** `tab_face(b, on, mark)` applies the look to any box: `tab_box` (the toolkit's rows) is a
  box and `tab_face`, so a program's own strip (classeur's tabs: a fixed width, drags, drop zones, its own content)
  draws the same pixels as `ui.tabs` (`tests/scenarios/tab_face_test.odin`), with no second path. `tab_body` and
  `tab_strip_start` are public with it. `mark`: classeur's accent on the focused panel's tab, drawn inside the
  shape along its top. Refused: a `tab_box` with options for every program's needs (the box is the program's), the
  look copied in each program (it drifted with every change of the face).

- **A tab gives way before its strip scrolls.** Its box and body are `children_sum(0)`; its words are sized by
  `tab_title_width`: their own width, cut with an ellipsis down to `TAB_TITLE_LEAST_EM` of text. The strip gives the
  room ([strip.md](strip.md)). A stack of views counts a tab cut to that least, an arrow and its "+" before it shows the
  view's moves and its window-sized buttons (`VIEW_STRIP_TABS_LEAST_EM`): with 3 em it showed them, and its Close ran
  past the window's edge.

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
- **Every tab has its whole silhouette, the first included.** Both feet curve out of the line, whatever its place.
- **The first tab starts a small inset from the pane's edge** (`tab_strip_inset`): the room its left foot needs and a
  short run of the line (`TAB_LINE_LEAD_PX`, 3 px), so the line leaves the pane's edge, runs a few pixels and curves up
  into the tab, as the owner's sketch draws it. Nothing more: no big margin, no padding of the pane.
- **The words sit in the middle of the shape.** `tab_body` is a row as tall as the visible part of the shape (the
  strip's ground shows above it), the tab's content centred across it, not across the strip.
- **A panel's content aligns with its first tab's words.** They start `tab_strip_inset` and `DOCK_TAB_PAD_EM` from
  the stack's edge; `dock_content_inset()` gives that distance to a panel. A pane adds no inset of its own: only the splitter separates two.
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
- **The chosen tab's feet are one path with the line.** The line and the outline are stroked once: from the strip's
  left end along the line, up the left fillet (tangent to the line at its outer end, to the side at its top), over the
  top, down and along the line to the strip's right end, round joins inside and no cap at a foot. Its fill is the same
  shape closed along the line's bottom edge, drawn before the stroke: under the tab and its feet the line is the page.
  Drawn apart (a stroke ending on the line's middle, a line running on under the fillet to the side, a rect of the page
  under the tab's width), the feet showed hooks: the line ran under the curve to the side, round caps overlapped it.
- **Every stroke's coordinates sit on its pixel centre** (`tab_snap`: a half pixel for a 1 px stroke, a whole one for
  2 px); the line's box draws on whole pixels; the radii are whole pixels, so the arcs land on the line at 100, 125,
  150 and 200 %. Nothing of a tab draws below the line's bottom edge nor beyond its strip's ends (a clip).
- **A strip is a bar, never a key.** Its ground is painted flat by `tab_strip_draw` (the box keeps `.Draw_Background`
  for what stands in it, with `.Custom_Ground`): a bar's face in a finish with a relief has a lit rim, and a clickable
  box with it is drawn as a key's bevel. The views' strip took presses (a double click maximises, a right click opens
  the menu) since 0.366 and was drawn as one big button (Tower's bottom terminal); its presses now go to a box with no
  face inside the ground. The dock's strips have the same ground.
- **An unchosen tab's outline flows into the line and never draws on it**: its small fillets (half the chosen tab's) are
  cut at the line's top edge. The line is the strip's colour, the outline a fainter one: a stroke on the line would show.
- `tests/docking/dock_tab_look_test.odin` reads the columns round each foot at every scale (nothing below the line,
  nothing beside the fillet, no line under the curve, the right foot the mirror of the left);
  `tests/scenarios/tab_face_test.odin` checks every column of the line in a program's row.
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
- The first silhouette (never released) gave the tab at an end of its strip a straight side, in line with its panel, and stood
  the first tab at the pane's edge. It read as a tab glued to the edge, its shape cut: the owner's remark on the void
  meant the big margin before the strip, not the room of the first tab's foot. Every tab now has both feet.
- The feet's junctions were drawn apart (an outline stroke ending on the line's middle, a rect of the page under the
  tab): the line ran on under each fillet to the side and made a hook, "disgusting overflows" in the owner's words. One
  path for the line and the outline replaced them.
- Before all of them, the views had their own look: a block tinted with the accent for the shown tab and ghost buttons
  for the others. A tinted block reads as a selected row of a list.

## Refused

- **A button's face for the chosen tab** (the plate): it is what made tabs read as buttons.
- **An accent line on the chosen tab, dividers between the others**: the flat look; the silhouette says both.
- **A margin round a pane, a padding before the first tab beyond its foot's room**: room lost for nothing.
- **A straight side at the strip's ends**: the first tab glued to the pane's edge, its shape cut.
- **A look per row of tabs** (dock, views, `ui.tabs`): one look in one file, so a program's tabs and the toolkit's agree.
