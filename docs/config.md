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

A `Def` carries its dotted lower-case `name`, a `description` (a settings UI shows its first sentence and folds the rest),
a `kind` (`.Bool / .Int / .Float / .String`), a `default`, optional `bounded` bounds, a `choices` list for strings, a
`unit` ("ms", "bytes"), `bytes` (an int that accepts `K`/`M`/`G` when typed), `restart` (takes effect at the next start)
and a `category` (defaults to the first name segment). A `hidden` preference is the program's own (a layout, a last
choice): it is kept and read as the others, but no settings page shows it, nor anything that lists the settings.

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
config.save_user(&p, profile_path)        // writes only user-set values; atomic and flushed (fsx.write_atomic)
config.load_file(&p, profile_path, .User) // missing file = no changes
```

A value read before its definition is registered (the profile file and the command line are read early) is remembered per
layer and applied when `register` arrives, and survives a round trip even if no definition ever registers it. A user's value
the definition refuses, in `register` (which counts them) or in `load_file` (a problem), leaves the default in place and stays
in the profile: another version may take it.

`p.dirty` says the user's layer differs from what was last read or saved: a change under a higher layer counts, reading a file does not.

## Observers (apply without a restart)

```odin
id := config.watch(&p, "net.", proc(user: rawptr, name: string, p: ^config.Prefs) { /* reload */ }, user)
config.unwatch(&p, id)
```

`fn` runs synchronously, on the changing thread, after any preference whose name starts with `prefix` changes.

## Titles, summary and search (for a settings UI)

```odin
title := config.title_of(d)                    // "net.http.max_connections" -> "HTTP max connections"
head  := config.category_title("devtools")      // "DevTools"
summary, more := config.summary_of(d.description)
if config.matches(d, query) { ... }             // every word of the query in the name, title or description
```

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

`save_user` writes one tag line (`wbprefs 1`) then `name<TAB>value` with `\\`, `\n`, `\r`, `\t` escapes. `load_file` wants the
tag of the layer it reads, `wbpolicy 1` for `.Policy` and `wbprefs 1` otherwise, and skips `#` comments and a leading byte-order
mark. The tags are kept as they are so files an existing application already wrote stay readable. `save_user` writes what it
knows, so a comment or a line that is no `name<TAB>value` does not survive it.
