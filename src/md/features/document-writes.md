# A person's document written whole

`fsx.write_atomic` replaces a file through a temporary file renamed over it. For a program's own files that is enough.
A person's document asks more: plume, galerie and feuille each wrote their own save, and each lost something.

## What a rename loses

A rename puts a new file at the name. The new file is the writer's: on POSIX its mode is the umask's, its owner and group
the writer's; on Windows `MoveFileExW` gives it the temporary file's attributes and its folder's access list. A symbolic
link at the name is replaced by a plain file. The other names of a hard-linked file keep the old content.

## The options

One `Write_Options` value, not one procedure per use: `flush`, `private`, `keep`, `follow`. `DOCUMENT` is the set an
editor's save needs. The zero value stays a program's own file, as `write_atomic` wrote before.

- `keep` on POSIX: `fchown` then `fchmod` on the open temporary file, before the rename. The owner first: a change of
  owner clears the set-user-ID bits that the mode then gives back. An owner this user may not give is refused by the
  system: the group alone is given, and the file becomes this user's (as any editor leaves it). `Write_Report.kept`
  says so.
- The temporary file is made new (`O_EXCL`, `O_NOFOLLOW`, after a leftover of a crash is removed): a file left at its
  name keeps its mode through `O_TRUNC`, and a link planted there would be written through.
- The temporary file is `0600` from its creation when `keep` or `private` asks: a document of mode `0600` is never
  readable wider while it is written. A new file (nothing written over) gets the mode of a new file.
- `keep` on Windows: `ReplaceFileW`, which keeps the replaced file's access list, attributes, creation time, short name
  and object id. It has no write-through: with `flush` the data is flushed in the temporary file, and the file is opened and flushed
  after for its name. That open needs write access, which a file this user may replace (the folder's right) may not
  give: the save is done all the same, `write_atomic` is true, and `Write_Report.flushed` is false. Refused: false for
  a replace that happened, which tells a person the save failed when it did not. When it cannot move the new
  file into place (`ERROR_UNABLE_TO_MOVE_REPLACEMENT`, `_2`), the name is free or still the old file: the plain rename
  is done, and `kept` is false. A sharing violation is tried again as `replace` does.
- `follow`: the chain is read by name (`path_kind`, `read_link`), a relative link from its own folder. Past 40 links
  (a loop) the write is refused, as `open` refuses with `ELOOP`. Refused: writing over the last name reached, which
  turns a link of the loop into a file the person never named.
  The temporary file is made beside the file at the end, so the rename never crosses a disk.

## Hard links: reported, not kept

A file of several names cannot be replaced atomically for all of them. Writing it in place keeps the names but a crash
leaves it half written: refused. The write renames as for any file, and `Write_Report.hard_links` counts the other
names, so a program can say it. Extended attributes and POSIX ACLs are not copied either; no program asked yet.

## What each program drops

- plume: `write_keeping` and `keep_owner` (`io.odin`, `io_unix.odin`, `io_windows.odin`) become
  `fsx.write_atomic(path, bytes, fsx.DOCUMENT, &rep)`; Windows gains the access list it lost.
- galerie: `write_beside` (`edits.odin`) becomes the same call; it gains the owner, the sync of file and folder, and
  a temporary file that is not readable meanwhile.
- feuille: `os.write_entire_file` over the document (`edits.odin` Save and Extract, `signature_view.odin`) wrote in
  place: a full disk or a crash left a cut PDF. `fsx.DOCUMENT` replaces it.
- classeur: nothing. It writes no document over another: its copy makes a new file (`O_EXCL`) and keeps the source's
  mode and times, which is a copy's work, not a save's.
