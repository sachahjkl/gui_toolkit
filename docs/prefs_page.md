# prefs_page: a settings page from the preferences

`import prefs_page "gt:prefs_page"` (the package is named `tk_prefs_page`). It builds a program's settings from its
preference registry ([config.md](config.md)), with no code per preference, in the look of opencode native's settings.

```odin
page: prefs_page.Page                         // kept between frames; prefs_page.destroy(&page) at the end

ui.next({width = ui.fill(), height = ui.fill()})
prefs_page.build(&page, &prefs, {
	user    = app,
	pages   = {{category = "appearance", title = "Appearance", icon = ICO_PALETTE}, {category = "history", title = "History", icon = ICO_HISTORY}},
	icon_font = app.icons, search_icon = ICO_SEARCH, reset_icon = ICO_RESET,
	changed = proc(user: rawptr, name: string) {   // a value was set or reset
		app := (^App)(user)
		config.save_user(&app.prefs, prefs_file())
		apply(app)
	},
	custom_names = {"look.theme"},
	custom  = proc(user: rawptr, name: string, em: f32) {   // the program's own control, under the words
		if at := prefs_page.theme_cards(themes, current, light, em); at >= 0 { /* set look.theme */ }
	},
})
```

## What it shows

- On the left: the search in a well, then the pages, each a button with its icon and its title; the page shown is
  pressed in. A page is a category of the registry (`Def.category`, or the first segment of the name). `Options.pages`
  gives their order, titles and icons (a page with no preference in the registry is not shown); without it, each category shows by name. A page narrower than 40 ems shows the
  icons alone. `Options.foot` is a faint line under the pages (where the file is).
- On the right: the page's title, then a line per preference, in the order the program registered them: its title
  (`config.title_of`) and its description (with "Locked by a policy", "Set on the command line for this run" or "Takes
  effect at the next start" when it applies) on the left, its control on the right, a reset button while the user's
  value is set, a carved line under it.
- While a search is typed (title, name or description: `config.matches`): what matches in every page, under each page's
  title.

The controls:

| Preference | Control |
|---|---|
| `Bool` | a switch |
| `String` with up to 4 choices (its own `choices`, or the program's `Options.choices`) | a segmented choice; under the words when it takes more than 45 % of the line |
| `String` with more choices | a list |
| `String` with no choices | a field |
| `Int` bounded with at most 200 steps, `Float` bounded | a slider (a round step: 0.1, 1, 10...), its unit after its value |
| other numbers, sizes in bytes | a field, its unit after it |
| a name in `Options.custom_names` | the program's own (`Options.custom`), under the words |

A locked preference (a policy, the command line) shows its control disabled.

## Changes

A value goes through `config.set_from_string` at the `User` layer: every observer of the registry runs. A field applies
its text on Enter or when it loses the keyboard; a refused value stays as it was, and the reason shows under the line
("out of range: 1 to 64 KB"). A slider applies its value when the drag ends, or at each key. `Options.changed` runs after
each value set or reset: save the file there (`config.save_user`) and apply the change.

## Themes as cards

`theme_cards(list, current, light, em)` draws the themes of `list` three to a row, each in its own colours (its version
`light`): its surface, its name in its text, its hues as dots, a ring of its accent around the one named `current`. It
returns the index of the one clicked, or -1.

## Keyboard

Tab goes through the search, the pages and the controls. `focus_search(&page)` gives the search the keyboard at the
next build (a program opens the page with it). `editing(&page)` says whether a field has the keyboard: a program that
closes the page on Escape leaves that Escape to the field.
