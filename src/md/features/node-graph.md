# The node graph

`ui.node_graph` (`src/ui/node_graph*.odin`) draws a graph of nodes and links and turns the pointer and the keys into
events. The program owns the model, the selection and the undo; the widget owns only the view's gesture. Two programs
shape it: cliche edits a flow of image steps (links left to right, typed ports), Tower shows a swarm of agents (a tree
from top to bottom, one link per child, states that change while it is watched). Documentation: `docs/node_graph.md`.

## Decisions

- **The direction is the graph's, not a port's.** `Graph_Options.direction` (`Graph_Direction`) is `.Right` (in ports on
  a node's left side, out ports on its right) or `.Down` (in ports along its top edge, out ports along its bottom edge).
  A port keeps its meaning (`flowgraph.Side`: in or out); the direction only says where each side is drawn and which
  way a link bends. One direction per graph keeps every curve the same shape: a link always leaves its out port along
  the flow and enters its in port along it. Refused: a side per port (top, left, ...): a link between two ports placed
  across each other has no good bend, and no program asked for a mixed graph.
- **Ports sit on the edges, beside the body.** In `.Right` the ports of a side are spread evenly over the node's edge,
  from under the header to the bottom, and the thumbnail and widgets start right under the header: ports add no band
  of rows that pushes the content down. The edge is at least a row per port; a node with no content is then as tall
  as the old rows, with its ports at the same places. A name is drawn where nothing is beside it (no content); else it
  is a tooltip, as in `.Down`. `Graph_Options.port_rows` keeps the rows (a typed flow whose names must show next to a
  thumbnail). Refused: names over the body (they cover its widgets); a row layout by default (it doubled a node's
  height in Tower's swarm for ports that have no name).
- **In `.Down`, ports have no rows.** A node's ports share its edge, spaced evenly, and their names are not drawn on
  the node (a name beside a dot on the edge covers the header or the body). A dot stands outside its edge, touching
  it: across the top edge it covers the title's first line, across the bottom edge the message and the border. A named port shows its name in a tooltip
  when the pointer rests on it. A tree's ports are usually one in and one out, with no name. The node's message is a
  line inside it, under the header: under the node is where its links leave.
- **A link's look is the program's, per link.** `Graph_Options.link_looks` is a slice in the order of `links`
  (`Graph_Link_Look`: an `Intent` and a `Graph_Dash`). The zero look is the old one: solid, in the colour of its out
  port's kind. An intent other than `.Neutral` is the theme's hue of that intent (`intent_hue`): the program says what
  the link means (a failed child, a waiting one), the theme says its colour, and a theme change recolours it. Refused:
  a raw colour per link (it does not follow the theme, and the light and dark versions need two); a look in
  `Graph_Link` (a link is an identity that events carry and programs compare: a look in it breaks `==`); a callback
  per link (a slice is data the program already has in the order of its links).
- **Dashes are an enum, measured in link widths.** `.Solid`, `.Dashed`, `.Dotted` (round dots): a pattern in pixels
  would be wrong at every zoom; in widths it scales with the link. `draw.path_dash` cuts the curve.
- **A title takes two lines at most.** It wraps at the node's width (`wrap_lines`); a third line is cut with an
  ellipsis (`elide`) at the end of the second, and the whole title shows in a tooltip when the pointer rests on the
  header. The header grows by one line for a two-line title: the node is as tall as its title needs. The title's room
  always leaves the place of the state's mark, even for an idle node: a run that starts must not wrap a title again
  and move the node's ports under the pointer.
- **`Graph_View.hover_node` is the node under the pointer** (its ports count), 0 for none, set at each build from the
  widget's own hit test, the same as its gestures use. A program shows something about a node under the pointer (a
  card, a detail pane) without testing the hit itself with the widget's private sizes. It is 0 when the pointer is over
  something built over the graph (a popup, a button). `hover_link` is the link under the pointer, as before.
- **The link under the pointer stands out of a bundle.** Where links overlap, a thicker stroke alone does not say which
  one is hovered: its neighbours are as bright and cross over it. So the hovered link is drawn last, over every other
  link, on a halo (an opaque band of its colour mixed into the well) that cuts the links it crosses; its colour steps
  toward the theme's text (`srgb_step`: lighter on a dark theme, darker on a light one); its two ports glow and its two
  nodes' edges take its colour; the other links fade toward the well. The eye follows one path from end to end.
- **The emphasis keeps contrast floors on the well, in every theme.** A lit link reads at 3:1 at least
  (`GRAPH_LINK_LIT_CONTRAST`, WCAG's ratio for what is not text): its stepped colour goes on along its lightness
  (`readable`) where the step is not enough (a pale kind on a light theme). A faded link keeps 1.5:1
  (`GRAPH_LINK_DIM_CONTRAST`): the share of its colour it keeps is the larger of the fade's and the one that reaches it,
  computed from the luminances (a mix toward the well is linear in luminance). A link already under 1.5:1 does not fade.
  Without the floor a light theme faded every other link to 1.2:1: the graph was gone around the hovered link.
  Refused: the accent for the hovered link (a link's colour says its kind or its state: the hover must not hide it);
  translucent halos and fades (a translucent stroke goes through a layer, one per link: opaque mixes with the well cost
  nothing).
- **A node under the pointer lights its links the same way**, in and out, in their own colours; the others fade less
  (`GRAPH_LINK_DIM_NODE`) than for one link (`GRAPH_LINK_DIM_LINK`): a node's links are read among the rest, one link
  alone. During a move the moved node lights its links. A node without a link fades nothing. Refused: two tones for in
  and out (they replace the link's own colour; the direction is read from the curve, which leaves its out port along
  the flow).
- **The selection's links are drawn over the plain ones**, thicker and lighter, but fade nothing: a fade that lasts as
  long as a selection hides the rest of the graph for minutes. Only the pointer fades.
- **The pick is the nearest link; Alt+wheel walks the others.** The hit test measures the distance to each curve
  within a hit width that scales with the zoom as the stroke does (never less than half the hovered stroke) and takes
  the nearest; on a tie, the one drawn last (on top). Where several links are within the hit width, a tooltip near the
  pointer names the hovered one (its two ends: node · port → node · port) and its place among them ("2 of 3 here");
  Alt+wheel takes the next or the one before, in the links' order (stable while the pointer moves, unlike an order by
  distance), and shows the tooltip at once. The wheel's fractions (a touchpad) add up to whole steps
  (`Graph_View.link_wheel`): one swipe does not spin through the bundle. The tooltip avoids the points of the hovered
  link's curve (`tooltip_near`'s `avoid`): it goes beside a steep link, not over the part of it under the pointer. A
  click selects the link picked. The pick (`Graph_View.link_pick`) lasts
  while its link is under the pointer. Over one link or none, Alt+wheel moves the view as the wheel does. Refused: Tab
  (it moves the focus between widgets); a tooltip on every link (one link alone is read from its curve: the tooltip
  would cover the graph at each rest). Some window managers take Alt+wheel (Xfce zooms the desktop with it): the pick
  is then the nearest link only, and the pointer moves to reach another. On Windows the toolkit keeps Alt's key down
  from the system, so releasing Alt after the wheel opens no menu. The links have no keyboard path and no place in
  the accessibility tree yet (ROADMAP).
- **The emphasis fades through `anim`, one value per graph.** `Graph_View.lit_link` or `lit_node` keep what it is
  about while it fades out; from one link to another it moves at once (the fade is for the graph's change, not for
  each link). At rest nothing asks for a frame.
- **The minimap has a corner and a size** (`Graph_Minimap`: `show`, `corner`, `size`). Its default size is a share
  of the area within limits (`GRAPH_MINIMAP_SHARE` of its width, between `GRAPH_MINIMAP_LEAST` and
  `GRAPH_MINIMAP_MOST` logical px, its height a fixed ratio, at most `GRAPH_MINIMAP_TALL` of the area's height): the
  old fixed 200 × 130 covered a third of a narrow side panel. An area too small for the least size shows no minimap.
- **`graph_fit` leaves the minimap's corner free.** It fits the nodes in the area less a column or a band on the
  minimap's side, whichever gives the larger zoom. A room with no inside within the fit's margins (a map almost as
  wide as the area) is never chosen; with neither room, the nodes fit in the whole area. The view keeps the minimap's corner and size of the last build, so a
  fit from a key (F), from the "Back to content" button or from the program avoids it alike. Refused: fitting in the
  whole area and moving the minimap away (a map that jumps between corners is not found again).

## Subtleties

- The view knows what its last build was laid out with (`em`, `scale`, `direction`, the title font, the minimap):
  `graph_node_rect`, `graph_port_pos` and `graph_fit` called between builds use it. Before the first build they use the
  defaults: a program that fits before its first frame fits again after it.
- A title is measured in graph units (at the em of the zoom 1) and drawn at the zoom's size: the lines are those of the
  zoom 1, so a node keeps its shape while the zoom changes. The second line is cut at the drawn size.
- The tooltips of the graph (a cut title, a port's name) wait the pointer's rest (`Feel.tooltip_delay_ms`) on one target:
  the graph keeps the target and the time it came, since the area is one box and the toolkit's rest is per box.
- The hit test of the links costs a box test per link and a distance to the curve (24 segments) for the links whose box,
  widened by the hit width, holds the pointer. It runs in a frame only: a still pointer and a graph at rest ask none.
- The tooltips are placed with `tooltip_near` around the node or the port (`tooltips.md`): a cut title's goes around
  the whole node, not its header, so it covers neither the title nor the lines under it; in `.Right` the rectangle
  includes the message drawn under the node.
