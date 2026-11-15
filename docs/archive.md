# archive: what a zip or a tar holds

`import archive "gt:archive"` (the package is named `tk_archive`). It reads zips and tars and writes zips; pure Odin (the toolkit's `flate` for the
compressed parts), any target. A file manager shows an archive as a folder with it; a program takes one file out of a
download with it.

```odin
idx, err := archive.open("/home/me/photos.zip")      // .zip, .tar, .tar.gz, .tgz (by the name: kind_of)
if err != .None { ... }
defer archive.index_destroy(&idx)

list: [dynamic]archive.Entry
archive.children(&idx, "2024/june", &list)            // right under a folder of it ("": its top)
data, rerr := archive.read(&idx, "2024/june/a.jpg", limit = 64 << 20)
xerr := archive.extract(&idx, "2024/june/a.jpg", "/tmp/a.jpg")
```

| | |
|---|---|
| `open(path)` | the index: every `Entry` (`name`, `dir`, `size`, `packed`, `mtime` in nanoseconds since 1970 UTC) |
| `children(idx, dir, out)` | the entries right under `dir`; a folder the archive names only through its files is made up once |
| `find(idx, name)` | the entry of that name, or nil |
| `read(idx, name, limit)` | a file of it, whole; `Too_Large` past `limit` |
| `extract(idx, name, out)` | a file of it written to `out`, its folders made; a name with `..` or a drive is refused (`Unsafe_Name`) |

Names inside are `/`-separated, without a leading or a trailing `/` (a `\` of a zip made on Windows becomes `/`). An entry
whose name has a `.` or `..` part, or a drive (`C:`), is left out of the index: a malicious archive lists nothing that a
copy out of it could follow out of its folder. `find` is one look (`Index.by_name`).

## How it reads

- **zip**: from its end: the end of central directory record (within a comment's 64 KiB), then the central directory,
  ZIP64's record and extra fields when a size, an offset or the count does not fit 32 bits. Opening a large zip reads a
  few kilobytes. A file is read at its local header: stored, or deflate (`flate`, `.Raw`); an encrypted one, or another
  method, is `Unsupported`. A zip's dates are its DOS times, taken as UTC.
- **tar**: header by header (ustar's prefix, GNU's long names, pax's `path`), its checksum checked; a gzipped one is
  inflated on the way, 256 KiB at a time, its data skipped. Each `open` and each `read` of a gzipped tar goes through it
  from its start (a gzip stream cannot be entered elsewhere).

## Writing a zip, alone or after a program

The package also writes zips, file by file. The writer can start after the bytes of another file, an executable: the
offsets it records are the file's own, so the whole file opens as a zip, and a program reads the files it carries.
A self-installing bundle ships many programs as one download that way (atelier's).

```odin
w: archive.Zip_Writer
archive.zip_begin(&w, "build/bundle", after = "build/host")    // the host's bytes first ("": a zip alone)
archive.zip_add(&w, "papier/papier", data, mode = 0o755)       // deflated, or stored when that is smaller
if err := archive.zip_end(&w); err != .None { ... }            // the first error of the whole writing

// in the program that carries it
idx, err := archive.open_as(process.executable_path(), .Zip)  // open_as: whatever the file's name
```

| | |
|---|---|
| `zip_begin(w, path, after)` | makes or empties `path`; `after`: a file copied first, as it is |
| `zip_add(w, name, data, mode)` | a file; `mode`: its Unix permissions, kept in the zip as Info-ZIP keeps them |
| `zip_end(w)` | the central directory and its end, the file closed; returns the first error of the writing |
| `open_as(path, kind)` | `open` without the name's guess |

An error stops the writing: every later call does nothing and `zip_end` returns it. A name that would leave its folder
is `Unsafe_Name`. Sizes and offsets stay under 4 GiB (no ZIP64 is written): past that, `Too_Large`. Names are written
as UTF-8 (bit 11).

Errors: `Unreadable`, `Not_An_Archive`, `Bad_Data`, `Unsupported`, `Not_Found`, `Too_Large`, `Unsafe_Name`.
`tests/archive` builds its zips and tars byte by byte.
