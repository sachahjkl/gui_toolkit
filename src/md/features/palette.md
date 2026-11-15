# The command palette: intent

One palette for every program: the same look, the same keys, the same prefixes. The palette is `ui.Command_Palette`
(`src/ui/palette.odin`), its commands and moves sources are in `src/ui/palette_sources.odin`, its settings source in
`src/prefs_page/palette.odin`. It ranks with `ui.rank` (`src/ui/rank.odin`) and remembers with `ui.Choice_Memory`
(`src/ui/choices.odin`). The API is in [docs/palette.md](../../../docs/palette.md). The keys of a command and the
window commands are in [commands.md](commands.md). The views' moves are in [views.md](views.md).

## The problem

The programs have three palettes. They diverged.

- **The toolkit's palette** lists one table of `ui.Command`. Papier, classeur, inspecteur and cliche each concatenate
  three tables into it: their commands, the settings (`prefs_page.palette_commands`) and the views' moves
  (`ui.View_Commands`). Then each program decodes the chosen index by ranges: `i < len(Action)`, then the settings,
  then the moves. Four copies of the same code. Each copy breaks when the table is made again between the choice and
  its reading.
- **opencode native's palette** (`ocn/src/palette.odin`) has its own items, its own row, its own stamp and five
  prefixes: `>` commands, `@` sessions and agents, `/` the server's commands, `#` models, `:` settings.
- **Wren's palette** (`wren/src/browser/palette.odin`, 800 lines) has its own sources and prefixes: `>` commands,
  `@` tabs, `:` preferences, `/` pages, `$` the vault. It also has nine settings of its own.

The same character means different things: `/` is a server command in opencode native and a page in Wren; `@` is a
session or an agent in one and a tab in the other. A fix in one palette (the lit ranges, a stale list, the selection
under the pointer) is not in the others. A person who uses two programs learns two palettes.

The state machines behind the three palettes are the same: "what is typed selects what is asked", "an answer is for
the query it was asked for", "what was chosen before comes first". The toolkit owns them.

## The model

A palette is a field and a ranked list of items. **Sources** give the items. The palette asks the sources, ranks
their items together, shows them, and says which item the person chose.

### A source

A source has:

- **a prefix** (`ui.Palette_Prefix`, below), or none: a source without a prefix is in the plain search only (a
  chooser's), `plain` or not;
- **a title** ("Sessions", "Tabs"), shown in the hint row and in its "reading" row;
- **`plain`**: its items take part in a search without a prefix too;
- **`remember`**: its choices go to the usage memory (false for the views' moves and the secrets);
- **its alternates**: the meaning of Ctrl+Enter, Alt+Enter and Shift+Enter for its items ("Open in a new tab"), or
  none;
- **`read`**: a procedure that the palette calls on the interface's thread when the query or the source's version
  changed, with a question. It answers at once from the program's memory, or it starts a chore and answers later
  (`palette_answer`);
- **`mark`**: a procedure that says the mark of an item now (a switch on, the model in use). The palette calls it for
  the rows in view only: a command's `checked` can walk a conversation;
- **its version**: the program bumps it when the source's items change.

**A question is a counted handle.** It holds a reference to the palette's link (`Palette_Link`), and the source ends
it exactly once: `palette_answer`, `palette_answer_error` or `palette_question_drop`. An answer that comes after
`palette_destroy` finds no palette and only lets go of the handle. A raw `^Command_Palette` kept by a chore was refused:
it is a write into freed memory the day the palette goes first.

**An answer is the source's, built in its own arena** (`Palette_Answer`, `palette_answer_allocator`), on a chore for
an answer made later. `palette_answer(q, &answer)` takes it whole, without a copy, kept or dropped (and freed). One
call for an answer made at once and one made later. A copy at the answer was refused: a searching source answers at
each key, and a copy of 100 000 items on the interface's thread is work in proportion to the data.

A source answers in one of two ways:

- **It gives its items.** The palette ranks them. Most sources do this: commands, settings, sessions, tabs, models.
- **It searches.** It receives the query and returns what it found, best first (a walk of a folder, the server's
  find, a history of a hundred thousand pages). The palette still scores each item with the same matcher, to merge it
  with the other sources and to light its ranges. An item that the source found and the matcher does not find stays,
  with the matcher's last-resort penalty: the source knew something (a page's content, a path's folder).

### An item

An item has an id (stable in its source, never a title), a title, a detail, an icon, the text of its keys, a group,
tags, a last text (a setting's name, an address: `Rank_Entry.last`), `disabled`, and `stays` (choosing it does not
close the palette: a switch). Its mark comes from the source's `mark`.

### A choice

`palette_chosen` returns the source, the item's id, its index in its answer and the modifiers of the Enter. It does
not return an index in a concatenated table. `palette_chosen_command` gives a command's index in the program's table:
one field, not a second copy of the index in the choice. The toolkit's own sources act themselves: a setting flips or opens its page, a view's move runs.
The program handles only the choices of its own sources.

### The toolkit's sources

Every program gets three sources, and gives them only its data:

| Source | Prefix | Plain | What choosing does |
|---|---|---|---|
| Commands | `>` | yes | returned to the program: the index in its `[]ui.Command` table |
| Views' moves | `>` | yes | the toolkit runs it (`views_command_run`); the palette's own view is not listed |
| Settings | `:` | yes | the toolkit flips a switch (the palette stays) or opens the settings on it (`prefs_page.show`) |

`palette_commands` gives the commands source what `palette_set` took: the table (each command's `id` is its item's id
and its key in the usage memory), `disabled`, the version, and the program's Shift+Enter. The keys shown, the aliases
and Ctrl+Enter and Alt+Enter are the keymap's ([keymap.md](keymap.md)). Its first call adds the moves source too. The
settings source is `prefs_page.palette_settings_add`: `ui` does not import `prefs_page`. A program with its own
settings model (Wren's `about:config`) gives its own source of the same prefix instead.

## The prefixes

The prefixes are a closed table of the toolkit, `ui.Palette_Prefix`. A prefix means the same thing in every program.
A program fills a prefix with a source, or leaves it empty. It cannot invent a character.

| Prefix | Name | Meaning | Sources |
|---|---|---|---|
| (none) | plain search | every source with `plain`, and every source without a prefix | commands, moves, settings, and what a program adds |
| `>` | Commands | what the program does | the commands, the views' moves, opencode native's server commands |
| `@` | Go to | the things of the program that one opens or switches to | sessions, tabs and closed tabs, clipboard entries, captures, processes |
| `/` | Paths | files, folders and addresses | the session's files, a folder to go to, visited pages, bookmarks |
| `#` | Choose | one among alternatives, the one in use marked | models, agents, workflows |
| `:` | Settings | the settings | the toolkit's settings source, or the program's own |
| `$` | Secrets | entries of a vault | Wren's vault |

Rules:

1. The prefix is the first character of the query, after leading spaces. The spaces after it are dropped.
2. A prefix counts only when one of the program's sources holds it. Else the character is text: `/home/sacha` in a
   program without a Paths source is a plain search.
3. A program adds its own source in one of two ways: under one of the prefixes, with that meaning; or with no prefix,
   in the plain search only. A new meaning that two programs need is a new line of this table, in the toolkit.
4. A Secrets source is never in the plain search and never in the usage memory. Its details are not shown.
5. A program can open the palette with a prefix typed (`palette_open(p, "@")`): opencode native's sessions button,
   Wren's address bar shortcut.

## Keys

- **Ctrl+K and Ctrl+Shift+P open the palette** in every program. Again: they close it. The toolkit gives the command
  (`ui.palette_command()`, scope `.Window`) and its one reader, `palette_keys`. Two ways to read the keys were refused
  (`command_pressed` of the command and `palette_toggle` beside `palette_keys`): they differ in what they follow. A
  close that the palette did not make (Escape, a click outside) is followed in `palette_chosen`, which the program calls
  at each build, and in `palette_keys`. This changes a refused alternative of [commands.md](commands.md) ("no
  ready-made window commands"): homogeneity first.
- **Up, Down** move the selection and wrap. **Page Up, Page Down** move by the rows in view. The selection skips a
  disabled item.
- **Enter** chooses. **Ctrl+Enter, Alt+Enter, Shift+Enter** choose with the source's alternate; without one, they do
  what Enter does.
- **Tab** completes: an item that has a completion (a folder of the Paths source) puts it in the field. Else Tab does
  nothing.
- **Escape** closes the palette. Backspace on a prefix removes it, as any character.
- A click chooses. The pointer selects a row when it moves over it, not when the list moves under it.

## Look

- One view of the toolkit (`PALETTE_VIEW`, home Dialog), at the top centre of the window it is asked from, resizable;
  the views' memory keeps its size. The search band (`ui.search_band`) is its top.
- **One row shape for every source**: the icon, the title with the lit ranges, the detail (weak), the mark, the keys
  (weak). A path or an address in the detail is cut in its middle. A program gives an icon glyph; a source can draw
  its own icon in the icon's place (Wren's site icons).
- The selected row is the toolkit's: a well with the accent's bar. The program's theme gives the colours.
- With nothing typed: **Recent** (the heaviest choices of the usage memory, among the items listed), then the
  commands under their groups. The settings and the moves are not listed then: `:` and `>` list them.
- With something typed: one ranked list, each row with its group or its source's title after the title.
- **The hint row** is the foot: the prefixes that the program has, each with its name (`> Commands  @ Sessions
  : Settings`), and at the right the keys of the selected row (`Enter Run`, the alternates of its source). A click on a
  prefix types it. While a prefix is typed, the hint row shows that source alone.
- **Nothing matches**: one weak row. With a prefix and a source still reading: "Reading sessions…" instead.

## Ranking

One ranking for every source: `ui.rank` with `rank_palette`. The title whole or at the starts of its words, then the
tags, then the group, then the same with a slip, then the last text. The usage memory adds its bonus
(`choice_bonus`). A plain search puts the items of the program's own sources (not commands, moves or settings) a few
points behind at an equal score: a command typed whole beats a page whose title holds the same word. Disabled items go
after the others, greyed.

**The ranking always runs on a chore.** The palette keeps each answer as a snapshot, once per source version (it takes
the answer's arena, no copy), and ranks the snapshots on a chore at each new query. The list shown stays until the new
ranking arrives. One path for 10 items and for 100 000.

**A ranking that a newer one replaced stops.** The link holds the serial the palette waits for (`latest`, atomic). A
ranking reads a source by chunks of `PALETTE_RANK_CHUNK` items and stops at the first look that finds another serial.
Without it, a letter typed at each frame over 100 000 items starts one full ranking per letter, they fill the chores,
and the last letter's ranking waits behind them all (the day-one test 6 failed on its bound for that reason).

## Reading and serials

- The palette has a serial. It changes at each query, each open and each close. Each question to a source and each
  ranking carries it. An answer with another serial is dropped and freed.
- A source that reads (its question has no answer yet) shows "reading" in its row (prefix) or as a spinner in the
  band's count (plain search). The palette never waits for it. The source owns its timeout and its error: an error is
  one weak row, "Sessions: could not read (…)".
- **Enter while a ranking is in flight waits for that ranking** (a new query, a late answer, a change of the memory),
  then chooses. It does not wait for a source that reads. If the person had moved the selection, Enter chooses that
  item, where the new ranking put it; else the first row that acts. A person who types "nf" and Enter in one frame gets
  the first item for "nf", not for "n".
- **The selection follows its item**: its source, its id, and whether it is a row of Recent (an item can be in Recent
  and in its group). A late answer that puts rows above the selection does not move it to another item. Until the
  person moves the selection after a change of the query, the selection is the first row that acts; a disabled
  `first` of the commands is not put first.
- **A source removed** takes its answer and its question with it, and the ranking in flight (which reads its snapshot)
  is dropped: no row of the list points at it.

## The usage memory

The usage memory is `ui.Choice_Memory`. The palette owns it. The program gives the path of its file
(`palette_choices.txt` in its state folder; "" in a test or a demo). A choice's key is `<source>:<id>`
(`command:tab.new`, `setting:appearance.theme`, `session:ses_…`): an id, never a title, so the memory holds across
languages. The palette notes each choice of a source with `remember`. Recent lists only the items present in an answer
that the palette already has: a session deleted since is not listed.

## What each program's palette becomes

- **papier, inspecteur**: `>` and `:` from the toolkit's sources. The code that decodes the chosen index by ranges
  goes. Inspecteur adds `@`: the processes and the services; choosing one selects its row. Inspecteur's `disabled`
  that follows the selection stays as a version of its commands source.
- **cliche**: the editor's and the history's palettes are the toolkit's with its commands. The history adds `@` (the
  captures) and `#` (the workflow to use). The add palette of the node graph is **a chooser**: a palette with one
  source and no prefix shows no hint row and no Recent. `ui.flow_palette` gives that source.
- **classeur**: `@` the tabs and panels (they replace "Tab 1 to Last tab", which showed when "tab" was typed). `/` the
  folders: a path typed, the recent folders, read on its workers. Its Ctrl+Enter (a key of one's own) and Alt+Enter
  (an alias) are the alternates of its commands source.
- **opencode native**: its palette goes. Its sources:
  - `>` its commands, the views' moves, and the server's commands in their group "Server" ("/compact": choosing puts it
    in the composer, as today);
  - `@` the root sessions;
  - `#` the models and the agents, the one in use marked;
  - `:` the toolkit's settings source on its `cfg_prefs`;
  - `/` the files of the session's folder, searched by the server: a later step.

  What changes for its user: `/` no longer lists the server's commands (they are under `>` and in the plain search);
  the agents move from `@` to `#`; with nothing typed, Recent and the commands show, not the eight last sessions; a
  switch flips and the palette stays open; the rows have the toolkit's look.
- **Wren**: its registry stays its own type (a name, a condition, an action around `ui.Command`). It gives a
  `[]ui.Command` table to the commands source at each registry version. Its sources: `@` the tabs and the closed tabs,
  `/` the visited pages and the bookmarks (alternate: "Open in a new tab"), `:` its own source over `about:config`, `$`
  the vault. `palette.odin` goes, with its nine settings: the view remembers the width, the toolkit's constants give the
  rest.

## Decisions

The design's open questions, answered by the user. The principle behind each answer: homogeneity first. What helps one
program helps all of them. Opencode native changes where the shared palette is more consistent.

- **`$` Secrets stays in the shared table.** Only Wren fills it today. A second vault (a password field's history) then
  has its prefix ready, with the same rules (never plain, never remembered, no detail shown).
- **Opencode native follows the table.** `#` is Choose: the agents move there, with the models. `/` is Paths: the
  session's files. The server's commands go under `>`, in their group "Server".
- **No setting turns Ctrl+K off.** A standard shortcut is not disabled. A widget that needs Ctrl+K (a terminal, a
  shortcut recorder) claims it (`keys_claim`), as [commands.md](commands.md) says.
- **Disabled items are greyed and listed last.** A person learns that a command exists, and the items that act come
  first. With nothing typed, the disabled commands are last in their group.
- **Personal keys and aliases for every program** (classeur's Ctrl+Enter and Alt+Enter, its aliases typed whole): the
  toolkit's, in [keymap.md](keymap.md). The commands source's `names`, `keys`, `first` and `alternates` went with it.
- **The palette always remembers the choices.** No setting turns the usage memory off.
- **The ranking always runs on a chore**, a short list too. The price is one frame between a key and its list. One path
  is worth that frame: the tests see the path that ships.

After the first four programs moved to the palette (papier, inspecteur, cliche, classeur), their reports listed what
the toolkit lacked. The answers, one API per need:

- **The toolkit owns the palette's command whole.** `palette_keys` reads its keys, and the sheet of the keys lists it
  (after the program's commands). A program's table has no line for it; a menu line reads `palette_command()` at its
  build. A constant of its keys for a program's const table was refused: it makes two lines of one command, the
  program's and the sheet's, and every program writes the same line.
- **The settings source asks for its page options** (`options: proc(user) -> Page_Options`) each time it reads or
  acts. A copy of the options kept dangling slices (the themes made again): every program had to add the source again
  at each change. One add at the start is enough.
- **One usage memory per file for the process** (`choice_memory_acquire`, counted). Two windows of one program each
  wrote the whole file, and the last to close won. A merge at each write was refused: two writers still race between
  the read and the write. The windows that share it build on one interface thread.
- **A choice made before the file was read is not lost** at a quick quit: the close has a chore read the file, waits
  for it within a bound (it waits for the writer anyway), merges and writes. Past the bound the file is left as it is:
  a write of the new choice alone would lose the file's.
- **A question can be ended from any thread.** Off the palette's interface thread, the end is posted there through
  the link (which holds the window's Task_Box). A window gone refuses the post: the end lets go of the handle and frees
  the answer where it is, so nothing is left at a program's end. An end that read the palette's state from a chore (a
  task's `lost`) was a race. `palette_answer_free` frees an answer never given.
- **A selection's version moves with its active row too**, and with a swap of one row for another at the same count:
  a command that acts on the active row reads its `disabled` from that version.
- **The node graph's add palette is a source of the toolkit** (`Flow_Palette`, `flow_palette`), a chooser. Cliche
  wrapped `flow_palette`'s commands in a source of its own: what helps one program helps all.
- **`palette_has`**, and `palette_add` idempotent: a program does not test one of a source's fields to know it is added.
- **A question carries its prefix.** A source in two places (classeur's folders under `/` and in the plain search)
  tells them apart, and is asked again in the other place for the same query.
- **A choice carries its query**, without its prefix (classeur's Alt+Enter makes an alias of it): reading the field
  after the close, and stripping the prefix by hand, was each program's copy of the parse.
- **A toggle command is a property of the command** (`Command.toggle`), its state the program's
  (`Palette_Commands_Options.checked(user, index)`, read for the rows in view). One concept for the menus and the
  palette: a menu line of a toggle already takes `checked` from the program, and the palette's row shows the same state
  and stays open when chosen, as a setting's switch does. A `stays []bool` and a `marks` proc beside the table were
  refused: whether a command is a switch does not change, it belongs with its label and its keys. The state is read at
  each build, not versioned: a flip ranks nothing again. (opencode native's Expand tools, Follow the output.)
- **A command's detail** (`Palette_Commands_Options.details`, part of the version): what it acts on ("Session · Fix
  the build"). Shown, not searched: a detail that every Session command shares would make the session's title find
  them all, and no other source's detail is searched either. A detail read per row in view was refused: the details
  change with what they name (a session switched), rarely, and a version says it.
- **`palette_ranked_for(p, text)`** for tests: whether the list shown was ranked for that text. A test reading the
  palette's private state was refused.

## Refused alternatives

- **Keep two palettes** (the toolkit's for four programs, their own for opencode native and Wren). It is how they
  diverged: each fix lands in one of them.
- **A prefix grammar per program** (a program registers any character). The same character then means two things in
  two programs, which is today's defect.
- **A callback per keystroke on the interface's thread that returns the filtered items** (`palette_items` of opencode
  native, Wren's `items`). The work is in proportion to the data on the interface's thread, and one slow source
  freezes the typing.
- **Ranking on the interface's thread for a short list, on a chore for a long one.** Two paths: a test sees one of
  them, a defect lives in the other.
- **Sections per source** (the best of each source in its own block). A weak source above buries the best hit of a
  strong one. One merged ranking.
- **A chip for the prefix** (the character taken out of the field). A text that the person does not see is a hidden
  state. Backspace then needs a rule of its own.
- **Word prefixes** ("cmd:", "tab:"). They are longer to type and change with the language.
- **The program decodes every choice** (an index in a concatenated table). It breaks when the table is made again
  before the choice is read. A choice is a source and an id.
- **Hidden disabled commands** (opencode native today). The person does not learn that the command exists. Greyed and
  last.
- **Settings of the palette per program** (Wren's width, rows, half-life…). They make the palettes differ.

## Subtle points

- The palette of a program with several windows opens over the window it is asked from. Its moves are that window's
  views (`views_commands_update(owner = …)`).
- The usage memory was named `palette_usage` in the request: the toolkit's name is `Choice_Memory`.
- A source's `read` runs on the interface's thread. It must not make a system call. It answers from memory or starts a
  chore.
- A switch's mark is read for the rows in view, at each build. A flip does not rank the list again.
- The snapshot of a source is immutable while a chore ranks it. A new version makes a new snapshot; the old one is
  freed when its last ranking ends.
- A window command's key still works while the palette's field has the keyboard (commands.md). The palette's command
  closes it.
- **A toolkit source acts in `palette_chosen`, not in the palette's build.** A view's move docks or closes views: it must
  not run inside a view's builder. The program calls `palette_chosen` at each build anyway, for its own choices.
- **A switch's flip does not rank again.** Its choice goes to the usage memory, whose version is part of what a ranking
  depends on; the palette counts that one change as seen. The settings source reads again when a preference is
  registered, not when a value changes (`Prefs.version` moves at each value).
- **An error answers the question.** A source that could not read is not asked again for the same query and version:
  else it is asked at each build.
- **The moves source reads again only when the moves it lists change.** The views' version moves with any view's
  step, the palette's own too (its opening, its first frame shown), whose moves the source leaves out. Read again at
  each such step, it ranked the list once more after a toggle chosen with the palette open. A fingerprint of the moves
  listed, taken when the views changed, decides.
- **A searching source's older answer** stays until the new one comes, but only its items that the matcher finds: what
  it found for "do" is no proof for "srv/".
- **The snapshots are counted.** The palette holds one per source, each ranking one per source in scope; the last to let
  go frees it, on whichever thread. The list shown is the last ranking itself (its rows point into its snapshots).
- **The selection's item is known by its source, its id and its Recent flag.** A ranking started while the selection
  did not move finds that item's row on the chore; after a move during the ranking, the interface's thread looks for it
  once, by the same rule.
- **The commands source compares versions, never `disabled`.** A program changes what can act with a new `version`
  (0: the table and `disabled` do not change in place; their addresses are compared). A pass over `disabled` at each
  build was refused: work in proportion to the data at each frame.

## Migration

1. The toolkit (done): the sources, the prefix table, the hint row, the serials, the ranking on chores, the usage
   memory owned by the palette, the three toolkit sources. `palette_set`, `Palette_Options` and
   `prefs_page.palette_commands` went; fidget uses the toolkit's palette.
2. papier, inspecteur, cliche: the toolkit's sources, their decoding removed; cliche's add palette as a chooser.
3. classeur: `@`, `/`, the alternates.
4. opencode native: its sources; its `palette.odin` goes. `/` files after.
5. Wren: the registry's table, its sources; its `palette.odin` goes.

## The tests that break the design on day one

1. **Type and Enter in one frame**: the choice is the first item of the full query's ranking.
2. **A stale answer**: a source answers for "ab" after the query is "abc", or after a close and an open. The answer
   is dropped, and freed.
3. **A source that never answers**: the palette shows "reading", Up, Down and Escape work, a later answer is dropped.
4. **A late answer above the selection**: the selected item stays the same item.
5. **A quiet build**: with nothing changed, no source is asked, nothing is ranked (a counter).
6. **No ranking on the interface's thread**: a source of 100 000 items; the interface's thread calls no matcher (a
   counter per thread).
7. **A prefix without a source**: `/home/x` in a program without Paths is a plain search.
8. **The usage memory across languages**: a choice made in English is first under Recent in French.
9. **A switch**: Enter flips it, the palette stays open, its mark changes, the list is not ranked again.
10. **One table of prefixes**: each program's test lists its sources (`palette_prefixes`: "> Commands", "@ Sessions"…)
    and compares them with the list it means, as `command_typing_keys` does for the keys.
