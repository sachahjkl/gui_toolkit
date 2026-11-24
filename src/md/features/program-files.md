# A program's standard files and its preferences' start

Every program keeps the same files: its preferences (`prefs`) and its own themes (`themes.txt`) in its config folder;
the views' memory (`views.txt`), the palette's memory (`palette_choices.txt`) and the file dialogs' memory
(`file_dialogs.txt`) in its state folder. Six programs wrote these paths, and the same start of the preferences:
register the toolkit's standard preferences, the program's own, the What's new version, read the file, apply the
command line's `--pref`.

## The parts

- `prefs_page.Program_Files`: the paths, made once by `program_files(folder, memory)`.
- `prefs_page.prefs_open(p, files, sets, defaults, defs, args, descriptions)`: the start of the registry.

## Decisions

- **A value with every path, made once at the start.** A program gives `files.views` to `ui.views_init`,
  `files.palette_choices` to its palette, and so on. Before, each path was a procedure that read the user folder again
  at each call.
- **`memory = true` gives empty paths.** An empty path is "in memory only" everywhere in the toolkit: `ui.views_init`,
  the palette's memory, `themes_file_init`, `config.user_writer_start`. A test sets `memory`, and nothing on disk is
  read or written.
- **A test may still give one path.** classeur's tests keep their preferences beside their session file
  (`<session>.prefs`). The test sets `files.prefs` after `program_files(..., memory = true)`: `prefs_open` reads
  the file that `files.prefs` names, whatever made it. opencode native's tests give no preferences' file: that is
  `memory = true` with nothing changed.
- **The state folder holds the views.** opencode native kept `views.txt` beside its preferences. The views are memory,
  not a choice of the person: they go in the state folder, as in the other programs. No migration (before 1.0).
- **The sets and the defaults are arguments.** classeur adds `.Rows` to `STANDARD_ALL`; each program has its own
  defaults (its theme, its name). `prefs_open` takes them, as `standard_register` does.
- **What's new is always registered.** One hidden preference costs nothing in a program that shows no What's new.
- **What the program changes after the start stays its own.** classeur hides `window.system_title` where the system draws
  no title bar; `config.ref_of` reaches the entry after `prefs_open`.
- **The problems of the file come first, then those of the command line.** That is the order they happen in.

## Subtle points

- `program_files` asks the user folders (`platform.user_dir`): it reads the environment only. `prefs_open` reads a
  file: call it at the start, before the window's loop, as before.
- `program_files_destroy` frees the paths with the allocator that made them.
