# fsx: file helpers

`import "gt:fsx"` (or the relative path of the submodule). For programs that keep data on disk: replacing a file atomically,
reading part of a file while another thread replaces it, and managing directories, the same on Windows and POSIX
(`fsx_windows.odin`, `fsx_unix.odin`).

The interface is platform-neutral: paths are plain strings, data is `[]byte`, a directory entry is `Dir_File`, a path's
kind is the opaque `Path_Kind`, and a file's modification time is an opaque `i64` stamp that is only ever compared to
another stamp. No Windows or POSIX type crosses the boundary, so another platform plugs in under `fsx_<os>.odin` without
touching the callers.

## Whole files

```odin
data, ok := fsx.read_all(path)                   // the whole file, false when larger than max_size (default 1 TiB)
ok = fsx.write_atomic(path, data)                // through a temporary file renamed over path: a reader sees old or new, never half
ok = fsx.write_atomic(path, data, flush = true)  // flush: on the disk when it returns
ok = fsx.write_atomic(path, data, private = true) // readable by its user only (POSIX: 0600, from its creation)
```

`private` is for a file that holds a secret (a password, even sealed): on POSIX the temporary file is created with mode
`0600`, so no other user can open it at any moment. On Windows a file takes its folder's access list, and a program's
folder under the user's profile is that user's already: it asks nothing more.

`write_atomic` is how a store replaces a file without a reader ever seeing a torn write: it writes
`<path>.<pid>.<thread>.tmp` in full, then renames it over `path` (`replace`, atomic on both systems). A reader that opened the
old file keeps reading it; a reader that opens after the rename sees the new one. Two writers each write their own
temporary file, and the last rename stays. A failed write removes its temporary file; a crash leaves it behind.
On Windows a reader that opened `path` without sharing its deletion (another program, an antivirus, the indexer) makes
the rename fail while it holds the file: `replace` tries again six times, 5 ms more apart each time (75 ms at most),
before the write returns false.

`read_all` reads between two `stat`s that agree, and tries again when they do not: a file replaced meanwhile comes back
whole, the old or the new one, or not at all after a few tries.

## A file written in parts

```odin
w: fsx.Writer
if !fsx.writer_open(&w, path) { return }          // <path>.<pid>.<id>.part, beside path
for chunk in chunks {
	if !fsx.writer_append(&w, chunk) { break }      // false: the write failed; the commit refuses
}
ok := fsx.writer_commit(&w, flush = true)         // renamed over path (replace); false: path as it was, the part gone
fsx.writer_abort(&w)                              // instead of the commit: the part removed, path as it was
```

`Writer` is for a file whose content comes in parts over time (a download, `http.receive`): the target keeps its old
content, or stays absent, until the whole new one is there. The temporary file is in the target's folder, so the
rename never crosses a disk; its name ends with `.part`, which tells a person who finds it after a crash what it is.

- `writer_open(&w, target, private)`: false when the file cannot be made (a missing or refused folder). `private` is
  `write_atomic`'s.
- `writer_append(&w, bytes)`: at the end, all of it. After a failure every append and the commit return false.
  `w.written` counts the bytes appended.
- `writer_commit(&w, flush)`: closes the file and renames it over the target (`replace`, its tries on Windows). Its
  answer is false when an append failed, the close failed or the rename failed; the part is removed then.
- `writer_abort(&w)`: closes and removes the part. It does nothing for a writer that holds nothing, so a program may
  call it at the end of every path (after a commit too).
- One thread uses a writer at a time. Every call blocks on the disk: call them off the interface's thread.
- Another thread may remove the part (`delete_file(w.temp)`) while the writer holds it open, at the program's end for
  example: the remove succeeds on every system, and the file goes when the writer closes it.

## Pieces of a file

```odin
n, ok := fsx.read_at(path, offset, buf)          // up to len(buf) bytes from offset; short at end of file
size, stamp, ok := fsx.stat(path)                // size and an opaque modification stamp (compare to a kept one)
ok = fsx.write_parts(path, parts[:], flush)      // create/truncate, write the slices one after the other (private as above)
ok = fsx.replace(from, to, durable)              // rename from over to atomically; durable: on the disk when it returns,
                                                 // and false may mean renamed, but the directory could not be synced
ok = fsx.delete_file(path)                        // true when the file is gone (including: was already absent)
```

`read_at` opens the file sharing read, write and delete (Windows) or by offset (`pread`, POSIX), so a reader never
blocks a writer's rename or a deletion: a file being replaced underneath is read as it was.

## Directories

```odin
fsx.make_dirs(dir)                                // the directory and every missing parent
ok := fsx.private_dir(dir)                        // the same, the directory its user's alone (false: another's, a link)
files := fsx.list_files(dir)                      // the plain files (no subdirectory, no link to one): name and size
kind := fsx.path_kind(path)                       // .Absent / .File / .Directory / .Link (links never followed)
target, size := fsx.stat_follow(path)             // .Absent / .File / .Directory and a file's size (links followed, no allocation)
entries, err := fsx.read_folder(dir)               // every entry: name, size, modified, kind, hidden (os.Error on failure)
fsx.folder_entries_delete(entries)                 // frees them (same allocator)
ok := fsx.remove_tree(path)                        // a file, or a directory with everything in it, one entry at a time
dir := fsx.temp_dir()                              // TEMP when set, else the system's (GetTempPathW / TMPDIR / /tmp)
```

`read_folder` gives a `Folder_Entry` per entry ("." and ".." left out): `name` (no path), `size` (a file's; 0 for a
folder), `modified` (Unix milliseconds, 0: unknown), `kind` (`.File`, `.Directory`, `.Link`: a symbolic link or a
junction, not followed) and `hidden`, the system's mark. On Windows `hidden` is the `FILE_ATTRIBUTE_HIDDEN` attribute,
read from `FindFirstFileW` / `FindNextFileW` with the rest: no call per entry (`core:os` opens each entry and drops the
attribute). Elsewhere it is a name that starts with ".". Its error is `core:os`'s: `io.Error.Permission_Denied`,
`os.General_Error.Not_Exist`, or the system's code. It blocks: call it off the interface's thread.

`private_dir` is for a folder in a place that other users share (`/tmp`). There, another user can make the name first,
and `make_dirs` would take that folder. `private_dir` makes the missing parents and the folder (mode 0700 on POSIX).
It returns true only when the path is a folder of this user that the others cannot enter.

- A folder of this user that is open to others is closed (0700).
- A folder of another user, or a link at the name, is refused (false).
- The checks are made on the opened folder (`O_NOFOLLOW`, `fstat`, `fchmod`). A name swapped between the check and the
  change is therefore never followed.
- On Windows a new folder takes its parent's access list, and a junction or a link at the name is refused.

`platform.user_dir(.Runtime, ...)` uses it for its Linux fallback, so a program's runtime folder needs no check of its
own. It blocks: call it off the interface's thread.

`remove_tree` deletes a directory one entry at a time rather than through `os.remove_all`, which asks the Windows shell
(`SHFileOperationW`) for a non-empty directory: the shell is not thread-safe (tests running side by side are not) and
does not survive being called from a process under AddressSanitizer. A junction or symbolic link to a directory is a
`.Link`, so `remove_tree` removes the link and leaves its target alone.

`temp_dir` reads `TEMP` first: a test harness points it at a throwaway folder (on every system) so that tests do not
leave files in the real temporary directory.

## A lock between processes

```odin
lock, got := fsx.file_lock(path, 10 * time.Second)   // Locked, Busy (another holds it at the end of the wait), Failed
defer fsx.file_unlock(&lock)                         // a lock not held: nothing
```

One process at a time holds the lock of `path`; the file is made when it is not there, and it stays. Linux takes
`flock` on the open file, so two opens in one process exclude each other too; Windows takes `LockFileEx` on its first
byte. The system lets go when the process ends, crashed or not. The wait tries again every `LOCK_POLL` (50 ms); 0 is one
try. Other systems take no lock: `Locked` at once. It waits on the system: call it from a task, or at a start before any
window. `setup.adopt_earlier` holds one while it moves a program's folders.

## Folders followed

```odin
w: fsx.Watch                                      // zero: not opened; its memory is the heap's
fsx.watch_set(&w, folders)                         // the folders to follow from now on (any thread; kept before watch_open)
ok := fsx.watch_open(&w)                           // false: no watcher on this system (macOS), or the system refused
changed, closed := fsx.watch_wait(&w)              // the waiting thread: the folders that changed, or closed
fsx.watch_stop(&w)                                 // any thread: the wait returns closed = true
fsx.watch_close(&w)                                // once the waiting thread ended
```

One thread loops on `watch_wait` until it returns `closed`. Each return names the folders that changed, as
`watch_set` gave them. Changes close together come as one: after the first, the wait goes on until none came for
`WATCH_QUIET_MS` (120 ms), at most `WATCH_MAX_MS` (600 ms) after the first. `watch_open` can run on the waiting thread
itself: the system is then never called from the interface's thread.

A folder is followed, not its subfolders: its entries made, removed, renamed, written, and their attributes. To follow a
file, follow its folder and compare the file's `stat`. Linux uses inotify; Windows a change notification per folder
(63 folders at most). Elsewhere `watch_open` fails, and `watch_wait` returns `closed`. The file picker follows its
folder with it ([file-browser.md](file-browser.md#sources)).

## Names

```odin
path := fsx.path_join(dir, name)                  // name in dir, by this system's separator (temp memory by default)
path = fsx.path_join(folder, name, source.sep)    // by a given one: a remote source's "\", or '/' for a site's relative paths
name := fsx.safe_file_name(order, "licence")      // the characters a system refuses become "_"; the fallback when empty
```

Both change text only: no system call, so the interface's thread may call them. `path_join` keeps a root whole ("/",
`C:\`), makes the separators that end `dir` one, and on a `\` path turns the `/` of `name` into `\` (a manifest's
relative names use `/` on every system); an empty `dir` gives `name`. `safe_file_name` replaces `/ \ : * ? " < > |`, the
control characters and DEL by `_`, and drops the spaces and dots at both ends (Windows drops the last ones without a
word); text past ASCII stays, so a person's name for a thing stays readable in a folder.
