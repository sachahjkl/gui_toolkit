# Personal keys and aliases: intent

A person sets a key or an alias for a command in any program, the same way: in the palette, Ctrl+Enter records a key
for the chosen command, and Alt+Enter makes the letters typed its alias. Classeur had this alone (`classeur/src/keymap.odin`
and its recorder in `palette.odin`). The toolkit takes it: `ui.Keymap` in `src/ui/keymap.odin`, its recorder view, its
two standard settings in `prefs_page`. A command's keys and the window commands are in [commands.md](commands.md). The
palette is in [palette.md](palette.md).

## The problem

- **A command has no stable name in the toolkit.** `ui.Command` has a label, translated at its display, and the
  programs' tables are indexed by an enum. A person's key must survive a new version and a change of language. The
  usage memory has the same need, and each program answers it differently: classeur and opencode native give their
  own ids (`names`), inspecteur gives its enum's names, papier and cliche give nothing (the English label).
- **Every reader of keys knows only the command's own keys.** `command_pressed`, `command_shortcut`, `command_tip`,
  the sheet and the palette's key text read `Command.keys`. Classeur made a second table for each of them, at each
  change of its keymap, so that its menus, its sheet and its palette said the person's keys.
- **Classeur wrote its keys in the language in use.** `binding_text` calls `chord_text`, which translates ("Ctrl+Maj+M").
  A value written in French was not read after a switch to English.

## Decisions

### A command's identity: `Command.id`

`ui.Command` has an `id`: a string, lower case, of letters, digits, `.`, `_` and `-` (`tab_new`, `tab.new`). It never
changes when the label changes. It holds no `=`, `;`, `,` or space: those are the separators of the stored text.

- **Every command of every table has an id.** A program's test calls `ui.command_ids_check(tables...)`: one line per
  empty, malformed or duplicate id, as `command_typing_keys` lists the typing keys. The test expects none.
- **The id is the usage memory's key too** (`command:<id>`). `Palette_Commands_Options.names` goes: it was a second
  copy of the id beside the table.
- **One id in two tables is one command for the keymap.** Cliche's "copy" in the editor and in the history: one key set
  for it acts in both. Two different commands take two ids.
- **A program that changes an id loses the person's key and alias for it.** No table of old ids is kept. The stored entry
  stays in the text, inert, until the person removes it. A program changes an id only when the command changes meaning.
- **The toolkit's palette command has no id.** Its keys are read only (palette.md, "No setting turns Ctrl+K off").

Refused:

- **The English label as the id.** A fix of a label's wording loses every person's key on it. Papier and cliche lose
  their usage memory once in the migration, which is the price of this choice.
- **The enum's name, read by reflection.** A rename in a refactor then changes stored data without anyone deciding it.
  An explicit string makes the rename visible in the diff. Tables built at run time (Wren's, opencode native's) have no
  enum anyway.
- **An id required only for "customizable" tables.** Two kinds of tables make two palettes: Ctrl+Enter would work on one
  command and not on its neighbour.

### Where the keymap lives

`ui.Keymap` is the program's, one per process: `app.keymap`. Each window's `ui.State` points to it
(`ui.keymap_use(&app.keymap)` once per window). The windows of one program share the person's keys, as they share the
settings file. A global was refused: the toolkit keeps no app state in globals.

The keymap holds:

- `bindings`: id → one binding, one chord or a sequence of two;
- `aliases`: alias → id;
- `known`: the ids of the program's commands (`ui.keymap_known(&km, table)`, once per table, again at each version of a
  table made at run time);
- `taken`: chord → id, made from `bindings` restricted to `known`, the first chord of each sequence included;
- `version`: bumped at each change of the bindings, the aliases or the known ids.

`taken` is made again when `bindings` or `known` changes, never in a frame.

**An entry whose id is not known is inert.** It is kept in the stored text, and it takes no chord from anyone. A
command absent today (a mode, a plugin, a command a program removed) does not steal a key from the commands that exist.
Dropping unknown entries at read was refused: a command of a mode not yet seen would lose its key at each start.

### How a key is read

`command_pressed(c)` keeps its signature. Its cost stays in proportion to the command's own keys, a few map lookups. The
loop over the table is the program's, as before.

1. If `c.id` has a binding: only that binding's chords act. The command's own keys do not.
2. Else: each own key acts, except a chord in `taken` by another id. **A person's key wins over a command's own key.**
   The command that had that chord keeps its other own keys.
3. Every chord goes through `chord_pressed(chord, c.scope)`: the typing rule, `keys_claim`, the window scope and the
   holds stay the same for a person's key.

**One key, one command.** `keymap_bind` removes another binding with the same chord. It also removes a binding whose
chord is the first chord of the new sequence, and a sequence whose first chord is the new single chord: a prefix of a
sequence is no key of its own.

**A person's binding replaces all the command's own keys.** One binding per command. Several personal keys per
command were refused: no program asked for it, and the recorder then needs a list to edit.

### Sequences of two chords

- The first chord is read by `command_pressed` of the command that has the sequence, with its scope. Pressed, it sets
  the window's `pending` chord and its deadline, `KEYMAP_SEQUENCE_MS` (1500) after.
- **`pending` is in `ui.State`, one per window.** A first chord in one window is not completed in another.
- While a chord is pending, no single chord acts. The next key press completes a sequence or clears `pending`. That
  press is taken in both cases: a person who started a sequence did not mean the second key alone.
- Escape clears `pending`. The deadline clears it too: the toolkit wakes the window at the deadline (`wake_within`).
- **The toolkit shows the pending chord**: a small bubble at the bottom centre of the window, "Ctrl+M, …", until the
  sequence ends. A status line of each program's own was refused: each program has its own status, or none.
- The deadline is a constant, not a setting: one feel in every program.

### Persistence

Two standard settings of the toolkit, in a new `Standard_Set.Keys` that `STANDARD_ALL` holds:

    keys.custom   "tab_new=Ctrl+M, T;terminal=F7"   an id, its chords (", " between the two of a sequence)
    keys.aliases  "nf=new_folder;go=goto_popup"      an alias, an id

- **The names are classeur's.** Its users' values carry over with no migration code. A value that classeur wrote with
  a translated modifier ("Maj") is not read: no compatibility parse.
- **The chords are stored in English** (`platform.key_text` with no catalogue), whatever the language in use.
  `ui.binding_text(b)` shows them translated; `ui.binding_store_text(b)` writes them. Two procedures, because the
  display and the storage have two readers.
- **They are `advanced`, not `hidden`.** The keys are the person's settings: an export carries them to another
  machine. The settings page shows each as a text field with its reset: that is the minimal page to remove one or all
  (below).
- **The keymap does not import `config`.** `ui.keymap_read(&km, custom, aliases)` reads the two texts.
  `Keymap.changed` (a procedure and its user) is called after each change made through the palette, with the two new
  texts. `prefs_page.standard_watch` sets it to write the two settings, and reads them into the keymap when the file
  changes. A value it wrote itself comes back as a change of the file: the keymap compares the text with its own and
  reads nothing. Wren gives the same two calls its own settings model.
- The texts are written in the order of the ids, sorted: the file does not change at each save because of a map's order.

### The palette

The commands source does it all. A program gives its table with ids and its keymap through `ui.keymap_use`, and writes
nothing else.

- **Ctrl+Enter on a command: "Set a key".** The palette closes. The recorder view opens: `KEYMAP_RECORDER_VIEW`, a
  dialog of the toolkit, classeur's recorder moved. It takes any chord (`key_take`, with `keys_claim` of every chord):
  two for a sequence. Enter keeps them, Escape gives up, Backspace before any chord gives the command its own keys
  again. When it ends, the palette opens again with its query.
- **The recorder says when a chord types text**: "This key does nothing while you type in a field." The rule of
  commands.md stays; the person learns it at the right moment.
- **Alt+Enter on a command: "Make the letters its alias".** The choice's query, trimmed and lower case, becomes an alias
  of that command. A former alias with the same letters moves to it. The palette opens again with the query.
- **An alias typed whole puts its command first**, under `>` and in the plain search. The aliases of a command are also
  its tags: "n" finds "nf". The source makes its entries again when `Keymap.version` changes. `Palette_Commands_Options.first`
  goes: the alias was its only use.
- **The keys shown on a row are the keys in effect.** `Palette_Commands_Options.keys` goes.
- **Ctrl+Enter and Alt+Enter on a command are the toolkit's in every program.** Shift+Enter stays the program's
  alternate. Wren's "open a URL command in a new tab" moves from Ctrl+Enter to Shift+Enter: one meaning per key in every
  program.

`ui.hotkey_field` is not the recorder. It records one combination for the system (Super, a character with no key name),
and it needs a modifier. A command's key can be F7 alone, and a sequence's second chord is often a letter alone. The
recorder shares its means: `key_take`, `keys_claim`, `kbd`.

### Menus, tooltips, the sheet

- `command_shortcut`, `command_tip` and `command_keys_text` read the keys in effect: the person's binding, else the own
  keys that no other id took. A program changes nothing at its menus.
- **A sequence reads "Ctrl+M, T"; alternative keys read "Ctrl+K / Ctrl+Shift+P".** The comma was the separator of both
  before. The comma stays the sequence's, because the stored texts already use it.
- **The sheet lists from the keys in effect.** Its list is made again when `Keymap.version` changes (part of
  `Sheet_Key`). A person's key shows in the accent's colour. A command whose own key was taken shows its other keys, or
  is not listed when it has none left.
- A command that has an alias and no key is not listed in the sheet. The sheet is about keys.

### Removing a key or an alias

Minimal: no page of its own.

- A key: Ctrl+Enter on the command, then Backspace. All keys: the reset of `keys.custom` on the settings page.
- An alias: Alt+Enter with the same letters on another command moves it. All aliases: the reset of `keys.aliases`.
  One alias: edit the text of `keys.aliases`.

A page that lists every binding with a remove button was refused for now: the sheet and the palette already show them,
and no person asked. If a person asks, the sheet's lines get the remove button, not a new page.

## API sketch

    Command.id: string
    Keymap :: struct { bindings, aliases, known, taken, version, changed, user, ... }
    Binding :: struct { chords: [2]Chord }
    KEYMAP_SEQUENCE_MS :: 1500
    KEYMAP_RECORDER_VIEW :: "keys"

    keymap_use(km)                         this window's state reads km
    keymap_known(km, table)                the ids that exist (again at a table's new version)
    keymap_read(km, custom, aliases)       the stored texts into the keymap
    keymap_texts(km) -> (custom, aliases)  the texts to store, ids sorted
    keymap_bind(km, id, b), keymap_unbind(km, id), keymap_alias(km, alias, id)
    keymap_alias_command(km, text) -> id   "" none
    command_keys_in_effect(c) -> []Binding
    binding_text(b), binding_store_text(b), binding_parse(text)
    command_ids_check(tables: ..[]Command) -> []string
    keymap_destroy(km)

    prefs_page: Standard_Set.Keys, KEYS_CUSTOM_PREF, KEYS_ALIASES_PREF; Standard_Watch_Options.keymap

## Migration

1. **The toolkit, with tests.** `Command.id`, `Keymap`, the reading in `command_pressed`, the recorder, the commands
   source's alternates and aliases, the key texts, the sheet, the two settings. `names`, `keys` and `first` leave
   `Palette_Commands_Options`. Fidget gives ids.
2. **classeur.** `keymap.odin` goes, its recorder, its second tables for the palette and the sheet, `window_keys`'s
   pending reset, `bindings_pressed`, and its two `Def`s. Its `Command` keeps `run`, `enabled` and `in_text` around a
   `ui.Command` with its ids unchanged: the stored values stay valid.
3. **papier, inspecteur, cliche.** An `id` on each line of their tables, `command_ids_check` in their tests,
   `keymap_use` and `keymap_known` at start. Inspecteur's enum names and papier's and cliche's labels stop being the
   memory's keys.
4. **opencode native.** Its `Command.id` moves into `ui.Command.id`. Its own key reading (`commands_keys`) reads through
   `command_pressed`. The server's commands get `server.<name>` and are known at each version of their list.
5. **Wren.** `Command.name` becomes `ui.Command.id`. Its two settings go into its own model with `keymap_read` and
   `Keymap.changed`. A URL command's new tab moves to Shift+Enter.

## Subtle points

- `known` must hold a table's ids before its first `command_pressed`: else a person's key on an unknown id takes no
  chord in the first frames, and the command's own key acts once.
- A person's key on a disabled command: the key does nothing, and it is not given back to the command whose own key
  it took. One key, one command, whether the command can act now or not.
- A sequence's first chord on a `.Page` command is held behind a dialog like any page key. On a `.Window` command it is
  read from anywhere.
- A widget's claim (`keys_claim`) also stops a sequence's second chord. The pending chord is then cleared by the next
  key press, which the widget took: the person sees the bubble go.
- The recorder claims every chord: Ctrl+K is a value there, not the palette (commands.md, "Exceptions").
- An alias is compared after trim and lower case. Its first character is never read as a prefix: `>nf` is the alias
  under `>`, and `nf` is the alias in the plain search.

## The test that breaks the design on day one

A test table has New tab (`tab_new`, Ctrl+T) and Close tab (`tab_close`, Ctrl+W and Ctrl+F4). In French, set
`tab_new` to Ctrl+W. Restart in English. Then:

- Ctrl+W runs New tab and not Close tab; Ctrl+F4 still closes the tab;
- the menu line of Close tab shows Ctrl+F4, and the sheet agrees with the menu;
- `keys.custom` reads `tab_new=Ctrl+W`;
- a stored entry `gone=Ctrl+F4` for an id that no table has changes none of this.

It breaks an id that follows the language, a stored text that follows the language, a reader of keys that ignores the
keymap, and a stale entry that steals a key.
