# store: small files of keys and values

`import store "gt:store"` (the package is `tk_store`). Pure Odin (`core:` and the toolkit's `fsx`), any target.

A program remembers small things outside its preferences: the last session, the server chosen, what a list ranks first, a
zoom per item. Each is a file of lines. `store` reads such a file once, keeps it in memory, and writes it later on a thread
of its own, atomically. The interface's thread never waits on the disk, and a crash never leaves a part of a file.

Preferences with a type, bounds and a settings page are `config`'s ([config.md](config.md)); `store` is for the rest.

## A store

```odin
s: store.Store
store.open(&s, path, '=')                  // reads the file; its worker starts
value, ok := store.get(&s, "server")       // a copy (temporary allocator by default)
store.set(&s, "server", "Home")            // in memory; the file follows
store.remove(&s, "server")
for e in store.list(&s) { use(e.key, e.value) }
store.flush(&s)                            // the end of the program: on the disk when it returns
store.close(&s)                            // flushes, ends the worker, frees
```

| Procedure | |
|---|---|
| `open(s, path, separator = '\t', wait_ms = WAIT_MS, most_ms = MOST_MS, private = false, on_failed = nil, user = nil, allocator) -> (loaded: bool)` | reads `path` on the calling thread; false: no file (the store starts empty) |
| `get(s, key, allocator = context.temp_allocator) -> (string, bool)` | a copy of the value |
| `set(s, key, value) -> bool` | false: the line cannot hold them (below) |
| `remove(s, key)` | |
| `replace(s, entries: []Entry)` | every entry at once, in that order (a list rewritten whole) |
| `list(s, allocator)`, `keys(s, allocator)`, `count(s)` | copies, in the file's order |
| `flush(s)` | writes what changed now and waits for it |
| `close(s)` | flushes, ends the worker; the store is zero after |

Every procedure can be called from any thread: the entries are behind a mutex, and `get`, `list` and `keys` return copies.

A zero `Store` is in memory only (no path, no worker): a test's, or a program run without a profile.

## When it reads, when it writes

`open` reads on the calling thread. Call it at the program's start, before the window and its loop: the first frame needs
these values (which server to connect, which session to show), the files are small, and no frame is waiting yet.

`set`, `remove` and `replace` change memory only, then wake the worker. The worker writes the file once the changes rest
for `wait_ms` (default `WAIT_MS`, 1 s), and at most `most_ms` (default `MOST_MS`, 5 s) after the first change that is
not written: a value that changes without end still reaches the disk. A `set` of the value already there changes nothing.

The worker takes the whole content under the mutex, then writes it without the mutex: a `set` never waits on the disk. It
writes through `fsx.write_atomic` with `flush`: a temporary file beside the file, synced, renamed over it. It makes the
file's folder first, so the first start needs no folder. `private` creates the file readable by its user only (a file
that holds a password, even sealed: [fsx.md](fsx.md)).

`on_failed(user, path)` runs on the worker after a write that failed. A program posts it to its interface
(`ui.post`, [post.md](post.md)) to say so. The changes stay in memory, and the next change writes them again.

## The file

One entry per line: `key<separator>value`, then `\n`, in the order the keys were first set. The key ends at the first
separator, so a value can hold the separator (`name\turl\tpassword`: the key `name`, the value `url\tpassword`).
There are no escapes, so the files a program wrote by hand before load as they are. A key cannot be empty, cannot hold
the separator or a line break, and a value cannot hold a line break: `set` refuses them.

When it reads, `open` drops a leading byte-order mark and the `\r` of a CRLF line. It skips a line with no separator, or
whose key was seen already (the first one stays).

## A Writer: a file the program formats

A file that is no list of lines (JSON, several lines per entry) has the same worker through a `Writer`. The program hands
it the whole content.

```odin
w: store.Writer
store.writer_open(&w, path)                // nothing is read; wait_ms 0: written at once, on the worker
store.writer_put(&w, data)                 // copied; the last content put is the one written
store.writer_flush(&w)
store.writer_close(&w)
```

`writer_open` takes the same `wait_ms`, `most_ms`, `private` and `on_failed` as `open`.
