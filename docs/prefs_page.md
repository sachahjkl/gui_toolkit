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
		// the loop saves: config.user_writer_save, once per round
		apply(app)
	},
	themes = app.themes, themes_light = app.theme_shown.light,   // appearance.theme as cards
	custom_names = {"look.font"},
	custom  = proc(user: rawptr, name: string, em: f32) {   // the program's own control, under the words
		/* a font picker */
	},
})
```

## The standard settings

Every program has the same look and the same place on the desktop. `standard_register` registers those preferences,
with their titles, descriptions, choices, bounds and search tags; the page then draws them with no code of the program's.

```odin
d := prefs_page.STANDARD_DEFAULTS   // system, machined, 14 px, in the menu, not started with the session
d.theme, d.app_name = "cliche", "cliche"
prefs_page.standard_register(&prefs, {.Appearance, .Session}, d)
config.register(&prefs, PREF_DEFS[:])   // the program's own, after them

a := prefs_page.appearance_read(&prefs)   // what to apply; again after each change
defer prefs_page.appearance_free(&a)
ui.theme_show(&theme, themes, prefs_page.appearance_choice(a), &shown, space)
```

| Set | Preference | Control |
|---|---|---|
| `Appearance` (page `appearance`) | `appearance.theme` | the themes' cards when `Options.themes` is set |
| | `appearance.mode`: `system`, `dark`, `light` | a segmented choice |
| | `appearance.finish`: `machined`, `edged`, `flat`, `gradient`, `glass` | a segmented choice, or a list |
| | `appearance.font_size`: 10 to 24 px | a slider |
| `Session` (page `general`) | `general.menu`: in the application menu | a switch |
| | `general.autostart`: start with the session | a switch |
| | `general.messages`: where the program says what it did (System, Window, Off; read by `messages_mode` for ui.announce) | a choice |

Start from `STANDARD_DEFAULTS`: a zero `Standard_Defaults` has `menu` off. `app_name` goes in the descriptions ("Start
cliche with the session"); those texts are made in the `allocator` argument and must live as long as the registry. The
names are fixed: the programs' files hold them. A program applies `general.menu` and `general.autostart` on a worker
with `desktop.apply` ([desktop.md](desktop.md)).

`appearance_read` reads a preference that is not registered as its standard default.

## What it shows

- On the left: the search in a well, then the pages, each a button with its icon and its title; the page shown is
  pressed in. A page is a category of the registry (`Def.category`, or the first segment of the name). `Options.pages`
  gives their order, titles and icons (a page with no preference in the registry is not shown); without it, each category shows by name. A page narrower than 40 ems shows the
  icons alone. `Options.foot` is a faint line under the pages (where the file is).
- On the right: the page's title, then a line per preference, in the order the program registered them: its title
  (`config.title_of`) and its description (with "Locked by a policy", "Set on the command line for this run" or "Takes
  effect at the next start" when it applies) on the left, its control on the right, a reset button while the user's
  value differs from the default, a carved line under it.
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
| a name in `Options.hotkeys` (a key combination as text) | a field that records the keys pressed (`ui.hotkey_field`): a click, then the keys |
| a `pref` of `Options.shortcut_prefs` | the same field, and what the system made of the keys under it (see below) |
| `appearance.theme`, with `Options.themes` | the themes' cards, under the words |

`Options.version` ("Papier 0.15.0") shows the program and its version at the bottom of the pages, above `foot`.

A locked preference (a policy, the command line) shows its control disabled. `Options.problem(user, name)` gives what
the program has to say under a line (a shortcut another program holds): it shows in red. `Options.status(user, name)` says a
preference's state plainly, under its line, in the weak text (the keys a shortcut got). `Options.page_foot(user,
category, em)` draws the program's own content under a page's preferences (not in a search): buttons, a list.

Each line whose value is the user's and differs from its default shows the reset button, whatever its control:
`differs_from_default(prefs, name, keys)` says when (`keys`: compared as key combinations, so "ctrl+print" is
"Ctrl+Print"). A value the user set equal to the default shows none. While one line of the page shown has it, a
**Restore defaults** button beside the page's title puts all of them back (each through `Options.changed`, as its own
reset button does).

## Global shortcuts

A program with global shortcuts ([shortcuts.md](shortcuts.md)) gives its service in `Options.shortcuts` and, in
`Options.shortcut_prefs`, each preference that holds a shortcut's keys with the shortcut's id in the service:

```odin
SHORTCUTS := [?]prefs_page.Shortcut_Pref{{pref = "shortcut.region", id = "region"}, {pref = "shortcut.screen", id = "screen"}}
opts.shortcuts, opts.shortcut_prefs = app.shortcuts, SHORTCUTS[:]
```

Each line records keys. Under it, in the weak text, `shortcuts.status_text` ("Works in every program: Ctrl+Print.", "The
system gave other keys…", "Waiting for the system's answer…"); in red, `shortcuts.problem_text` ("Another program holds
Ctrl+Print: choose other keys.", "The system refused this shortcut.", keys that do not parse). While a field records
keys, the page holds the service (`shortcuts.hold`): Windows would take the very keys being recorded. The program's
`status` and `problem` run for its other preferences.

## Themes from the program

With `Options.themes` (the program's list: its own theme, then `ui.THEMES`), `appearance.theme` shows as the themes'
cards and a click sets it. The cards show the version `appearance.mode` asks; for `system`, the one the program shows
now (`Options.themes_light`: its `ui.Theme_Shown.light`; the page does not ask the system each frame).

A program that updates itself (`update.Updater`, `docs/update.md`) gives it in `Options.updater`, and in `update_pref` the
preference whose line shows it (its own switch, "update.auto"). Under that line: the state in words (`update.status_words`:
up to date, a version available, downloading, installed, the last check's failure, or that a package manager updates this
copy), a **Check now** button, **Install <version>** when one is on offer, and **Restart now** when one is installed and the
program gives `Options.restart`.

## Changes

A value goes through `config.set_from_string` at the `User` layer: every observer of the registry runs. A field applies
its text on Enter or when it loses the keyboard; a refused value stays as it was, and the reason shows under the line
("out of range: 1 to 64 KB"). A slider applies its value when the drag ends, or at each key; while it is held,
`Options.preview(user, name, value)` gets each value it moves to, for the program to show at once (a rounding, a size)
without writing it. `Options.changed` runs after
each value set or reset: apply the change from there; the loop's `config.user_writer_save` writes the file off the loop.

## Themes as cards

`theme_cards(list, current, light, em)` draws the themes of `list` three to a row, each in its own colours (its version
`light`): its surface, its name in its text, its hues as dots, a ring of its accent around the one named `current`. It
returns the index of the one clicked, or -1.

## The settings in place of the main view

A program with one window shows its settings in place of its main view (papier: in place of the history):

```odin
// the state: settings_open: bool, page: prefs_page.Page
open_settings :: proc(app: ^App) {   // the gear button, Ctrl+,
	app.settings_open = true
	prefs_page.focus_search(&app.page)
}

// in the build
if app.settings_open {
	o := settings_options(app)
	if !dialog_open && prefs_page.escape_leaves(&app.page) { app.settings_open = false }
	if prefs_page.back_bar(&app.page, o, "Settings", "Back to the history (Escape)", em) { app.settings_open = false }
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&app.page, &app.prefs, o)
} else {
	build_main_view(app)
}
```

`back_bar(page, options, title, back_tip, em)` is a bar as wide as its parent: a back arrow (Lucide's `arrow-left` in
`Options.icon_font`, else the word "Back") whose tooltip is `back_tip`, then the title. It returns true when the arrow
was pressed. `escape_leaves(page)` is true when Escape was pressed and no editor of a preference has the keyboard: that
Escape gives up the editor first.

## Keyboard

Tab goes through the search, the pages and the controls. `focus_search(&page)` gives the search the keyboard at the
next build (a program opens the page with it). `editing(&page)` says whether a field has the keyboard: a program that
closes the page on Escape leaves that Escape to the field.

## The settings in the command palette

`palette_commands(prefs, options)` gives one `ui.Command` per preference the pages show (a hidden one is not): its label
is the title the page gives it, its group `Settings · <page>`, its icon the page's (else Lucide's sliders), its tags the
preference's (`config.Def.tags`: other words the settings' search and the palette find it by, "colours" and "dark" for a
theme). A program puts
them after its own commands in `ui.palette`; when one is chosen, it opens its settings and calls `show(page, prefs,
options, name)`: the page's search holds the preference's name in quotes, so it shows alone with its control, and the
page under the search is its own (clearing the search lands there).

```odin
settings, names := prefs_page.palette_commands(&app.prefs, opts)
all := slice.concatenate([][]ui.Command{app_commands, settings}, context.temp_allocator)
if i, _ := ui.palette(&app.palette, all, enabled); i >= len(app_commands) {
    app.settings_open = true
    prefs_page.show(&app.page, &app.prefs, opts, names[i - len(app_commands)])
}
```

## The update in the status bar

`update_badge(updater, restart, user)` is a button for a program's status bar: "Install 0.16.0" when a version is on
offer, "Downloading 0.16.0…" while it comes, "Restart to update to 0.16.0" once it is in place (`restart(user)`: the
program starts again). It builds nothing when there is nothing to do, and returns whether it built something.
