# The licence card and the thank-you page

Asked by the user on 2026-11-16: what a buyer of Wren gets, every program gives. Two pieces, one look:

- **On the site**, the thank-you page that hands the licence over: the program's logo floating in its glow, the confetti
  when the licence arrives, the key in a champagne-gold frame with a glint and twinkling stars (Wren's
  `site/thanks/index.html`).
- **In the program**, the licence as a card: a dark foil engraved like a banknote, iridescent, a light that sweeps across
  it, the card that tilts towards the pointer, a gold-and-enamel seal in relief, the person's name raised in brushed
  silver, and a back to turn it over to (Wren's `about_card*.odin`, its `card-foil` and `card-seal` shaders).

Wren made both for itself, its card in its page engine's CSS. The toolkit makes them once, natively, for every program;
Wren then shows the toolkit's card, so one card exists.

## The thank-you page

The shop's template `src/site/licence_pages/thanks.html` and its block (`licence_thanks_block`, `<!-- licence-thanks -->`)
take Wren's page whole, with the program's own name, logo and accent instead of Wren's:

- the hero: the logo floating (a slow bob), with a glow of the accent around it, the title, a status line with three
  waiting dots while the Worker makes the licence;
- on the licence's arrival: a short burst of confetti (the accent, gold, white and three fixed hues), the card of the
  licence rising in, a sheen passing over it once, six gold stars twinkling at its corners;
- the key in a box with a champagne-gold edge and a slow glint across it; Download and Copy (two labels in one cell,
  so the button keeps one width);
- the help block: a problem with the licence, the order number filled in the help form's address, never the key.

Everything moves only with the visitor's consent to motion (`prefers-reduced-motion` stops it all, the confetti too). The
protocol does not change: the Worker's `/licence?txn=` answers 202 while it works, 200 with the licence.

The colours are the site's own variables (`--shop-accent`, its text and surfaces), never Wren's blue: a program's thank-you
page looks like its site. The gold is the same for every program: it says "a licence", not "this program".

## The card: `ui.licence_card`

```
ui.licence_card("licence", {product = "Inspecteur", edition = "Personal licence", name = lic.name, email = lic.email,
	date = lic.date, order = lic.order, logo = app.logo})
```

One widget, drawn by the toolkit, the same in every program. The settings' Licence page (`prefs_page.licence`) shows it
for a registered licence, in place of its plain lines; an unregistered program shows no card.

### What it is made of

The card is two faces and a thickness, composed in 3D with the toolkit's planes (`draw.push_plane`, `draw_plane`, a
`Mat4` with a perspective), as Wren's page engine composes Wren's:

- **The front**: a plane drawn by an application shader (`render.create_app_shader`, `draw.app_shader`): the module
  `licence_card.wgsl`, Wren's `card_foil.wgsl` taken whole, in its three modes (the card, the seal, the back).
- **The relief**: a normal map made natively (Wren's `about_card_relief.odin`): a guilloche of two rosettes, a lipped
  frame with a groove, micro-lettering of the product's name in the frame, a grain. 2x the card's size at 100 %.
- **The lettering**: the product, the edition, the name, the e-mail, the date and the order, rasterised from the
  glyphs' outlines and raised with a bevel (Wren's `about_card_engrave.odin`): silver, lit with the card's lights.
- **The seal**: a medal stuck on the card, its own plane a few pixels above it with a cast shadow (Wren's
  `about_card_seal.odin`): a reeded gold edge, a domed green face with fine rings, CERTIFIED and a tick raised.
- **The back**: the front's relief inside out, the program's logo raised in the middle (its picture, taken as a height
  field), a line of lettering with the vendor's name. Nothing of the person is on this side.
- **The thickness**: the rim of a bank card, flat strips edge-on behind the front, shaded by their orientation, so a
  tilt shows a solid and not a sheet.

### How it moves

- **Tilt**: the pointer over the card tilts it towards itself (rotateX / rotateY, at most 14 and 18 degrees), the second
  light follows the pointer, the lettering slides a little over the foil (parallax). The pointer gone, it eases back.
- **The sweep**: a light crosses the card from its bottom left to its top right. It passes when the card is first shown
  and each time the pointer comes onto it; in between it is off.
- **Turn over**: a "Turn over" button under the card, shown on hover or focus, frees the card: a drag turns it on two
  axes with no limit, and a fling slows down; past a quarter turn the back shows. Done or Escape brings it back, by the
  short way. The arrows turn it by 30 degrees while it is free.
- **At rest, no frame.** The card asks for frames only while something moves: the pointer over it, an ease, the sweep,
  a fling. A card that sits on a page costs nothing, as Wren's did. The textures are made once (on a task, off the
  interface's thread: the relief is the costly part) and kept with the renderer; a change of the lettering remakes the
  lettering alone.
- **Less motion** (`platform.os_animations_enabled` false, or the program's own setting): no tilt, no sweep, no button;
  the foil lit at a fixed angle.

### Where it cannot be had

When the application shader cannot be had (the device refused the module, a picture is being recorded, the textures
are not made yet), the card is drawn flat: the dark gradient of Wren's CSS fallback, the lettering as plain text, the
seal as a drawn medal. It reads well without the foil, as Wren's page did.

### Decisions of the native card

- **The logo is a picture file's bytes** (`Licence_Card.logo`, the program's `#load` of its PNG), not a texture: the back
  needs its pixels as a height field, made on a chore. Its address keys the textures made of it: a constant of the program.
- **The thickness is drawn, not composited.** Wren's rim was 52 thin planes for its page engine's compositor (a layer each,
  sorted, split where they crossed). The card is a convex solid: its faces that face the eye never cover each other. So
  the rim's facets and the seal's edge are projected polygons, drawn when they face the eye, before the face they border;
  only the front, the seal and the back are planes. No crossing to avoid, no gap, no sort.
- **At rest, no plane.** With no turn the projection is the identity (the seal's perspective enlargement cancelled, as
  Wren's scale did): the card is drawn straight, with no layer.
- **The textures are the renderer's, not the card's.** A thread-local cache of the interface's thread, by renderer id:
  each texture known by its kind and a hash of its inputs, made on a chore, uploaded at the next draw, the least
  recently asked one dropped past a dozen. A device loss marks them lost (the handles stay): made again. The lettering's
  glyph outlines are taken on the interface's thread (the font state is its own); their coverage and bevel are the
  chore's.
- **The sweep on the pointer's arrival reads.** Wren's sweep gave way to the pointer's light by 90 %; a pass that starts as
  the pointer comes would not show, so it gives way by half.
- **The first sweep waits for the foil**: it starts at the first build after the card drew its foil, not before (a flat
  card has none to sweep).

### The finishes and the themes

The card is an object, not a surface of the theme: its foil, its silver and its gold are the same in every finish and
every theme, as a bank card is the same on any table. What the theme gives is around it: the page, the button's look.
In the Flat finish the card keeps its relief: a licence is the one place where the toolkit shows off.

## Decisions refused

- **The card as a picture** (a pre-rendered PNG per program). It cannot tilt, catch the light or be turned over, and the
  name on it is the person's.
- **A CSS card in each program's site only**. The program is where the person looks at their licence; the site sees it
  once.
- **A widget per program** (each program its own copy of Wren's). One card, so a fix reaches all of them.
- **A finish-dependent card** (flat in Flat). Rejected above: the card is an object.

## Tests

- **One picture per finish and per theme**: the Licence page with a registered licence, in each finish (Flat, Gradient,
  Glass, Machined, Edged) on a dark and a light theme, compared with references (`tests/licence_card`): the flat card
  on every device, the foil on a GPU of its own. On WARP (the Windows runners' software rasterizer) a foil frame takes
  seconds and its pixels are not a GPU's: the foil pictures are not taken there, and the motion tests draw the card flat
  (its motion does not depend on the foil). WebGPU over WARP takes no picture at all (a third of a second a frame:
  ten pictures pass a test's limit); the Direct3D 11 job compares the flat card on WARP.
- **The card at rest asks for no frame**: after the sweep and an ease, `hosts_due` says nothing is due.
- **The tilt follows the pointer and comes back**: the pointer on a corner, the card's turn towards it; gone, zero.
- **Turn over**: a drag of half a turn shows the back (its plane drawn, the front's culled); Escape brings it back.
- **The fallback**: with the shader refused, the card is drawn flat with its plain text, whole.
- **The thank-you page**: the site's test builds it for a program and checks the program's name, logo and accent, and
  that the script, given a 200 from a fake Worker, shows the key and the buttons.

The single test that breaks the design on day one: a card shown for a minute with the pointer elsewhere must have
asked for no frame after its sweep.
