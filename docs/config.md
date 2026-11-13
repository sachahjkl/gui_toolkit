# config: a typed preference registry (an about:config for any application)

`import "gt:config"` (or the relative path of the submodule). Pure Odin (`core:`, `base:runtime` and the toolkit's `ascii` and `fsx`), any target.
Every tunable is a named, typed, documented preference, so an application never hides a setting behind a magic constant.

The package is named `tk_config` (the directory is `config`): an application that keeps a thin `config` alias package of its
own needs the two names to differ, because Odin package names are unique within a build. With no such alias,
`import "gt:config"` binds it as `config` all the same.

## A preference

A subsystem declares its preferences next to the code that uses them, as a table of `Def`:

```odin
DEFS := [?]config.Def{
    {name = "net.max_connections", description = "Connections per host.", kind = .Int,
        default = {i = 6}, bounded = true, min = 1, max = 64},
    {name = "net.max_body", description = "Largest response kept.", kind = .Int,
        default = {i = 256 << 20}, bytes = true, unit = "bytes", bounded = true, min = 0, max = 1 << 40},
    {name = "ui.theme", description = "Colour scheme.", kind = .String,
        default = {s = "auto"}, choices = {"auto", "dark", "light"}, restart = true},
}
```

A `Def` carries its dotted lower-case `name` (its segments but the last are its groups: see below), a `description` (a
settings UI shows its first sentence and folds the rest), a `kind` (`.Bool / .Int / .Float / .String`), a `default`,
optional `bounded` bounds, a `choices` list for strings, a `unit` ("ms", "bytes"), `bytes` (an int that accepts
`K`/`M`/`G` when typed) and `restart` (takes effect at the next start). Its `tags` are other words a search finds it by,
that its name, title and description do not say ("colours", "dark" for a theme).

### Advanced and hidden

- `advanced`: a technical setting. A settings page shows it, folded under an "Advanced" part of its group. A search finds
  it as any other, and nothing blocks a change to it.
- `hidden`: the program's state, not a setting (a layout, a last choice). It is kept, read and saved as the others, but no
  settings page shows it, `groups_of` does not count it, and the JSON, TOML and INI exports leave it out.

## The registry

```odin
p := config.prefs_make();  defer config.prefs_destroy(&p)
config.register(&p, DEFS[:])                      // idempotent; a second kind for a name is a programming error

r := config.ref_of(&p, "net.max_connections")     // resolve once, read on hot paths
n := config.get_int(&p, r)                         // get_bool / get_float / get_string
n = config.int_of(&p, "net.max_connections")       // by name, for rare reads
```

Reads never hash a string on a hot path: resolve a `Ref` once, or copy the values into a plain struct and refresh it from
an observer. An unknown name or a kind mismatch is a programming error (it asserts).

## Layers

A value comes from one of four layers, lowest to highest: `Default < User < Command_Line < Policy`. A higher layer wins
for the run; a policy value also **locks** the preference (`is_locked`: the user cannot change it, and `reset` changes
nothing). Setting a lower layer while a higher one owns the preference is refused with `.Locked`, but the user's own value is
still kept for the profile file. `.Default` is no layer to set: it always answers `.Locked`, or `.Unknown`.

```odin
err := config.set_from_string(&p, "net.max_connections", "12", .User)   // full validation; Set_Error
config.set_int(&p, r, 12)                                                 // by Ref, .User by default
rest, errors := config.apply_args(&p, os.args[1:])                        // --pref name=value (returns the rest)
config.load_file(&p, policy_path, .Policy)                                // an enterprise policy file
config.reset(&p, "net.max_connections")                                   // back to the default (user layer only)
```

## Persistence (user changes only, atomically)

```odin
text := config.export_own(&p)                // the user-set values only, as the file's text (on the loop: it reads the registry)
written = p.user_version                     // the version this text has
config.write_user_file(profile_path, text)   // atomic and flushed (fsx.write_atomic); any thread: it reads no registry state
config.load_file(&p, profile_path, .User)    // missing file = no changes
config.save_user(&p, profile_path)           // export_own then write_user_file, on the calling thread
```

A program writes its file off its loop with a `User_Writer`: a disk write there froze the window at each change.

```odin
config.user_writer_start(&writer, &p, profile_path)   // after the file was read: it has what p holds
config.user_writer_save(&writer, &p)                  // once per round of the loop: serializes when user_version moved,
                                                      // the writer's thread writes; a newer text replaces one not written
if config.user_writer_failed(&writer) { ... }         // a write failed (told once); the next change tries again
config.user_writer_stop(&writer, &p)                  // at the end: the last changes written, the thread joined
```

A value read before its definition is registered (the profile file and the command line are read early) is remembered per
layer and applied when `register` arrives, and survives a round trip even if no definition ever registers it. A user's value
the definition refuses, in `register` (which counts them) or in `load_file` (a problem), leaves the default in place and stays
in the profile: another version may take it.

`p.user_version` counts the changes of the user's layer: a change under a higher layer counts, reading a file does not. A
program keeps the version it last serialized and saves when `p.user_version` differs; a change made while a worker writes the
file moves it again, so the next save has it. If a write fails, the program forgets the version it recorded, so the next save
tries again.

## Observers (apply without a restart)

```odin
id := config.watch(&p, "net.", proc(user: rawptr, name: string, p: ^config.Prefs) { /* reload */ }, user)
config.unwatch(&p, id)
```

`fn` runs synchronously, on the changing thread, after any preference whose name starts with `prefix` changes.

## Groups and their titles

The name is the one source of where a preference goes. Its segments but the last are its groups, from the top:
`appearance.text.gamma` is in the group `appearance`, and in it the group `appearance.text`. A name of one segment is in
no group. The program and the toolkit fill a table of the titles of the groups; a group with no title gets one made from
its last segment.

```odin
path := config.path_of("appearance.text.gamma")          // {"appearance", "appearance.text"} (slices of the name)
config.title_register(&p, "appearance", "Appearance", order = -1)
config.title_register(&p, "appearance.text", "Text and fonts")
config.group_title(&p, "appearance.text")                // "Text and fonts"
config.group_title(&p, "devtools")                       // "DevTools" (no title registered)
top   := config.groups_of(&p)                            // the top groups, in their order
inner := config.groups_of(&p, "appearance")              // the groups in "appearance"
```

- `title_register(p, path, title, order := 0)`: a second call for the same path replaces the first, so a program that
  registers after the toolkit gives its own words.
- `groups_of(p, parent := "", allocator)`: the groups directly in `parent` that hold a preference that is not hidden.
  They are sorted by `order` (lower first), then by the registration of their first preference.

## Titles, summary and search (for a settings UI)

```odin
title := config.title_of(d)                    // "network.http.max_connections" -> "Max connections"
summary, more := config.summary_of(d.description)
if config.matches(&p, d, query) { ... }        // every word of the query in the name, title, description, tags or group titles
```

`title_of` reads the last segment of the name only: its groups are headings (`group_title`). It drops a trailing unit
word ("debounce_ms" -> "Debounce") and the "enabled" of a switch. `Def.title` gives the words a settings page shows when
the name does not make them ("Read a QR code", "Start with the session"); empty, `title_of` makes them from the name.

### A search over pages

A settings dialog made of pages shows, while a query is typed, the matching preferences of every page under their page's
title. `Search` says what shows; the dialog keeps its own layout and draws:

```odin
config.search_begin(&s, field_text)               // "": no search
for page in pages {
    config.search_page(&s, page.title)            // a title with every word of the query: the whole page shows
    for name in page.names {
        show, heading := config.search_shows(&s, &prefs, name)
        if heading != "" { draw_heading(heading) } // before the page's first match, once
        if show { draw_row(name) }
    }
}
if config.searching(&s) && s.found == 0 { draw_nothing_matches() }
```

## Snapshots (reset to a known state)

```odin
s := config.snapshot(&p)                         // every preference and the layer that decides it
defer config.snapshot_destroy(s)
changed := config.restore(&p, s)                 // put them all back (policy values untouched)
```

## File format

`export_own` writes one tag line (`wbprefs 1`) then `name<TAB>value` sorted by name, with `\\`, `\n`, `\r`, `\t` escapes. A
float is written in the fewest digits that read back as the same value. `load_file` wants the tag of the layer it reads,
`wbpolicy 1` for `.Policy` and `wbprefs 1` otherwise, and skips `#` comments and a leading byte-order mark. The tags are kept
as they are so files an existing application already wrote stay readable. `export_own` writes what it knows, so a comment
or a line that is no `name<TAB>value` does not survive it.

## Export

```odin
own  := config.export_own(&p)                  // our format: what the profile file holds; load_file reads it back
own   = config.export_own(&p, all = true)      // every value of this run, in our format
json := config.export_json(&p)                 // {"appearance.theme": "dark"}
toml := config.export_toml(&p)                 // [appearance] theme = "dark", [appearance.text] gamma = 1.8
ini  := config.export_ini(&p)                  // [appearance] theme=dark
```

Each exporter takes `(p: ^Prefs, all := false, allocator := context.allocator) -> string`.

- `all = false`: the user's layer only, which is what differs from the defaults. A user value under a command line or
  policy value is in it. `all = true`: every preference, with the value it has for this run.
- JSON, TOML and INI hold the settings: a hidden preference is not in them. A user value that no definition registers or
  accepts in this run has no type, and is not in them either. `export_own` holds all of these, so a round trip loses
  nothing.
- These files are written only. The registry reads no JSON, TOML or INI.

The formats:

- JSON: one flat object sorted by name, as the `settings.json` of Zed or VS Code. A string has the escapes of RFC 8259
  (`\"`, `\\`, the control characters). An int is an integer. A float always has a decimal point or an exponent, in the
  fewest digits that read back as the same value.
- TOML: a table per group, a key per preference (its last segment); a name of one segment goes before the first table. A
  key that is no bare key is quoted. A name that is also a group's path (`browser.tabs` beside `browser.tabs.width`) cannot
  be a key and a table at once: it goes before the first table under its whole quoted name (`"browser.tabs" = true`).
  Strings are basic strings, with DEL and the control characters escaped.
- INI: a section per group, `key=value` per preference. A string is written as it is, or between double quotes with the
  escapes of JSON when a reader would not read it back as it is (a space at an end, a control character, `"`, `\`, `;`,
  `#`).
