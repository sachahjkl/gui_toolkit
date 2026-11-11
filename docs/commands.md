# Commands: keys, palette and the sheet of the keys

A program names each of its commands once, in a table of `ui.Command`: its label, its group and its keys. The same table
gives the key handling, the shortcut of a menu's line, a tooltip's text, the command palette and the sheet of the keys:
they cannot disagree.

```odin
Cmd :: enum u8 { End_Task, Kill, Palette, Shortcuts }

COMMANDS := [Cmd]ui.Command{
	.End_Task  = {label = "End task", group = "Processes", keys = {{.Delete, {}}, {}}},
	.Kill      = {label = "Kill…", group = "Processes", keys = {{.Delete, {.Shift}}, {}}},
	.Palette   = {label = "Command palette", group = "Window", keys = {{.K, {.Ctrl}}, {.P, {.Ctrl, .Shift}}}},
	.Shortcuts = {label = "Keyboard shortcuts", group = "Window", keys = {{.F1, {}}, {}}},
}

// each frame, when no menu or dialog has the keys
for c in Cmd { if ui.command_pressed(COMMANDS[c], can(c)) { run(c) } }

// a menu's line, a tooltip
if ui.menu_item(COMMANDS[.Kill].label, ui.command_shortcut(COMMANDS[.Kill]), enabled = can(.Kill)).clicked { run(.Kill) }
tip := ui.command_tip(COMMANDS[.Kill])          // "Kill… (Shift+Delete)"

// the palette and the sheet
if run_palette { ui.palette_open(&app.palette) }
enabled: [Cmd]bool
for c in Cmd { enabled[c] = can(c) }
if i, resized := ui.palette(&app.palette, COMMANDS[:], enabled[:]); i >= 0 { run(Cmd(i)) }   // resized: save app.palette.size
ui.shortcuts_sheet("keys", COMMANDS[:], &sheet_open)
```

| | |
|---|---|
| `Chord{key, mods}` | a key and its modifiers; the zero value is no key |
| `Command{label, group, keys}` | `keys`: two chords at most, the first one shown in menus and tooltips |
| `chord_text(chord)` | `Ctrl+Shift+P`, `Shift+Delete`, `F5`: modifiers in the order Ctrl, Shift, Alt |
| `key_name(key)` | a key's printed name (`Page Down`, `Enter`, `Escape`) |
| `command_shortcut(c)`, `command_keys_text(c)`, `command_tip(c)` | the first key's text; every key's, apart by commas; `label (key)` |
| `command_pressed(c, enabled)` | one of its keys was pressed this frame: the press is taken. A command that cannot act takes no key |
| `palette_open(&p)` | opens the palette (`Command_Palette`, the program's) at the top centre of the window (`PALETTE_TOP` of its height), its field empty |
| `palette(&p, commands, enabled) -> (int, resized)` | while it is open: the commands under their groups' headings, each with its icon and its first key; the index chosen, or -1; `resized`: the user changed its size (`p.size`, logical pixels: keep it) |
| `shortcuts_sheet(id, commands, open, title)` | a dialog: every command that has a key, grouped, its keys at the right; scrolls past `SHEET_HEIGHT` of the window |

The palette is a dialog (`modal_sized`: its edges and its corner's grip resize it, `PALETTE_WIDTH_EM` by
`PALETTE_HEIGHT_EM` at first, never under `PALETTE_MIN_EM`) with a field at its top and the commands under it; a command's
`icon` (a glyph of the state's `icon_font`) shows before its label. Up, Down, Page Up, Page Down move the selection;
the pointer moving over a line selects it. What is typed keeps the commands whose label
(or label and group) holds it whole, or in pieces that each begin a word, the words in order (`fuzzy_words`: "prio" finds
"Raise the priority", "ks" "Keyboard shortcuts"; letters scattered in a word match nothing, so "prio" does not find
"Previous section"), the best matches first (the text whole before pieces, at a word's start before elsewhere; a match in the label
before one that needs the group's letters), the headings go and each line says its group, and the first match is selected: Enter runs
it. A command that cannot act now is greyed and is not chosen. Escape closes the palette,
and the sheet.

`tests/commands` tests the texts, the keys and the palette.
