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
| `enter`, `alternates` | the words of Enter, Ctrl+Enter, Alt+Enter and Shift+Enter in the hint row ("Open in a new tab"); without an alternate, Enter with a modifier does what Enter does, and `Palette_Choice.mods` says which |
| `read(p, src, question)` | on the interface's thread, when it must answer. It ends the question, at once or later. It makes no system call |
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
| `disabled` | greyed, listed last, never chosen, never put first |
| `stays` | choosing it does not close the palette (a switch) |

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
| `palette_commands(&p, table, disabled, Palette_Commands_Options{names, keys, first, version, alternates})` | the commands; and beside them the views' moves of the window the palette is over | `>`, plain | a command: returned, `palette_chosen_command(&p, c)` its index in the table. A move: the toolkit runs it |
| `prefs_page.palette_settings_add(&p, &settings, &prefs, &page, options, open, user)`, once | the settings the pages show; `options(user) -> Page_Options` is asked each time the source reads or acts (the themes' slice as it is then); a change of the pages bumps `settings.source.version` | `:`, plain | a switch flips (`Page_Options.changed` is called) and the palette stays; another setting is put alone on its page (`prefs_page.show`) and `open(user)` shows the settings |
| `flow_palette(&p, &fp, g, cat, from, version)`, at each build | a node graph's add palette, `Flow_Palette`: one item per kind of the catalog (a kind at its max_count, or with no port that fits `from`, disabled). A chooser: no prefix. `flow_palette_items(g, cat, from, allocator)` gives its items (a test) | none | returned: `c.index` the kind, `c.id` its name |

`Palette_Commands_Options`: `names`, each command's id (nil: its label as the table holds it); `keys`, each one's keys'
text as the program shows them (nil: its first chord); `first`, a command put first while something is typed (an alias
typed whole; not when it is disabled); `version`, the version of the table and of `disabled` (0: neither changes in
place, the palette compares their addresses; it never reads `disabled` at a frame); `alternates`, the words of Enter
with a modifier. A `disabled` that follows a list's selection takes the selection's `version` (`Item_Selection.version`:
it moves when a row is selected or no longer, one row for another at the same count, and the active row moves).

## The rest of the API

| | |
|---|---|
| `palette_open(&p, typed = "")`, `palette_close(&p)`, `palette_toggle(&p, typed)`, `palette_is_open(&p)` | the palette's view over the window being built, at its top centre, resizable (the views remember its size); `typed` in its field (`"@"`: the sessions), also when it is open already. `palette_toggle`: a button or a menu line |
| `palette_command() -> Command`, `palette_keys(&p) -> bool` | the toolkit's window command, Ctrl+K and Ctrl+Shift+P (its keys read only). The toolkit owns it whole: `palette_keys` reads its keys, the sheet of the keys lists it, so a program's table has no line for it. A program's menu line reads it at its build (`c := ui.palette_command()`). No setting turns it off |
| `palette_chosen(&p) -> (Palette_Choice, ok)` | call it at each build: it runs the choices of the sources that act, returns the others once, and follows a close the palette did not make (Escape, a click outside). `Palette_Choice{source, id, index, mods, query}`: `query` is the query it was chosen for, without its prefix (an alias typed) |
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
- Enter chooses. While a ranking is in flight (the query typed in the same frame, a late answer), Enter waits for it:
  then it chooses the row the person moved to, kept on its item, else the first row that acts.
- Tab puts the selected item's completion in the field. Escape closes the palette.
- One row for every source: the icon, the title with what the query lit, the detail, the mark, the keys.
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
