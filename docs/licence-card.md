# The licence card

`ui.licence_card` shows a registered licence as an object: a dark foil engraved like a banknote, iridescent, a light
that sweeps across it, the person's name raised in brushed silver, a gold-and-enamel seal in relief, and a back with the
program's logo raised. It tilts towards the pointer and turns over. It is the same in every program; the settings'
Licence page shows it for a registered licence ([prefs_page.md](prefs_page.md#the-licence)). The design and its decisions
are in [src/md/features/licence-card.md](../src/md/features/licence-card.md).

```odin
ui.licence_card("licence", {
	product = "Inspecteur", edition = "Personal licence", name = lic.name, email = lic.email,
	date = lic.date, order = lic.order, logo = LOGO_PNG, back_line = "INSPECTEUR · FROMENT SOFTWARE",
})
```

## What it takes

| field | |
|---|---|
| `product` | the program's name: at the top left, and repeated in the microprint of the frame |
| `edition` | the edition's title for people (`licence.edition_title`): at the top right, in small capitals |
| `name` | who the licence is made out to: set smaller when it is wider than the card, so that it is whole |
| `email`, `date`, `order` | each "" when there is none (the date and the order are labelled Issued and Order) |
| `logo` | the program's logo, the bytes of a picture file (a `#load` of its PNG): printed on the front, raised on the back; nil: none |
| `back_line` | the line along the back's bottom ("": the product's name in capitals); nothing of the person is on the back |

The strings are read during the build and the frame's draw; `logo` is a constant of the program (its address keys the
textures made from it).

Every card carries the same code engraved at the bottom right of its back (`ui.LICENCE_CARD_SEAL_URL`, a step of a hunt
across the programs): there is nothing to set.

It is as wide as `ui.LICENCE_CARD_WIDTH_EM` font sizes (440 pixels at a font of 15), or its parent when that is narrower;
its height follows its width (a bank card's shape, `LICENCE_CARD_ASPECT`), with room above and below for its tilt. It
returns the card's signal. To a screen reader it is an image named by all it says.

## How it moves

- **Tilt**: the pointer over the card turns it towards itself (at most 14 degrees about x and 18 about y), and the
  second light follows the pointer. The pointer gone, it eases back (0.55 s).
- **The sweep**: a light crosses the card from its bottom left to its top right (2.8 s) when the card first shows its
  foil and each time the pointer comes onto it.
- **Turn over**: the button under the card (shown while the pointer is on the card or the button has the keyboard) frees
  it. A drag turns it on two axes with no limit; a drag let go while it moves flings it, slowing down; the arrows turn it
  by 30 degrees. Past a quarter turn the back shows. **Done** or Escape brings it home by the short way.
- **Less motion** (the animations off: `platform.os_animations_enabled`, `ui.set_animations`): no tilt, no sweep, no
  button; the foil is lit at a fixed angle.

**At rest it asks for no frame.** A frame is asked only while an ease, the sweep, a fling or the button's fade runs; the
tilt moves with the pointer's own events.

## How it is drawn

- The front and the back are planes (`draw.push_plane`) drawn by the toolkit's application shader `src/ui/licence_card.wgsl`
  (two passes: the engraving's shade, then the light); the seal is a plane of its own 5 units above the front; the rim of
  the card and the edge of the seal are flat facets, projected and shaded by their orientation. Seen from the front, the
  back is not drawn; seen from behind, the front and the seal are not. At rest the card is drawn straight, with no layer.
- Its textures (the front's relief, its raised lettering, the seal's relief and lettering, the back's relief with the
  logo raised, the back's lettering, the logo) are made on chores (`ui.task`) and kept with the renderer: another card,
  or the page shown again, costs nothing; a change of the text makes the lettering alone again. After a device loss they
  are made again. The lettering's glyph outlines are taken on the interface's thread (`font.glyph_outline`); the rest is
  the chores'.
- **The flat card.** Until its textures are there, where the shader cannot be had (Direct3D 11 without its blob, a module
  the device refused), while a picture is recorded, or when `ui.set_licence_card_flat(s, true)` asks for it, the card is
  drawn flat: the dark gradient, the text plain, a drawn medal. It reads as well.
- The card is an object, not a surface of the theme: it is the same in every finish and every theme. The button under it
  is the theme's.

Direct3D 11 runs the shader from its blob `src/ui/shaders/licence_card.dxbc` and its hash `licence_card.sha256`, which the
workflow `shaders.yml` writes on Windows after the WGSL changes (or `rect.wgsl` does): see [shaders.md](shaders.md). A blob
that is missing or stale is refused, and the card is drawn flat.

## For a test or a tool

```odin
ui.licence_card_look(state, "licence")   // found, settled, shaded, plain_text, turned, back, rx, ry, sweeping, moving
ui.set_licence_card_flat(state, true)     // every card of the State drawn flat
ui.licence_card_seal_module(x, y)         // whether module (x, y) of the back's code is dark (LICENCE_CARD_SEAL_MODULES a side)
ui.licence_card_seal_reveal(rx, ry)       // 0 .. 1: how much of the code's contrast the back shows at that turn (turns)
```

`tests/licence_card`: a picture per finish on a dark and a light theme (the foil and the flat card), no frame due at rest
after the sweep and an ease, the tilt that follows the pointer and comes back, the turn over and Escape, the flat card
whole with a long name; the back's code decodes to its address, shows only at its turn, and on a device of its own reads
from the pixels at that turn and not straight on.
