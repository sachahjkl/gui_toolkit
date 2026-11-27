# The tabs' styles and the surface they frame: intent

The code is `src/ui/tab_style.odin` (`Tab_Style`, `Tab_Surface`, `tabs_over`, every style's draw), `tab_face.odin` (the
face of a tab, a Folder's chosen silhouette: [tabs.md](tabs.md)), `tab_panel.odin` (`ui.tab_panel`) and `ui.tabs_ex`
(`widgets_ext.odin`). How a program uses them: [docs/widgets.md](../../../docs/widgets.md) ("Tabs over a surface of their
own"), [docs/docking.md](../../../docs/docking.md).

## The fault

"The tabs do not integrate with what they frame." Three captures showed it:

- ardoise: the chosen tab was the page's colour over a terminal of another colour, and the strip's line ran under a
  terminal that drew its own border: a double border, a tab pasted on top. The unchosen tabs' outlines read as boxes.
- feuille's signature panel: a cut between the card and its tabs.
- the dock editor: every pane the page's colour, so the fault did not show; it shows as soon as a panel has its own
  ground (an editor's, a terminal's).

The cause is one missing fact: nothing told the strip the surface under it. The chosen tab took "tab_on background",
the page; the strip drew its line in the border's colour; the content drew its own frame. Three parties, three
colours, two borders.

## The rule

- **The content names its surface once** (`Tab_Surface{ground, edge}`): `Dock_Options.surface` per panel,
  `View_Options.surface` per kind of view, `Tab_Panel_Options.surface`, `tabs_over` round a program's own strip.
  Every part of the strip reads it: the chosen tab's fill, the strip's ground, a Folder's line, a Header's band, and
  the panel's body (a dock's, a view's) is painted with it. A zero ground is the page's, a zero edge the border.
- **One party draws the frame.** `tab_panel` builds the strip and the page in one box and draws one outline: the
  content inside draws none. A dock's or a view's body is painted by the toolkit, so a program paints no ground of its
  own under a stack's strip.
- **A style per strip, chosen by its context, never global.** The owner chose among four proposals, each drawn with
  the real renderer in a dock, a card and a terminal, dark and light:

| Context | Style | Why |
|---|---|---|
| A dock's stacks, a stack of views (Tower's terminals), an editor, a terminal | `.Underline` | The calmest: no border can double, whatever the panel's ground, a near-black terminal included |
| A small panel's modes (feuille's signature) | `.Segmented` (asked) | Not tabs glued to an edge: a control inside the panel's one frame |
| Documents (`ui.tabs`, `tab_panel`, a program's own strip) | `.Folder` | The tab is the page's surface, one outline round both |
| A panel with a header band | `.Header` (asked) | Kept: the owner keeps it available |

  The defaults: `Dock_Options.tab_style` and `View_Dock_Options.tab_style` nil: `.Underline`; `Tabs_Options.style`
  nil: `.Folder` (in a `tab_panel` too); a program's own strip with no `tabs_over` round it: `.Folder`, as the
  look it had. The debug window's dense strip: `.Underline`, in its dense scope.

- **Tones are steps off the surface, measured in sRGB lightness** (`tab_lightness`; the theme's colours are linear):
  a step in linear luminance vanished on a light card and was huge on a dark one. The band (Header) moves from the
  surface toward the page, the chrome around it: a card lighter than the page gets a darker band, a terminal darker
  than it a lighter one. The track (Segmented) is a step lighter than the surface on a dark palette (darker vanished on
  a near black), darker on a light one; the chosen key lighter again, white on a light palette.
- **Colours are read in the build** (`Tab_Draw`, `Tab_Panel_Draw`): a draw has no tags, and `color` there did not give
  the page.

## The four styles

- **Folder.** The chosen tab is the silhouette ([tabs.md](tabs.md)) filled with the surface's ground and stroked with
  its edge, without the finish's light (its top would no longer be its panel's colour). The line is the frame's top
  edge. Unchosen tabs: words on the strip, a fill in the tab's shape under the pointer, no outline (outlines read as
  boxes). In a `tab_panel` the first tab stands a corner's radius in, so its foot does not land on the frame's curve.
- **Underline.** The strip stands on the surface; no line, no border between them. The chosen tab: its words in the
  text's colour over a 2 px accent bar at the strip's bottom (a `mark`, the focused panel's, colours the bar); the
  others weak, a rounded fill under the pointer. The first tab at the edge: its words over the panel's first column
  (`dock_content_inset`).
- **Segmented.** A track a step off the surface, the chosen key on it with a faint edge. Each tab paints its part of
  the track, its ends rounded at the first and the last; the strip's clip lets the track's pad out. The owner: "the
  pills less, but they can serve": it is for small panels that switch modes, not for a dock.
- **Header.** The strip is the panel's header band; the chosen tab is a hole in it onto the surface (its exact ground,
  the strip's height, an accent along its top); the others weak words, a short separator between two unchosen tabs.
  Not a raised tab of another colour: that was the pasted look again.

## Subtle points

- `tabs_over` is a scope: `tab_face`, `tab_body`, `tab_strip_start` and `tab_strip_look` read the innermost. A
  `dock_panel` opens its stack's, so `dock_content_inset` inside it gives the stack's inset; `ui.tabs_ex` opens its
  own style on the surface of the scope around it (a `tab_panel`'s).
- A Folder's frame draws its outline before the tabs (the chosen tab covers the line under it and strokes its own
  outline onto it, the same pixels, opaque). The other styles draw their outline after the tabs, over what reaches a
  rounded corner, inside a rounded clip.
- `tabs_ex` draws a Folder's line under its strip unless `framed` (a `tab_panel` owns it); the other styles stand on
  what is under them, and a line there was the double border.
- The edged finish lit a dock's strip as a window's title where the focus was (`dock_strip_draw`). Gone: a strip on
  its panel's surface is not a caption, and the lit strip drew a band over the panel's colour.
- A dock keeps each tab's close-button room; under Segmented the key is that wide.

## Tower's asks

- **A tab's own content**: `Tabs_Options.content` builds in the tab's body (index, chosen, hot, the box, the label);
  `tab_face` stays public for a strip a program builds itself.
- **A right click**: `Tabs_Result.menu` is the tab whose menu was asked (a right click, the Menu key, Shift+F10) and
  `menu_at` where (the pointer, or under the tab); `closed` a middle click. Neither chooses the tab.
- `Tabs_Options.after` builds after the last tab (a "+"), across the words' height.

## Refused

- **A global style** (`set_tab_style`, the proposals' switch): a dock and a card's switcher in one program want two
  styles. Not kept as a program-wide default either: each strip's context decides, and a program changes one strip
  with one option.
- **The silhouette with outlined unchosen tabs and the finish's light** (0.366): the outlines read as boxes, the light
  made the tab another colour than its panel.
- **A fixed tone step for every surface**: it vanished on a near-black terminal and on a white card.
- **A raised chosen tab (Header as first briefed)**: a fill other than the panel's is what read as pasted.
- **Letting the content keep its own border under a strip**: the double border.
