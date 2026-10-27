# fsx: file helpers with the guarantees a store relies on

`import "gui_toolkit/fsx"` (or the relative path of the submodule). The whole-file and positional file operations a
persistent store needs, with the durability and concurrency guarantees it relies on, on every system
(`fsx_windows.odin`, `fsx_unix.odin`), plus the directory helpers an application needs to manage its own files.

The interface is platform-neutral: paths are plain strings, data is `[]byte`, a directory entry is `Dir_File`, a path's
kind is the opaque `Path_Kind`, and a file's modification time is an opaque `i64` stamp that is only ever compared to
another stamp. No Windows or POSIX type crosses the boundary, so another platform plugs in under `fsx_<os>.odin` without
touching the callers.

## Whole files

```odin
data, ok := fsx.read_all(path)                   // the whole file, false when larger than max_size (default 1 TiB)
ok = fsx.write_atomic(path, data)                // through path.tmp renamed over path: a reader sees old or new, never half
ok = fsx.write_atomic(path, data, flush = true)  // flush: on the disk when it returns
```

`write_atomic` is how a store replaces a file without a reader ever seeing a torn write: it writes `path.tmp` in full,
then renames it over `path` (`replace`, atomic on both systems). A reader that opened the old file keeps reading it;
a reader that opens after the rename sees the new one.

## Pieces of a file

```odin
n, ok := fsx.read_at(path, offset, buf)          // up to len(buf) bytes from offset; short at end of file
size, stamp, ok := fsx.stat(path)                // size and an opaque modification stamp (compare to a kept one)
ok = fsx.write_parts(path, parts[:], flush)      // create/truncate, write the slices one after the other
ok = fsx.replace(from, to, durable)              // rename from over to atomically; durable: on the disk when it returns
ok = fsx.delete_file(path)                        // true when the file is gone (including: was already absent)
```

`read_at` opens the file sharing read, write and delete (Windows) or by offset (`pread`, POSIX), so a reader never
blocks a writer's rename or a deletion: a file being replaced underneath is read as it was.

## Directories

```odin
fsx.make_dirs(dir)                                // the directory and every missing parent
files := fsx.list_files(dir)                      // the plain files (no subdirectory, no link to one): name and size
kind := fsx.path_kind(path)                       // .Absent / .File / .Directory / .Link (links never followed)
ok := fsx.remove_tree(path)                        // a file, or a directory with everything in it, one entry at a time
dir := fsx.temp_dir()                              // TEMP when set, else the system's (GetTempPathW / TMPDIR / /tmp)
```

`remove_tree` deletes a directory one entry at a time rather than through `os.remove_all`, which asks the Windows shell
(`SHFileOperationW`) for a non-empty directory: the shell is not thread-safe (tests running side by side are not) and
does not survive being called from a process under AddressSanitizer. A junction or symbolic link to a directory is a
`.Link`, so `remove_tree` removes the link and leaves its target alone.

`temp_dir` reads `TEMP` first: a test harness points it at a throwaway folder (on every system) so that tests do not
leave files in the real temporary directory.
