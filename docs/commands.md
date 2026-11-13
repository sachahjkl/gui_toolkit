# Commands: keys, palette and the sheet of the keys

A program names each of its commands once, in a table of `ui.Command`: its label, its group and its keys. The same table
gives the key handling, the shortcut of a menu's line, a tooltip's text, the command palette and the sheet of the keys:
they cannot disagree.

![The palette: the program's commands under their groups with their keys, then one per preference of its settings (examples/showcase)](screenshots/showcase_palette.webp)

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
| `Command{label, group, keys, icon, tags}` | `keys`: two chords at most, the first one shown in menus and tooltips; `tags`: other words the palette finds it by ("exit", "close" for Quit), a match of them after one of the label's |
| `chord_text(chord)` | `Ctrl+Shift+P`, `Shift+Delete`, `F5`: modifiers in the order Ctrl, Shift, Alt |
| `key_name(key)` | a key's printed name (`Page Down`, `Enter`, `Escape`) |
| `command_shortcut(c)`, `command_keys_text(c)`, `command_tip(c)` | the first key's text; every key's, apart by commas; `label (key)` |
| `command_pressed(c, enabled)` | one of its keys was pressed this frame: the press is taken. A command that cannot act takes no key |
| `palette_open(&p)` | opens the palette (`Command_Palette`, the program's) at the top centre of the window (`PALETTE_TOP` of its height), its field empty |
| `palette(&p, commands, enabled, opts) -> (int, resized)` | while it is open: the commands under their groups' headings, each with its icon and its first key; the index chosen, or -1; `resized`: the user changed its size (`p.size`, logical pixels: keep it). Ctrl, Alt or Shift with Enter chooses too: `p.chosen_mods` says which |
| `Palette_Options{recent, recent_title, first, keys, foot}` | what a program adds: the commands run last on top under their heading ("Recent") while nothing is typed; a command first while something is (an alias typed whole); per command the text of its keys as the program shows them (its user's own, a sequence "Ctrl+M, T"); a line under the list |
| `shortcuts_sheet(id, commands, open, title)` | a dialog: every command that has a key, grouped, its keys at the right; scrolls past `SHEET_HEIGHT` of the window |

The palette is a dialog (`modal_sized`: its edges and its corner's grip resize it, `PALETTE_WIDTH_EM` by
`PALETTE_HEIGHT_EM` at first, never under `PALETTE_MIN_EM`) with a field at its top and the commands under it; a command's
`icon` (a glyph of the state's `icon_font`) shows before its label. Its list holds a whole number of lines at any size
(what is left of a line goes under it), so the foot never cuts its last line. Up, Down, Page Up, Page Down move the selection;
the pointer moving over a line selects it. What is typed keeps the commands whose label
(or label and group) holds it whole, or in pieces that each begin a word, the words in order (`fuzzy_words`: "prio" finds
"Raise the priority", "ks" "Keyboard shortcuts"; letters scattered in a word match nothing, so "prio" does not find
"Previous section"), or, when nothing is found so, each word with a slip or two (`fuzzy_typos`: "Qestart pencode" finds "Restart
opencode native"; none in a word of three letters, one up to six, two beyond), the best matches first (the text whole before pieces, at a word's start before elsewhere; a match in the label
before one that needs the group's letters), the headings go and each line says its group, and the first match is selected: Enter runs
it. A command that cannot act now is greyed and is not chosen. Escape closes the palette,
and the sheet.

A program with a palette of its own (commands, sessions and settings in one list) ranks each entry the same way:
`ui.palette_match(query, label, group, tags)` gives its score and what lights in its label.

### A ranked list

`ui.rank(query, items, entry, user, match, bonus, cache, version) -> []Rank_Hit` filters any list the way the palette does: each item is
matched, the hits are kept, the best first; equal scores keep the list's order, and an empty query keeps every item in
order. A picker, a slash menu, a mention list and a palette call it with their own items.

| Name | What it is |
|---|---|
| `Rank_Entry{label, group, tags, last, skip}` | an item as `entry(&item, user)` gives it: the text that lights, its group, other words that find it, a last text that finds it when nothing else does (nothing lights then), and `skip` for an item that is never in the list |
| `Rank_Hit{index, score, ranges}` | a kept item: its index in `items`, its score (higher first), what lights in its label |
| `Rank_Match` | how a query matches: `rank_palette` (the default: `palette_match`), `rank_fuzzy` (`fuzzy_score` of "label  group"), or a program's own, which folds its texts in the cache's slots it is given (`fuzzy_cache_text`, at most `RANK_MATCH_SLOTS`) |
| `bonus(&item, user) -> f64` | optional: added to the score of a hit only (how often the user chose it lately) |
| `cache: ^Fuzzy_Cache` | optional: the query and each item's texts folded, kept between calls; a list ranked each frame folds again only the texts that changed |
| `version: u64` | optional, with a cache: the items' version as the program counts their changes (what they are, what `bonus` reads). A call with the query and the version (not 0) of the last one returns the hits it kept and reads no item: a list shown at each frame costs nothing while neither changes |

The hits and their ranges are in temp memory; with a `version`, they are the cache's, kept until its next `rank`.

```odin
hits := ui.rank(query, models, proc(m: ^Model, _: rawptr) -> ui.Rank_Entry {
	return {label = m.name, group = m.provider}
}, match = ui.rank_fuzzy, cache = &picker.search)
for h in hits { ui.matched_label(fmt.tprintf("###m%d", h.index), models[h.index].name, h.ranges) }
```


A list that a program builds again each frame folds its texts once with a `ui.Fuzzy_Cache` (the palette keeps one):

| Procedure | Result |
|---|---|
| `fuzzy_needle(query) -> Fuzzy_Needle`, `fuzzy_text(s) -> Fuzzy_Text` | the query and a text folded once, for many matches: `fuzzy_find`, `fuzzy_score`, `fuzzy_words`, `fuzzy_typos` and `palette_match` take them in the place of strings, with the same results |
| `palette_entry(label, group, tags) -> Palette_Entry` | an entry folded: its label, the label with its tags, the label with its group and its tags |
| `fuzzy_cache_needle(&c, query)` | the needle, folded again only when the query changed |
| `fuzzy_cache_text(&c, slot, ..parts)` | the text of a slot (an item's place in the list; `parts` one after the other), folded again only when it changed: it is compared with what the slot held, byte by byte |
| `palette_entry_cached(&c, slot, label, group, tags)` | an entry kept in the slots `3 * slot` to `3 * slot + 2` |
| `fuzzy_cache_keep(&c, slots)`, `fuzzy_cache_destroy(&c)` | lets go of the slots from `slots` on; of all |

```odin
needle := ui.fuzzy_cache_needle(&app.search, query)
for it, i in items {
	if score, ranges, ok := ui.palette_match(needle, ui.palette_entry_cached(&app.search, i, it.title, "", it.tags)); ok { ... }
}
ui.fuzzy_cache_keep(&app.search, 3 * len(items))
```

The fold of a text goes 16 bytes at a time over its ASCII runs (`ascii.lower_run`) and a rune at a time past them, with
the same bytes as `unicode.to_lower`.

A program's settings go in its palette too: `prefs_page.palette_commands` and `prefs_page.show` (docs/prefs_page.md).

A key held, not pressed: `ui.key_held(key)` is true from its press in the window to its release, by the key's own
events (not by the modifiers' state, which a compositor may leave stale after one of its own shortcuts). A key pressed
before the window had the keyboard is not held, and none is once the user left the window. Ctrl, Shift and Alt are keys
there: a monitor stops its refresh while Ctrl is held alone.

`tests/commands` tests the texts, the keys, the keys held and the palette.
