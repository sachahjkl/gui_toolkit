# lucide: the Lucide icons

`import lucide "gt:lucide"` (the package is named `tk_lucide`). The [Lucide](https://lucide.dev) icons as a font (ISC
licence, `src/lucide/LICENSE.txt`): `DATA` is the face, and each constant is the character of one icon in it, named as
Lucide names it.

```odin
icons, _ := font.load_embedded(&fonts, lucide.DATA)
draw.text(dc, icons, size, pos, color, lucide.SEARCH)
```

The `prefs_page` icons of the pages (`Page_Info.icon`), the buttons of a toolbar, a menu's icons: any text drawn in that
face. One set for every program of the toolkit. When a program needs an icon that has no constant yet, add it to
`src/lucide/lucide.odin`: its code point is in the font's character map, under the icon's name.
