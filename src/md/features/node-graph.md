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
- The tooltips are placed with `tooltip_near` around the node or the port (`tooltips.md`): a cut title's goes around
  the whole node, not its header, so it covers neither the title nor the lines under it; in `.Right` the rectangle
  includes the message drawn under the node.
