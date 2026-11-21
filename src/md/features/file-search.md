# File search

`gt:filesearch` finds a file by its name as the person types, in the folders they work in, the files they open most
coming first. classeur searches a folder and what is under it with it; the palette gets a source of files; a launcher
(ROADMAP.md) gets files for nothing. Content search (grep) comes after names, on the same index.

Status: designed, not built. Two measures come before any code (below).

## The engine: fff

[fff](https://github.com/dmtrKovalenko/fff) (MIT, Dmitriy Kovalenko) is the search library opencode and nushell use. It
keeps one index per tree in memory, filled by a scan on threads of its own and kept true by a watcher; a search answers
in milliseconds from warm memory. Its matching survives typos and dropped letters ("shcema" finds "schema"), ranks by
how often and how lately a file was opened (frecency, kept in LMDB), knows git status, and searches contents (literal,
regex, fuzzy). It already uses each system's fast path to read folders (getdents64 on Linux, NTFS's API on Windows).

Written ourselves, the same would be months for less: the rule is an established library where one exists.

## Decisions

- **A crate in the toolkit's native library, not fff's C library.** `native/filesearch` depends on the `fff-search` crate
  and gives the C ABI the Odin package calls, as `native/pdf` does for hayro; it is the `filesearch` feature of
  `gt_native`. fff's own `libfff_c` would be a second static library with a second copy of Rust's standard library
  (the reason `gt_native` is one library). fff's `zlob` feature (it needs Zig) is left off: a toolchain more for a few
  percent.
- **One API, a backend per system** (the toolkit's rule: no common ground that is slow on every system):
  - **Linux**: fff, its watcher on inotify. The trees are the home folder and the folders a program opens, not `/`:
    inotify watches one directory per watch, and `max_user_watches` bounds them (8 192 on older kernels; since
    Linux 5.11 it scales with the memory, up to 1 048 576). Past the bound, the tree is searched as last scanned and rescanned on a timer, and the
    program says so.
  - **Windows**: fff for the trees, as on Linux. A whole-disk index read from NTFS's master file table and kept by its
    change journal (what Everything does) needs a privileged reader, a service: it is a decision of its own
    (ROADMAP.md, Maybe), not this one.
  - **macOS**: fff, its watcher on FSEvents. Spotlight's index (`mdquery`) already covers a disk and is free; it is the
    first thing to measure there, against fff, when the toolkit runs on macOS.
- **Never on the interface's thread.** Opening an index starts its scan on fff's threads; a search runs on a chore
  (`ui.task`) and its page of results comes back to the build that asked, the older answers dropped (as the palette's
  sources). The interface reads a result as it reads any other answer.
- **Names first, contents later.** The content index costs some 360 bytes a file; on a home of half a million files
  that is 180 MB for a feature no program asks for yet. It is off until one does, and then backed by a mapped file.
- **One frecency for the person, not one per program.** The LMDB database lives in the vendor's data folder
  (`<data>/FromentSoftware/filesearch`), shared: a file opened in classeur comes first in the launcher. LMDB is made
  for several processes reading and writing one database.
- **A program says what it opened** (`note_opened`): fff cannot see a file open in another program, and the system's
  "recent files" are a different list on each system.

## The API, as planned

```odin
idx := filesearch.open({roots = {home}, watch = true})       // the scan starts on fff's threads
filesearch.search(idx, "shcema", {limit = 50}, on_page, user) // on a chore; on_page on the interface's thread
filesearch.note_opened(idx, path)                            // frecency
filesearch.close(idx)
```

A result: its path, its name's match ranges (to draw them), file or folder, its score. State: scanning (with the
count so far), ready, watching or rescanning on a timer, failed with its reason.

## Before any code: two measures

1. **Memory and scan time on a real home** (the author's: its file count, the resident memory once indexed, the time
   of a first scan cold and warm), on Linux and on Windows.
2. **The watcher's cost and bound** on Linux: the watches a home takes, against `max_user_watches`.

If the memory of a whole home is too much, the trees narrow to the folders a program opens, with the home's top
levels only.

## Refused

- **An index of our own** (a walk, a trie, a watcher): what fff does, done again worse.
- **The lowest common ground** (a plain recursive walk on every system, searched each time): slow everywhere.
- **`libfff_c` as it ships**: a second copy of Rust's standard library beside `gt_native`.
- **A whole-disk index on Linux**: no master file table to read; a scan of `/` and a watch on every folder do not
  hold on a desktop.
- **A frecency per program**: the launcher would not know what classeur opened.
