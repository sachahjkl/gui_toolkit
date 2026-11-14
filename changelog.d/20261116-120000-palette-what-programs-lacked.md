type: Changed

**The command palette gives what the first programs lacked** (docs/palette.md): the sheet of the keys lists the palette's command itself, the settings source reads its options when it needs them, one usage memory per file is shared by a program's windows and keeps a choice made just before quitting, a question can be ended from any thread, a list's selection version follows its active row, and the node graph's add palette is a source of the toolkit. Migration:
  - A table's line for the palette's command (Ctrl+K, Ctrl+Shift+P) → none: `ui.palette_keys` reads its keys and `ui.shortcuts_sheet_open` lists `ui.palette_command()` after the program's commands. A menu line reads `ui.palette_command()` at its build.
  - `prefs_page.palette_settings_add(&p, &s, &prefs, &page, options, open, user)` with `options: Page_Options` → `options: proc(user: rawptr) -> Page_Options`, asked when the source reads or acts; add it once (a second add does nothing). A change of the pages shown: `s.source.version += 1`.
  - `Command_Palette.memory: Choice_Memory` → `^Choice_Memory`, shared per file (`ui.choice_memory_acquire(s, path)`, `ui.choice_memory_release(m)`); `ui.palette_memory_open` is unchanged for a program. `ui.choice_memory_close` keeps a choice made before the file was read.
  - Ending a `Palette_Question` (`palette_answer`, `palette_answer_error`, `palette_question_drop`) is safe from any thread: off the palette's interface thread it is posted there (`palette_answer` then returns false). `ui.palette_answer_free(&a)` frees an answer never given, instead of `virtual.arena_destroy(&a.arena)`.
  - `Item_Selection.version` (a list's, a `Virtual_List`'s, a `Table`'s) also moves when the active row moves (Ctrl+arrows, a right click on a selected row, `list_select`).
  - `ui.flow_palette(g, cat, from) -> (commands, disabled)` → `ui.flow_palette(&palette, &fp, g, cat, from, version)`, a `ui.Flow_Palette` source (a chooser; `c.index` is the kind, `c.id` its name); `ui.flow_palette_items(g, cat, from, allocator)` gives its items.
  - `src.read == nil` to know whether a source is added → `ui.palette_has(&p, &src)`; `ui.palette_add` is idempotent.
  - `Palette_Question.prefix`: where the query was typed (`.None`: the plain search); a searching source is asked again when only the prefix changed.
  - `Palette_Choice.query`: the query the item was chosen for, without its prefix (reading the field after the close goes).
  - `p.ranked.valid` and `p.ranked.text` in a test → `ui.palette_ranked_for(&p, text)`.
