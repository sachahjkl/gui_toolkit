# lucide: the Lucide icons

`import lucide "gt:lucide"` (the package is named `tk_lucide`). The [Lucide](https://lucide.dev) icons as a font (ISC
licence, `src/lucide/LICENSE.txt`): `DATA` is the face, and each constant is the character of one icon in it, named as
Lucide names it.

```odin
icons, _ := font.load_embedded(&fonts, lucide.DATA)
draw.text(dc, icons, size, pos, color, lucide.SEARCH)
```

The `prefs_page` icons of the pages (`Page_Info.icon`), the buttons of a toolbar, a menu's icons: any text drawn in that
face. One set for every program of the toolkit. Every icon of the font has its constant: `src/lucide/lucide.odin` is
generated from `lucide.ttf` by `odin run tools/tk -- gen_lucide`, a constant per glyph, UPPER_SNAKE of the glyph's name
in the font (`arrow-up-down` is `ARROW_UP_DOWN`; a name that starts with a digit takes an `N`). Do not edit it: a newer
font, then the command again. The names are the font's own, which are older than lucide.dev's for a few icons
(`ALERT_TRIANGLE` for triangle-alert, `SEND_HORIZONAL` for send-horizontal).

A program may make it its icon font (`ui.State.icon_font = icons`): `ui.icon`, `ui.icon_button`, a menu item's `icon`
and `ui.button_icon` then draw Lucide's characters. The widgets' own marks (a menu's or a check box's check, a
dropdown's arrow, a submenu's arrow, a number's − and +, a toast's sign) are characters of the toolkit's icon font
(`ui.ICON_FONT_DATA`), which `ui.widget_icons()` loads the first time a widget draws one: they stay right whatever the
program's icon font is.

## Only the icons a program uses

The whole font is 900 KB, and a program that loads `DATA` (the toolkit does, for a text field's menu and the command
palette) carries all of it. A program draws about 25 to 90 of its 1876 icons. Built with
`-define:LUCIDE_SUBSET=<absolute path>`, `DATA` is the font at that path instead (`#load` of the define); the constants
do not change, and one whose icon the font does not hold draws nothing.

`toolbox.lucide_subset(project)` writes that font at `build/lucide_subset.ttf` in the project (`LUCIDE_SUBSET_FILE`)
and returns its absolute path. It holds the icons named in the Odin sources of the program (`Project.src`) and of the
toolkit's `src` (the widgets' own): every `<alias>.NAME` of a file that imports the lucide package as `<alias>`
(`tk_lucide` without an alias), the names mapped to their characters through `src/lucide/lucide.odin`
(`toolbox.lucide_names_used(dirs)`, `toolbox.lucide_codes(source, names)`). An icon reached any other way (its
character written out, `""`) is not seen: name it by its constant. `toolbox.font_subset(data, codes)` makes the
font: the glyphs of the characters, `.notdef` and the parts of a composite glyph, the outlines and advances unchanged,
a new character map, no glyph names, no ligatures (GSUB).

A program's tool does both with `.Lucide_Subset` in `Project.features`: `build_native` writes the file, and
`odin_command` passes the define to every command but `check` once the file is there. whatsnew: 25 icons, 10 KB
instead of 917 KB.

## A program's own icons

A program needs no icon of the toolkit: any icon font it loads can be its icon font, and an icon is a character of it
(a string). The menus, `ui.icon` and `ui.icon_button` draw whatever `ui.State.icon_font` holds.

```odin
// the program's own font, beside its executable or embedded in it
ICONS :: #load("assets/my_icons.ttf")
MY_EXPORT :: "\ue001"   // its character in that font

icons, _ := font.load_embedded(&fonts, ICONS)
state.icon_font = icons
if ui.menu_item("Export…", icon = MY_EXPORT).clicked { ... }
```

The program's face is used for all of its icons; the widgets' marks stay in the toolkit's own face.
