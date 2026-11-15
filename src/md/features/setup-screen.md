# The setup screen: intent

The setup's view (`src/setup/dialog.odin`) is the first screen a person sees of a program, before it is even
installed. It shows the program first, what it will do second, and its maker last.

## The problem

The screen was five framed panels of the same weight stacked: a header with a small logo, an empty field, a bar named
"Options" that looked like a field, a box per option, and a box of dashes. Nothing said which program this was at a
glance; the eye had nowhere to go first; the vendor was a line of small grey words.

## Decisions

- **A hero, without a frame.** The program's logo large (`HERO_LOGO_EM`, 4.5 em), its name (1.6 em), what it is
  (`Identity.description`), its state as a pill (`ui.pill`, the state's glyph and tone) beside the version, and what
  the state means in one weak sentence under it. A band of the accent's tint fading down carries it: each program's
  setup wears its colour. A program without a logo shows its initial on a tile of its accent, so the hero keeps its
  shape.
- **The action is the primary button, not a title.** "Install Papier", "Upgrade to 0.28.0", "Repair" are the button's
  words; the title is the program's name. (`headline` still says the action, for a screen of a program's own.)
- **The location only when it means something.** A field and "Choose…" before the first install, prefilled with the
  system's default folder at the first reading; the installed program's path after. Nothing when there is neither.
- **The options as a list card of switches** (`ui.list_card`, `ui.toggle(wrap = true)`): an option is a state that
  holds, which a switch says better than a box to tick; hairlines between, no frame per option.
- **Details folded, Uninstall never hidden.** The parts of the install (menu entry, record, this copy), the note of
  NixOS and what the last action said fold under "Details". Uninstall stays on the details' line, a danger link, open
  or folded: one click away, never a primary button beside Install.
- **A footer for the maker and the acts.** Under a hairline: "By <mark> <vendor>" on the left (the same signature as
  the sites' foot), what closes and what installs on the right.
- **A copy from the Nix store has a screen of its own.** Under the hero, the rest of the dialog is Nix's snowflake on
  a disc of Nix's two blues, "Managed by Nix", why there is nothing to do here, and the store path: it cannot be read
  as an install that failed. What an earlier install left, if any, can still go from the details.
- **The spacing scale throughout** ([spacing.md](spacing.md)): PAGE_MARGIN at the sides, ITEM_GAP between sections,
  LINE_GAP under a section's head, CARD_PAD in the card.

Refused:

- **A centred hero** (logo above the name): a showcase's layout, it takes a dialog's height for nothing.
- **Uninstall in the footer**: next to Install, a red button is one mis-click from a loss.
- **Details open when an install is there**: they pushed the options and the buttons into a scroll.

## Subtle points

- The settings' Installation page (`src/setup/page.odin`) keeps its own denser layout: it lives inside the settings,
  which have their own header.
- The ids the tests and the programs' automation find stay (`setup_install`, `setup_uninstall`, `setup_tile_<k>`,
  `setup_choice_<k>`, `setup_logo`, `setup_by_*`); `Dialog.at` marks Uninstall from the details' line.
