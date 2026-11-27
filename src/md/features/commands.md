# Commands: a key that types text, the window's commands

A program names its commands once, in a table of `ui.Command` (`src/ui/commands.odin`). The table gives the keys, the
menus' and the tooltips' key texts, the palette's commands source and the sheet. This file records two rules of that
table: what a key that types text may do, and where a window command's key works. The API is in
[docs/commands.md](../../../docs/commands.md).

## The problem

A key that types text is a printable key with no modifier or with Shift alone: a letter, a digit, a punctuation mark,
Space, Backspace, keypad + and -. While a text field has the keyboard, that key belongs to the field. A command on it
then has two outcomes, and both are defects:

- The command runs and the field loses the character (cliche's tool letters in a shape's text, before each program
  guarded them by hand).
- The field takes the character and the command never runs, while its menu line still shows the key. Papier keeps its
  search field focused at all times: a key such as Shift+D on an entry's command can never work there.

Each program had its own guard: cliche's `Edit_Typing` mode, classeur's `in_text` flag, inspecteur's `editing_chord` and
its Space test, papier's choice of keys. Each guard is a copy of one state machine: "a text field has the keyboard".
The toolkit knows that state (the focus box is a text field), so it owns the rule.

## The rule

1. `ui.command_key_types_text(chord)` says whether a chord types text. It is a pure function of the key and the
   modifiers: Ctrl or Alt with any key types nothing; F1 to F12, Escape, Enter, Tab, Delete, Insert, the arrows, Home,
   End, Page Up, Page Down, Menu and Print type nothing with any modifier. Backspace counts as typing: it edits the field.
2. `ui.command_pressed` never takes a chord that types text while a text field has the keyboard (`is_text_field` of the
   focus box: a line edit or a text area, not a list). The key goes on to the field. No program needs a guard of its
   own for this case.
3. A program checks its tables in a unit test with `ui.command_typing_keys(table)`. The function returns one line per
   chord that types text, `"<label>: <key>"`. The test compares the result with the list that the program expects:
   empty for a program whose field always has the keyboard (papier), the canvas tools for cliche. A new key that types
   text then fails the test until its author lists it on purpose.

The rule does not forbid such keys everywhere. Single-letter tools (cliche's V, R, E…), Space for a preview and
Backspace to go up are the convention of their kind of program, and they work while no field has the keyboard. Rule 2
removes the defect of the first case, and the test of rule 3 removes the second one: a program whose field always has
the keyboard lists no typing key.

## Refused alternatives

- **Refuse every typing key in every table** (an assert in `command_pressed`). It makes the defect impossible, but it
  takes the single-letter tools from cliche and Space from classeur and inspecteur. Those programs have no field with
  the keyboard while the keys are used.
- **Hide the key text of a typing command while a field has the keyboard.** The palette and the sheet always have their
  own field, so they never show these keys, and a menu's text changes with the focus. Rule 3 is a check at test time,
  not a change at run time.
- **A check over every program's table from the toolkit.** The toolkit does not see the programs. Each program calls the
  function in its own test.

## Subtle points

- The modifiers of a chord are only Ctrl, Shift and Alt (`platform.Modifiers`). Super is not part of a chord: the
  desktop takes it.
- Delete and Shift+Delete edit a field too (Shift+Delete cuts). They do not type text, so the rule allows them. A
  program that reads its keys before its field (papier's `view_keys`) gives them to its command; that is its choice.
- A program that reads keys with its own table reads each chord with `chord_pressed(chord, scope)`: the same rules as
  `command_pressed`, rule 2 and the window commands' scope too. The person's keys and sequences are the toolkit's
  ([keymap.md](keymap.md)): `command_pressed` reads them.

# Window commands

## The problem

Some commands are the window's, not a page's: the command palette, the keyboard shortcuts, the settings, close the
window, quit. A person expects them in every page and every mode: in the settings, while a field has the keyboard, while a
docked or floating view has the focus. Each program guarded its key reading with its own state: cliche skipped every key
while a field had the keyboard (its history page), opencode native read no key while a dialog was open (its settings are
a dialog), a program read its commands in one mode and not in another. Each guard was right for the page's commands and
wrong for the window's. The palette then could not open from the settings, which list themselves in it.

The state machine behind each guard is "who has the keyboard". The toolkit knows it. So the toolkit says which commands
ignore it.

## The rule

1. A command has a scope: `.Page` (the default) or `.Window`. The program marks its window commands.
2. `command_pressed` takes a window command's key whatever has the focus: a field, a list, a view's body without the
   focus (`keys_held_from_view`), and from behind a view shown as a dialog (`keys_held_by_dialog`). A page command keeps
   both holds.
3. A window command's key types nothing (Ctrl, Alt, or F1): rule 2 of the typing keys still holds, so a typing key would
   not work while a field has the keyboard. `command_window_typing_keys` lists the exceptions; a program's test expects
   none.
4. The program reads its window commands in every page and mode, before it builds the page. It has no guard of its own
   around them: the toolkit's holds are the only ones.
5. A widget that owns every chord while it has the keyboard claims them (`keys_claim(owner, ..pass)`) at each build. Then
   `command_pressed` takes none of them, a window command's neither, but the chords of `pass`. The claim is explicit and
   names its reason at its call: the default is that the window command wins.

## Exceptions that claim the chords

- **The shortcut recorder** (`hotkey_field` while it records): Ctrl+K is the value recorded, not the palette.
- **A terminal's grid** (opencode native's shells): Ctrl+K, Ctrl+W, Ctrl+Q go to the shell. Opencode native takes them
  out of the events before the interface sees them (`term_events`) and lets only Ctrl+Shift+T through. A grid built with
  the toolkit's boxes claims with `keys_claim(grid, {.T, {.Ctrl, .Shift}})`.

## Refused alternatives

- **A list of window chords that every field skips.** The fields take only their own editing chords (Ctrl+A, C, X, V, Z,
  Y and the moves): a window command's chord is not one of them, so nothing is to skip. The problem was the programs'
  guards and the toolkit's holds, not the fields.
- **Window commands that ignore a claim.** A shell and a shortcut recorder need Ctrl+K. Without the claim each program
  would guard its window commands again.
- **A claim of this build only.** A program reads its commands before it builds the widget, so the claim of the last
  build counts too.
- **Window commands that stop at every dialog.** The settings of a program are often a view shown as a dialog: the
  palette then could not open from them. A window command opens its own view on top (the palette, the sheet), and a
  question stays below it. A program that must not quit under a question gives `disabled`.
- **Ready-made window commands in the toolkit for the sheet and the settings.** Each program has its own words, keys
  and icons for them. The scope is one field on the table it already has.

## The palette's command: the toolkit's

The palette's command is the exception to the last refusal: `ui.palette_command()` (Ctrl+K and Ctrl+Shift+P, scope
`.Window`; a procedure over read-only keys, so no program changes them for all) and `palette_keys`, its one reader. This file refused it first, for the reason above: each program had its own words and
keys. The single palette ([palette.md](palette.md)) changes the balance. The palette is the same view in every program,
so its keys must be the same too: a person who opens the palette in one program with Ctrl+K expects Ctrl+K in the next
one. Homogeneity comes first. No setting turns Ctrl+K off: a standard shortcut is not disabled. A widget that needs the
chord (a terminal, a shortcut recorder) claims it with `keys_claim`, as before.

## The sheet's lines that are no command

A program has keys that belong to a widget, not to a command: Up and Down in a composer's history, Ctrl+V that pastes a
picture, a middle click, Escape twice that stops. They are not in its table, as no `command_pressed` reads them; the
sheet must list them all the same, or a person never learns them. `shortcuts_sheet_open`'s `extra` takes them as
`Sheet_Line{group, keys, label}`.

- **Their keys are text, in a table's English.** A middle click or "Esc, Esc" is no `Chord`, so a line's keys are text.
  The sheet names each word of it that is a key in the language in use (`platform.key_text`, the words of every
  command's keys): "Esc, Esc" reads "Échap, Échap" in French, as Escape does on a command's line. Shown as written,
  every program translated "Esc" itself, and a person read two names for one key on one sheet. A word that names no
  key ("Middle click") stays as written: the toolkit has no word for it, the program translates it. " / " separates
  two keys ("Up / Down"), as between a command's keys; a "/" that is a key ("Ctrl+/") has no space on one side.
  Refused: a line's keys as `Binding`s. A middle click has none, and a line that mixes a key and a click would split.
- **A new table without reopening.** A program makes its table again when the language changes; the sheet keeps the
  slices it was given. `shortcuts_sheet_set` swaps the table and the lines, open or not, and `shortcuts_sheet_open`
  calls it: a program never closes and reopens the sheet to change what it lists (the person's scroll would go).
- **Each group once.** The sheet shows a group where its first command stands, with all its commands together in the
  table's order. A palette's table orders by meaning and may alternate groups; a heading shown twice reads as two
  groups of one name.
- **In their group.** A line of a group the commands have goes after that group's last command; a line of a group no
  command has goes under its own heading after the commands. A person looks for a key by what it does, and the group
  says that.
- **Not in the palette.** A line acts on nothing by itself: the palette would list a choice that does nothing.
- **Refused: commands with no key reader** (a `Command` the program never reads, for the sheet alone). Its keys would
  be a `Chord` (no middle click), the palette would list it, and a person could rebind a key nothing reads.

## Subtle points

- Two places can read the same window command (the program's top level and a view's body). The first one takes the key:
  read window commands once, at the top of the build.
- A command hidden from the palette (`Palette_Commands_Options.hidden`: it does not exist in this state) takes no key:
  the program passes `hidden || disabled` to `command_pressed`, so its chord goes on to another reader
  ([palette.md](palette.md)). The sheet takes the same slice (`shortcuts_sheet_open`'s `hidden`) and leaves it out.
  Refused: `command_pressed` reading the palette's `hidden` itself: it takes a command, not an index, and a program
  can have no palette or several; the program has the slice at hand.
- `key_press_any` is the window command's read. It takes the event as `key_press` does: a later reader gets nothing.
