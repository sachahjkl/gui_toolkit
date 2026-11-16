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
ui.palette_memory_open(&app.palette, &app.ui, state_path("palette_choices.txt"))   // shared by the windows; "": in memory
prefs_page.palette_settings_add(&app.palette, &app.settings, &app.prefs, &app.page, page_options, open_settings, app)
if !ui.palette_has(&app.palette, &app.sessions) {
	app.sessions = {name = "session", title = "Sessions", prefix = .Go_To, plain = true, remember = true,
		enter = "Switch", read = sessions_read, user = app}
	ui.palette_add(&app.palette, &app.sessions)   // (a second add does nothing)
}

// each build, at its top
ui.palette_commands(&app.palette, COMMANDS[:], disabled[:], {version = app.can_version})   // compares the version only
ui.palette_keys(&app.palette)                                    // Ctrl+K, Ctrl+Shift+P: the one reader of its keys
if c, ok := ui.palette_chosen(&app.palette); ok {                // the toolkit's sources act in it
	if i, is := ui.palette_chosen_command(&app.palette, c); is {
		run(Cmd(i))
	} else if c.source == &app.sessions {
		session_switch(app, c.id)
	}
}

// the sessions changed
app.sessions.version += 1

// an answer made at once, in its own arena: the palette takes it without a copy
sessions_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	app := (^App)(src.user)
	a: ui.Palette_Answer
	al := ui.palette_answer_allocator(&a)
	a.items = make([]ui.Palette_Item, len(app.sessions_list), al)
	for s, i in app.sessions_list {
		a.items[i] = ui.palette_item_clone({id = s.id, title = s.title, detail = s.folder, icon = lucide.MESSAGE_SQUARE}, al)
	}
	ui.palette_answer(q, &a)
}
```

An answer made later keeps the question (a copy of its `query` if it needs it), builds a `^Palette_Answer` on its
chore, and ends the question from there or from its `done`: an end made on another thread (a chore, a task's `lost`,
a worker) is posted to the palette's interface thread. A source that built an answer and does not give it frees it
with `palette_answer_free`.

## The prefixes

A prefix is the first character of the query, after leading spaces. The table is the toolkit's and is closed: a program
fills a prefix with a source, or leaves it empty. A character without a source is text (`/home/x` is a plain search in a
program without a Paths source).

| `Palette_Prefix` | Character | Meaning |
|---|---|---|
| `.None` | | the plain search: every source with `plain`, and every source without a prefix (a chooser's) |
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
| `prefix`, `plain` | where its items are searched: under its prefix, and in the plain search when `plain`. Without a prefix: the plain search only |
| `remember` | its choices go to the usage memory (Recent, and a bonus in the ranking) |
| `listed` | its items are listed when nothing is typed and no prefix is (the commands) |
| `searches` | it answers for the query: asked again at each one. Else it is asked once per `version` |
| `enter`, `alternates` | the words of Enter, Ctrl+Enter and Alt+Enter in the hint row ("Open in a new tab"); without an alternate, Enter with a modifier does what Enter does, and `Palette_Choice.mods` says which. Shift+Enter is go to in every source (below) |
| `read(p, src, question)` | on the interface's thread, when it must answer. It ends the question, at once or later. It makes no system call |
| `mark(src, id) -> bool` | the mark of an item now (a switch on, the model in use): called for the rows built only |
| `value(src, id) -> string` | the value an item has now, at its row's right ("Nord", "300 ms"): called for the rows built only |
| `reach(p, src, id, go) -> bool` | whether item `id`'s act name can be shown though no frame shows it (the settings, closed); with `go`, shows its place. nil: only what a frame shows is reached |
| `runner` | the run mode of its items that run (`Palette_Item.runs`): a `^Palette_Runner` (below) |
| `act(p, src, choice)` | what choosing does, run by `palette_chosen`; nil: the choice is returned to the program |
| `poll(p, src)` | at each build while the palette is open: a source that follows a state bumps its `version` there |
| `version` | the program bumps it when the items change |

| `Palette_Item` field | |
|---|---|
| `id` | stable in its source, never a title: the usage memory holds across languages |
| `title`, `detail`, `icon`, `keys`, `group` | the row: the title that the query lights, the detail (weak), an icon glyph of the state's `icon_font`, the keys' text; the group is the heading with nothing typed, said after the title while something is |
| `tags`, `last` | other words that find it; a last text that finds it when nothing else does (a setting's name) |
| `completion` | what Tab puts in the field (a folder's path, its prefix included) |
| `disabled` | greyed, listed last, never chosen, never put first |
| `stays` | choosing it does not close the palette (a switch) |
| `act` | the act name of what it acts on (`setting:appearance.theme`, `command:save`): Shift+Enter goes there |
| `runs` | Enter opens its run mode (its source's `runner`): its control under its row, or a command's form |

### Questions and answers

| | |
|---|---|
| `Palette_Question{link, source, serial, prefix, query}` | a counted handle on the palette. The source ends each question exactly once, from any thread. `prefix`: where the query was typed (`.None`: the plain search; a source in two places tells them apart, and is asked again in the other place for the same query). `query`, after the prefix, is valid during `read` |
| `Palette_Answer{arena, items}`, `palette_answer_allocator(&a)` | the source's answer: its items and their strings in its own arena (or constants) |
| `palette_item_clone(item, allocator)` | an item with its strings copied in an answer's arena |
| `palette_answer(q, &a) -> bool` | ends `q`: the palette takes `a` whole, no copy (it is zero after). On the interface's thread: true when kept (the source's question in flight), else dropped and freed. On another thread: posted there, false |
| `palette_answer_error(q, message) -> bool` | ends `q`: the source could not read. One weak row, "Sessions: could not read (message)" |
| `palette_question_drop(q)` | ends `q` without an answer (a source that gives it up): the source is asked again at a next build |
| `palette_answer_free(&a)` | frees an answer never given to `palette_answer` |

An end on another thread than the palette's goes to its window's posts (its Task_Box). After `palette_destroy`, an end
finds no palette and only lets go of the handle and frees the answer. A window gone refuses the post: the end lets go
of the handle and frees the answer on the thread that made it. A source that has not answered yet
shows "Sessions: reading…" under its prefix, and "…" after the count in a plain search. The palette never waits for a
source: a source owns its timeout.

A searching source returns what it found, best first. The palette still scores each item with its matcher; an item that
the matcher does not find stays, after every match.

## The toolkit's sources

| Call | Source | Prefix | What choosing does |
|---|---|---|---|
| `palette_commands(&p, table, disabled, Palette_Commands_Options{version, choices, details, checked, user})` | the commands; and beside them the views' moves of the window the palette is over | `>`, plain | a command: returned, `palette_chosen_command(&p, c)` its index in the table; a command with arguments opens its form first, and the choice holds their values (`c.arguments`); with Ctrl or Alt, the toolkit sets a key or an alias (below). A move: the toolkit runs it |
| `prefs_page.palette_settings_add(&p, &settings, &prefs, &page, options, open, user)`, once | the settings the pages show, each with its value in use at its right; `options(user) -> Page_Options` is asked each time the source reads or acts (the themes' slice as it is then); a change of the pages bumps `settings.source.version`. It installs the commands' forms too | `:`, plain | a switch flips (`Page_Options.changed` is called) and the palette stays; another setting opens its run mode (below). A setting the policy or the command line fixes is disabled, its reason its detail |
| `flow_palette(&p, &fp, g, cat, from, version)`, at each build | a node graph's add palette, `Flow_Palette`: one item per kind of the catalog (a kind at its max_count, or with no port that fits `from`, disabled). A chooser: no prefix. `flow_palette_items(g, cat, from, allocator)` gives its items (a test) | none | returned: `c.index` the kind, `c.id` its name |

A command's item id is its `Command.id`, the usage memory's key (`command:<id>`); the keys on its row are its first key
in effect (the person's, [commands.md](commands.md)); the person's aliases of it are among its tags.
`Palette_Commands_Options`: `version`, the version of the table and of `disabled` (0: neither changes in place, the
palette compares their addresses; it never reads `disabled` at a frame; a change of the keymap needs none: the source
follows its version); `choices(user, index, argument) -> (labels, values)`, the values a String argument of command
`index` without its own choices may take (a closed list the program fills: the models), read when its form opens; `details`,
each command's detail ("Session · Fix the build": what it acts on), shown weak after its
title and not searched (a detail that many commands share would find them all), part of `version`; `checked(user,
index)` and `user`, whether a toggle command is on now. A command with `Command.toggle` is a switch: its row shows its
mark (`checked`, read for the rows built only, at each build: a flip ranks nothing again) and choosing it leaves the
palette open; the choice is returned to the program, which flips it. Its menu line is the same command:
`menu_item(c.label, ui.command_shortcut(c), checked = on)`. A `disabled` that follows a list's selection takes the selection's `version` (`Item_Selection.version`:
it moves when a row is selected or no longer, one row for another at the same count, and the active row moves).

While the window reads a keymap (`ui.keymap_use`), Ctrl+Enter and Alt+Enter on a command are the toolkit's in every
program, and the program does not see these choices:

- **Ctrl+Enter, "Set a key"**: the palette closes and the recorder (`KEYMAP_RECORDER_VIEW`) takes any chord, two for a
  sequence; Enter keeps them, Escape gives up, Backspace first gives the command its own keys again. Then the palette
  opens again with its text.
- **Alt+Enter, "Make the letters its alias"**: the query, trimmed and in lower case, becomes an alias of the command;
  the palette opens again with its text.
- **An alias typed whole puts its command first**, under `>` and in the plain search (not a disabled one).

## The run mode: a value changed in the palette

Enter on an item that runs (`Palette_Item.runs`: a setting that is no switch, a command with arguments) unfolds its
control under its row; the other rows step aside, the palette keeps its height. The control comes from the value, in
the settings page's table (`prefs_page.control_of`):

| The value | In the run mode |
|---|---|
| a closed list (any length), a family, a theme, a command's Bool | a sub-list the field filters, the value in use marked; a family drawn in its face, a theme with its hues |
| a colour | the colour picker; the field is its text |
| keys | the field is their text; the recorder under it |
| a bounded number | the field is its text with its unit; Up and Down step it; its slider (written when let go) |
| the rest (a path, an address, a size, a text) | the field is its text |

- The field keeps the keyboard: its text is the control's filter or the value's text. A filter typed selects the best
  row; Up, Down, Page Up, Page Down and a click move and write at once. A value typed is written at Enter; a value
  refused stays, its reason under the row.
- **Enter keeps** and goes back to the list (a form: the next argument; on the last, the choice). **Escape puts back
  the value of before** and goes back (a form: the argument before; on the first, the list). A value another path
  wrote since the run mode's last write is left. A close the palette did not ask (a click outside, Ctrl+K) is Escape at
  each level.
- Every write is made in `palette_chosen`, at the top of the next build: call it before the program's content, so the
  page shows a value in the same frame as the palette.
- `Command.arguments: []config.Def`: what a command takes, each a value as a setting is. Its form shows each argument
  with its control; the values come with the choice, `Palette_Choice.arguments`, as the settings file writes them
  (`"Harbour at dusk"`, `"webp"`, `"4194304"`).
- `prefs_page.palette_forms_use(&p)`: the forms runner, for a program without the settings source (palette_settings_add
  installs it). Without it, a command with arguments is chosen without them.

| | |
|---|---|
| `Palette_Runner{open, text, build, write, undo, values, close, user}` | what runs a source's run mode: prefs_page's two (a setting's, the forms'). `open` notes what Escape puts back and says the steps (0: none); `text` the field's text at a step and whether it is the value's; `build` the control (a value to write, made by `palette_chosen`); `write` from text ("" or why not); `undo`; a form's `values`; `close` |
| `palette_run_level(&p) -> Palette_Run_Level` | `.Closed`, `.Control` (a value), `.Form` (a command's arguments) |
| `palette_run_item(&p) -> (src, id, arg, ok)` | the item the run mode is open on, and the argument shown |
| `palette_run_error(&p) -> string` | why its last write was refused ("": it was not) |
| `palette_sublist(id, &st, count, step, height, row, user) -> (moved, clicked)` | the run mode's list of choices: rows of one height, only those in view built, `step` moving the selection (`Palette_Sublist{sel, reveal}`), `row(user, i, selected)` filling each row |
| `palette_command_arguments(&p, id) -> (index, arguments)`, `palette_command_choices(&p, index, argument) -> (labels, values)` | what a forms runner reads of the commands source |
| `Palette_Run_Keys{step, page, enter, tab}`, `palette_run_set_text(&p, text)` | the keys `build` is given, read before the field (Tab: complete); a control puts a text in the field, the caret at its end, as typed (a path completed: prefs_page's) |

A `Path` value completes in the run mode: the entries of the folder typed, read on a chore, that start with its last
part, folders first; Tab puts the one selected in the field, Enter keeps the text.

## Go to: Shift+Enter

Shift+Enter on an item goes where it lives: the palette closes, the view that shows its act name comes forward, the
element is scrolled into view, gets the focus and is lit once. An item whose place cannot be shown offers no go to (its
hint row does not say it), and Shift+Enter there does what Enter does.

- An element states its act name at its build: `ui.act_name(box, "setting:appearance.theme")`. The settings page names
  each setting's line; a toolbar's tool of a command names it itself (`"command:<id>"`): the commands source's items
  carry it. A program's own button of a command calls `ui.act_command(box, command.id)` at its build.
- `ui.act_shown(name)`: whether a window of the program showed it in its last frame. `ui.act_go(name)`: goes there, now
  or within `ACT_GO_BUILDS` builds when it shows (`ACT_LIGHT_MS`: the light, a ring `ACT_LIGHT_OUTSET` ems outside the
  element, so it never touches its words).
- A source reaches what no frame shows with `reach`: the settings source shows the setting's page (its search cleared,
  its Advanced part unfolded for an advanced one) and calls `open`.

## The rest of the API

| | |
|---|---|
| `palette_open(&p, typed = "")`, `palette_close(&p)`, `palette_toggle(&p, typed)`, `palette_is_open(&p)` | the palette's view over the window being built, at its top centre, resizable (the views remember its size); `typed` in its field (`"@"`: the sessions), also when it is open already. Open over another window, it moves to this one, fresh. `palette_toggle`: a button or a menu line; it closes the palette only when it is open over this window |
| `palette_command() -> Command`, `palette_keys(&p) -> bool` | the toolkit's window command, Ctrl+K and Ctrl+Shift+P (its keys read only). The toolkit owns it whole: `palette_keys` reads its keys, the sheet of the keys lists it, so a program's table has no line for it. A program's menu line reads it at its build (`c := ui.palette_command()`). No setting turns it off. Call `palette_keys` in the build of the window that owns the views (with `ui.set_views` on it): the windows of its views read the same keys for the same palette, which opens over the window they are pressed in. A choice made there comes out of `palette_chosen` in the program's build, as any choice; the recorder of a key and the palette after it show in the window the palette was over |
| `palette_chosen(&p) -> (Palette_Choice, ok)` | call it at each build, before the program's content: it runs the choices of the sources that act, a command's Ctrl+Enter and Alt+Enter and Shift+Enter's go to, makes the run mode's writes, opens the palette again when the recorder ended, returns the other choices once, and follows a close the palette did not make (Escape, a click outside). `Palette_Choice{source, id, index, mods, query, arguments}`: `query` is the query it was chosen for, without its prefix; `arguments`, a command's values from its form |
| `palette_chosen_command(&p, c) -> (index, ok)` | the index in the commands table of a choice of the commands source |
| `palette_add(&p, &src)`, `palette_has(&p, &src)`, `palette_remove(&p, &src)` | a source of the program's: added (a second add does nothing), added or not, removed. A removal drops its answer, its question and the ranking in flight |
| `palette_memory_open(&p, s, path)` | the usage memory's file (`Command_Palette.memory`), read on the chores. One memory per file for the process (`choice_memory_acquire`): the palettes of a program's windows that give one path share it, and the file holds every window's choices. The palette notes each choice of a source with `remember`; the last palette to go writes it. A choice made before the file was read is not lost at a quick quit |
| `palette_row_count(&p)`, `palette_row(&p, i)`, `palette_selected(&p)`, `palette_busy(&p)`, `palette_ranked_for(&p, text)` | what a test reads: the rows in view, the source and the id of one, a ranking or a read in flight, whether the list shown was ranked for the field's text `text` (none in flight) |
| `palette_destroy(&p)` | before `ui.destroy` of its window |

`Command_Palette.asks`, `.rankings` and `.dropped` count the questions asked, the rankings started and the answers and
rankings dropped: a test reads them.

## Keys and look

- Up and Down move the selection and wrap; Page Up and Page Down move by the rows in view. The selection skips a
  disabled row, and starts on the first row that acts. The pointer selects a row when it moves over it.
- Enter chooses (an item that runs: its run mode). While a ranking is in flight (the query typed in the same frame, a
  late answer), Enter waits for it: then it chooses the row the person moved to, kept on its item, else the first row
  that acts. Shift+Enter goes to it.
- Tab puts the selected item's completion in the field. Escape closes the palette (in the run mode: one step back).
- One row for every source: the icon, the title with what the query lit, the detail, the value, the mark, the keys.
- With nothing typed: Recent (the heaviest choices among the items of the answers), then the commands under their
  groups, the disabled last in each. A prefix alone lists its sources' items. A palette of one source without a prefix
  is a chooser: no Recent, no hint row.
- The hint row at the foot: the prefixes, each with its name (a click types it), and the keys of the selected row.

## Threads

The interface's thread asks the sources and keeps their answers (once per version, without a copy). Every ranking runs
on a chore, for 10 items and for 100 000: a test counts the matches of this thread (`ui.rank_matched()`) and finds none.
A ranking that a newer one replaced stops at its next chunk (`PALETTE_RANK_CHUNK` items). The list shown stays until
the next ranking comes, a frame later. An answer or a ranking for another serial is dropped. The selection follows its
item: a late answer that puts rows above it does not move it to another item.
