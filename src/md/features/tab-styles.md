# The tabs' styles and the surface they frame: intent (design proposals)

The code is `src/ui/tab_style.odin` (`Tab_Style`, `Tab_Surface`, `tab_panel`), with `tab_face.odin` ([tabs.md](tabs.md))
and `ui.tabs_ex` (`widgets_ext.odin`). This branch holds four proposals for the owner to choose from; the chosen one
replaces the silhouette and the others go.

## The fault

"The tabs do not integrate with what they frame." Three captures showed it:

- ardoise: the chosen tab was the page's colour over a terminal of another colour, and the strip's line ran under a
  terminal that drew its own border: a double border, a tab pasted on top. The unchosen tabs' outlines read as boxes.
- feuille's signature panel: a cut between the card and its tabs.
- the dock editor: every pane the page's colour, so the fault did not show; it shows as soon as a panel has its own
  ground (an editor's, a terminal's).

The cause is one missing fact: nothing told the strip the surface under it. The chosen tab took "tab_on background",
the page; the strip drew its line in the border's colour; the content drew its own frame. Three parties, three colours,
two borders.

## The rule

- **The content names its surface once** (`Tab_Surface{ground, edge}`): `tab_surface` around a strip, `Dock_Options.surface`
  per panel, `Tab_Panel_Options.surface`. Every part of the strip reads it: the chosen tab's fill, the strip's ground,
  the line, the band. A zero ground is the page's, a zero edge the border: the silhouette is unchanged by default.
- **One party draws the frame.** `tab_panel` builds the strip and the page in one box and draws one outline: the
  content inside draws none. The dock paints a panel's body with its surface, so a program stops painting its own
  ground under a stack's strip.
- **Tones are steps off the surface, measured in sRGB lightness** (`tab_lightness`; the theme's colours are linear): a
  step in linear luminance vanished on a light card and was huge on a dark one. The band (Header) and the track
  (Segmented) move from the surface toward the page, the chrome around it: a card lighter than the page gets a darker
  band, a terminal darker than the page a lighter one. A fixed "darker" vanished on a terminal's near black.
- **Colours are read in the build** (`Tab_Draw.accent`, `Tab_Panel_Draw.band`): a draw has no tags, and `color`
  there did not give the page.

## The four styles

- **Folder (A).** The chosen tab is the silhouette filled with the surface's ground and stroked with its edge, without
  the finish's light (its top would no longer be its page's colour). The line is the frame's top edge. Unchosen tabs:
  words on the strip, a fill in the tab's shape under the pointer, no outline. In a `tab_panel` the first tab stands a
  corner's radius in, so its foot does not land on the frame's curve.
- **Underline (B).** The strip stands on the surface; no line, no border between them. The chosen tab: its words in
  the text's colour over a 2 px accent bar at the strip's bottom; the others weak. A `tab_panel` puts the first words
  over the page's first column.
- **Segmented (C).** A switcher inside the panel's one frame: a track a step off the surface (lighter on a dark
  palette, darker on a light one), the chosen key lighter again (white on a light palette) with a faint edge. Each tab
  paints its part of the track, its ends rounded at the first and the last; the strip's clip lets the track's pad out.
- **Header (D).** The strip is the panel's header band; the chosen tab is a hole in it onto the surface (its exact
  ground, full height, 2 px accent along its top); the others weak words, a short separator between two unchosen tabs.
  This refines the brief ("a raised surface"): a raised tab of another colour than its page is the paste-on look again.

## Subtle points

- The Folder's frame draws its outline before the tabs (the chosen tab covers the line under it and strokes its own
  outline onto it, the same pixels, opaque). The other styles draw their outline after the tabs, over what reaches a
  rounded corner, inside a rounded clip.
- `tabs_ex` does not set the strip's line when `framed` (inside a `tab_panel`): the panel owns it.
- The dock keeps each tab's close-button room; under Segmented the key is that wide.

## What Tower asked, in the same API

- **A tab's own content**: `Tabs_Options.content` builds in the tab's body (index, chosen, hot, the box, the label);
  `tab_face` stays public for a strip a program builds itself.
- **A right click**: `Tabs_Result.menu` is the tab whose menu was asked (right click, Menu key, Shift+F10) and
  `menu_at` where; `closed` a middle click.
- `Tabs_Options.after` builds after the last tab (a "+"), across the words' height.

## Refused

- **A fixed tone step for every surface**: it vanished on a near-black terminal and on a white card.
- **A raised chosen tab (D as briefed)**: a fill other than the page's is what read as pasted.
- **Letting the content keep its own border under a strip**: the double border.
