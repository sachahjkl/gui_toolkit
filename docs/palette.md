# The command palette

One palette for every program: the same look, the same keys, the same prefixes. A program gives it **sources**; the
palette asks them, ranks their items together on a chore, shows them, and returns the choice. The design and its
reasons are in [src/md/features/palette.md](../src/md/features/palette.md).

```odin
App :: struct {
	palette:  ui.Command_Palette,
	settings: prefs_page.Palette_Settings,
	sessions: ui.Palette_Source,
	...
}

// once
ui.palette_memory_open(&app.palette, &app.ui, state_path("palette_choices.txt"))   // "": in memory only
prefs_page.palette_settings_add(&app.palette, &app.settings, &app.prefs, &app.page, page_options, open_settings, app)
app.sessions = {name = "session", title = "Sessions", prefix = .Go_To, plain = true, remember = true,
	enter = "Switch", read = sessions_read, user = app}
ui.palette_add(&app.palette, &app.sessions)

// each build, at its top
ui.palette_commands(&app.palette, COMMANDS[:], disabled[:])        // copies only on a change
if ui.command_pressed(ui.PALETTE_COMMAND) { ui.palette_toggle(&app.palette) }
if c, ok := ui.palette_chosen(&app.palette); ok {                 // the toolkit's sources act in it
	switch {
	case c.command >= 0:            run(Cmd(c.command))
	case c.source == &app.sessions: session_switch(app, c.id)
	}
}

// the sessions changed
app.sessions.version += 1

sessions_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	app := (^App)(src.user)
	items := make([]ui.Palette_Item, len(app.sessions_list), context.temp_allocator)
	for s, i in app.sessions_list { items[i] = {id = s.id, title = s.title, detail = s.folder, icon = lucide.MESSAGE_SQUARE} }
	ui.palette_answer(p, src, q.serial, items)   // at once, from memory; or later, from a chore's answer
}
```

## The prefixes

A prefix is the first character of the query, after leading spaces. The table is the toolkit's and is closed: a program
fills a prefix with a source, or leaves it empty. A character without a source is text (`/home/x` is a plain search in a
program without a Paths source).

| `Palette_Prefix` | Character | Meaning |
|---|---|---|
| `.None` | | the plain search: every source with `plain` |
| `.Commands` | `>` | what the program does: the commands, the views' moves |
| `.Go_To` | `@` | the things one opens or switches to: sessions, tabs, captures, processes |
| `.Paths` | `/` | files, folders and addresses |
| `.Choose` | `#` | one among alternatives, the one in use marked: models, agents, workflows |
| `.Settings` | `:` | the settings |
| `.Secrets` | `$` | entries of a vault: never plain, never remembered, no detail shown |

`palette_prefixes(&p) -> []string` lists the prefixes a palette has, with their names (`"> Commands"`, `"@ Sessions"`). A
program's test compares it with the list it means, as `command_typing_keys` for the keys.

## A source

| `Palette_Source` field | |
|---|---|
| `name` | stable, in English: the usage memory's key is `<name>:<id>` |
| `title` | in English, translated where it shows: the hint row's name, its "reading" row |
| `prefix`, `plain` | where its items are searched: under its prefix, and in the plain search when `plain` |
| `remember` | its choices go to the usage memory (Recent, and a bonus in the ranking) |
| `listed` | its items are listed when nothing is typed and no prefix is (the commands) |
| `searches` | it answers for the query: asked again at each one. Else it is asked once per `version` |
| `enter`, `alternates` | the words of Enter, Ctrl+Enter, Alt+Enter and Shift+Enter in the hint row ("Open in a new tab"); without an alternate, Enter with a modifier does what Enter does, and `Palette_Choice.mods` says which |
| `read(p, src, question)` | on the interface's thread, when it must answer: `palette_answer(p, src, question.serial, items)` at once from memory, or later from a chore's `done`. It makes no system call |
| `mark(src, id) -> bool` | the mark of an item now (a switch on, the model in use): called for the rows built only |
| `act(p, src, choice)` | what choosing does, run by `palette_chosen`; nil: the choice is returned to the program |
| `poll(p, src)` | at each build while the palette is open: a source that follows a state bumps its `version` there |
| `version` | the program bumps it when the items change |

| `Palette_Item` field | |
|---|---|
| `id` | stable in its source, never a title: the usage memory holds across languages |
| `title`, `detail`, `icon`, `keys`, `group` | the row: the title that the query lights, the detail (weak), an icon glyph of the state's `icon_font`, the keys' text; the group is the heading with nothing typed, said after the title while something is |
| `tags`, `last` | other words that find it; a last text that finds it when nothing else does (a setting's name) |
| `completion` | what Tab puts in the field (a folder's path, its prefix included) |
| `disabled` | greyed, listed last, never chosen |
| `stays` | choosing it does not close the palette (a switch) |

`palette_answer` copies the items: the caller frees its own after the call. An answer for another serial (an older
query, a former opening) is dropped and returns false. `palette_answer_error(p, src, serial, message)` says that the
source could not read: one weak row, "Sessions: could not read (message)". A source that has not answered yet shows
"Sessions: reading…" under its prefix, and "…" after the count in a plain search. The palette never waits for a source:
a source owns its timeout.

A searching source returns what it found, best first. The palette still scores each item with its matcher; an item that
the matcher does not find stays, after every match.

## The toolkit's sources

| Call | Source | Prefix | What choosing does |
|---|---|---|---|
| `palette_commands(&p, table, disabled, Palette_Commands_Options{names, keys, first, version, alternates})` | the commands; and beside them the views' moves of the window the palette is over | `>`, plain | a command: returned, `Palette_Choice.command` its index in the table. A move: the toolkit runs it |
| `prefs_page.palette_settings_add(&p, &settings, &prefs, &page, options, open, user)` | the settings the pages show | `:`, plain | a switch flips (`Page_Options.changed` is called) and the palette stays; another setting is put alone on its page (`prefs_page.show`) and `open(user)` shows the settings |

`Palette_Commands_Options`: `names`, each command's id (nil: its label as the table holds it); `keys`, each one's keys'
text as the program shows them (nil: its first chord); `first`, a command put first while something is typed (an alias
typed whole); `version`, the table's version (0: the palette keys on the table's address and compares `disabled`);
`alternates`, the words of Enter with a modifier.

## The rest of the API

| | |
|---|---|
| `palette_open(&p, typed = "")`, `palette_close(&p)`, `palette_toggle(&p, typed)`, `palette_is_open(&p)` | the palette's view over the window being built, at its top centre, resizable (the views remember its size); `typed` in its field (`"@"`: the sessions) |
| `PALETTE_COMMAND`, `palette_keys(&p) -> bool` | the toolkit's window command, Ctrl+K and Ctrl+Shift+P: no setting turns it off. `palette_keys` reads it and toggles |
| `palette_chosen(&p) -> (Palette_Choice, ok)` | call it at each build: it runs the choices of the sources that act, and returns the others once. `Palette_Choice{source, id, index, command, mods}` |
| `palette_add(&p, &src)`, `palette_remove(&p, &src)` | a source of the program's |
| `palette_memory_open(&p, s, path)` | the usage memory's file (`Command_Palette.memory`, a `Choice_Memory`), read on the chores; the palette notes each choice of a source with `remember` |
| `palette_row_count(&p)`, `palette_row(&p, i)`, `palette_selected(&p)`, `palette_busy(&p)` | what a test reads: the rows in view, the source and the id of one, a ranking or a read in flight |
| `palette_destroy(&p)` | before `ui.destroy` of its window |

`Command_Palette.asks`, `.rankings` and `.dropped` count the questions asked, the rankings started and the answers
dropped: a test reads them.

## Keys and look

- Up and Down move the selection and wrap; Page Up and Page Down move by the rows in view. The selection skips a
  disabled row. The pointer selects a row when it moves over it.
- Enter chooses. Enter typed in the same frame as the query waits for that query's ranking, then chooses its first row.
- Tab puts the selected item's completion in the field. Escape closes the palette.
- One row for every source: the icon, the title with what the query lit, the detail, the mark, the keys.
- With nothing typed: Recent (the heaviest choices among the items of the answers), then the commands under their
  groups, the disabled last in each. A prefix alone lists its sources' items. A palette of one source without a prefix
  is a chooser: no Recent, no hint row.
- The hint row at the foot: the prefixes, each with its name (a click types it), and the keys of the selected row.

## Threads

The interface's thread asks the sources and copies their answers (once per version). Every ranking runs on a chore,
for 10 items and for 100 000: a test counts the matches of this thread (`ui.rank_matched()`) and finds none. The list
shown stays until the next ranking comes, a frame later. An answer or a ranking for another serial is dropped. The
selection follows its item: a late answer that puts rows above it does not move it to another item.
