# Folders followed: intent

A folder shown changes on screen when its files change. A copy, a download or another program adds a file: the list
shows it with no F5. `fsx.Watch` is the system's part, for any program. The file picker's local source follows the
folder each picker shows (`File_Source.watch`).

## Purpose

classeur had the only watcher of the suite. The file picker, feuille (a PDF changed on disk) and the toolkit's own
files (themes.txt, the preferences) need the same thing. One watcher in `gt:fsx` replaces the copies.

## Decisions

- **A thread waits; the caller says the folders.** `watch_wait` blocks until a change and returns the folders that
  changed. `watch_set` (any thread) replaces the set and wakes the wait, which applies it before it waits again. The
  system's calls (inotify, `FindFirstChangeNotificationW`) run on the waiting thread only.
- **A folder is told once its watch begins.** A caller reads a folder, then asks to follow it (the file tree follows
  the folders it shows), or asks first and reads on another thread (the picker): either way the system's watch is made
  later, on the waiting thread, and a change in between was lost. Told at the start of its watch, the folder is read
  again once, after the watch exists. The cost is one more reading per folder followed. Found on the Windows CI: a
  file made at once in a folder just opened never came.
- **A set keeps the watches of the folders still wanted.** Windows closed and opened every notification at each set: a
  change in a folder already followed, in that gap, was lost. A notification of a folder that is gone (or waits to go
  while the notification holds it) is closed and forgotten, as inotify's `IGNORED`: a folder made again at its path is
  watched again at the next set.
- **Close changes are one change.** After the first event, the wait goes on until none came for `WATCH_QUIET_MS`
  (120), at most `WATCH_MAX_MS` (600) after the first. A copy of a thousand files reads the folder a few times. 120 ms
  is under what a person notices; 600 ms bounds the delay under a steady stream.
- **A folder, not a file.** Windows' notifications take a folder. A program that follows one file watches its folder
  and compares the file's stamp (`fsx.stat`).
- **`watch_set` before `watch_open` is kept.** The waiting thread can then open the watch itself: a program's
  interface thread never calls the system for it. The wake is written only once the watch is open, under the lock
  (`watch_close` cannot free it between the test and the write).
- **The heap's memory.** The set is shared by two threads; a frame's or a test's allocator is not.
- **The picker follows through its source.** `File_Source.watch(src, path, reply)` follows one folder per picker;
  `file_reply_changed(reply)` says it changed, as often as it does. A server's source can push its own changes the same
  way. nil: no follow, F5 stays the way.
- **The follow is asked before the reading.** A change between the two is then told, not lost (the follow's ticket is
  the picker's `follow` counter; a change of an older follow is dropped).
- **A change marks the folder stale; the next build reads it again.** Not in the reply: it runs before the build, and a
  rename's field must not lose its row. Not while a reading is on its way (it is read again after it) nor while a name is
  edited. The reading is `F5`'s (`.Again`): the same folder keeps its entries until the answer, and the rows'
  identities (by name) keep the selection, the scroll and the active row.
- **One watch and one thread per State for the local source** (`File_Local_Watch`), started at the first follow. The
  thread gathers the folders told and posts one wake while none is queued: a busy folder never fills the State's queue.
- **ui.destroy does not join the thread.** A post on its way waits on a full queue that the interface's thread no
  longer drains. The memory is counted (the State's reference, the thread's); `watch_stop` ends the wait, the last
  reference frees it. A post after ui.destroy is refused by the State's `Task_Box`.

## Kept apart

- **`desktop.watch_start`** follows the fixed places of a program's integration (the applications folder, the install
  folder, the registry keys), and a place that does not exist yet through its nearest ancestor. It answers "read the
  state again", not "these folders changed". Its walk up the ancestors and the registry keys have no use for a folder
  shown; the folder watcher's set and grouping have none for it. Two small pieces, each with one job, cost less than one
  with modes.

## Refused

- **A poll on a timer.** It reads every folder shown every second, and still lags.
- **A watch of subfolders** (`IN_` on each, `bWatchSubtree`). A picker shows one folder; a recursive watch on a home
  folder uses thousands of inotify watches.
- **`ReadDirectoryChangesW` with the names changed.** The picker reads the folder again anyway; a name list adds a
  buffer to size and an overflow to handle, for nothing.

## Subtle points

- inotify gives one descriptor per inode: two paths to one folder share a watch. The last path set wins its reports.
- An overflow of inotify's queue reports every folder: what was lost is read again.
- A folder removed ends its watch (`IN_IGNORED`): its path is reported and forgotten, so a folder made again at that
  path is watched again at the next `watch_set`. Kept, the dead watch made `watch_set` think it watched it already.
- A report's paths are copies: a `watch_set` during the quiet time removes watches, and their paths, before the wait
  ends.
- Windows waits on 64 handles at most: the first 63 folders are watched (the 64th handle is the wake).
- macOS has no watcher yet: `watch_open` fails, and the picker reads a folder again only on F5.
- A file made before the waiting thread applied the folder is not told. The picker's follow is asked before the
  reading, so its listing sees such a file. A test makes files until one is told.
