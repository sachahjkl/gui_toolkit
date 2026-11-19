# Downloads: intent

opencode native downloads the files a person picks in its file browser: a file of the server comes to a folder of this
computer while the person keeps working, and the notification says how far it is. Five parts of the toolkit make it,
each useful alone. The API is in [docs/http.md](../../../docs/http.md) (`http.receive`),
[docs/notifications.md](../../../docs/notifications.md) (`Notification.progress`),
[docs/file-browser.md](../../../docs/file-browser.md) (`File_Dialog.row_actions`, `start_known`) and
[docs/fsx.md](../../../docs/fsx.md) (`fsx.Writer`).

## The parts

1. **A streamed body** (`gt:http`, `receive`): the answer's body goes to a callback, chunk by chunk, on the request's
   own thread. Memory stays bounded by one chunk, whatever the file's size.
2. **A notification with a progress bar** (`platform.Notification.progress`): the program sends the same notification
   again with `replace` and a new value; the bar moves in place.
3. **A program's actions on an entry of the browser** (`platform.File_Dialog.row_actions`): "Download" in the context
   menu of a file of the server, beside the browser's own acts.
4. **`start_known` in the toolkit's browser**: the Save dialog that asks where the download goes opens in Downloads.
5. **A file written in parts** (`fsx.Writer`): the chunks go to a temporary file beside the target, which takes the
   target's name only once the whole body came.

## Decisions

- **A callback per chunk, not a reader the caller pulls.** Both clients push: libcurl calls its write callback, and a
  pull API over it needs a second thread or a buffer between the two. WinHTTP's own loop reads and hands over the same
  way. The stream of events (`events`) has the same shape; a download is one more of them.
- **The callback runs on the request's thread, and the caller's thread is a worker.** `receive` blocks as `request`
  does. A program calls it from a chore or a thread of its own; the interface's thread never waits on the network nor
  the disk. The callback writes the chunk (`fsx.writer_append`) and posts the progress back (an atomic, a wake).
- **Two ways to stop: the callback returns `.Stop`, or another thread asks (`Stop`).** The first is the caller's own
  decision (a disk full); the second is the person's (Cancel in the notification). `Stop` is the struct of the event
  streams: one stop for every long transfer of the package. Linux sees it in libcurl's progress callback (about once a
  second, and at once when bytes come); Windows between two reads of the asynchronous job.
- **`timeout` is a silence, not a total.** A download of 4 GB takes longer than any total a program can guess; what
  says that a connection died is that nothing comes. 0 is `STREAM_SILENCE`, as for an event stream.
- **`max_bytes` is 0 by default: no bound.** The body is not kept, so the bound of `request` (64 MB, a memory bound)
  does not apply; a caller that wants one sets it.
- **The status and the length come with each chunk** (`Body_Part.status`, `.length`, `.received`). A first callback of
  the head alone would be a second callback type for one value. An answer that is not 2xx gives no chunk and no Error,
  as `events`: a 404 page never lands in the target file. The Response comes back without its body (headers, URL).
- **Windows: the asynchronous job of the streams, not the synchronous calls of `request`.** A stop must not wait for a
  read that never returns; `stream_windows.odin`'s job already waits on an event with a stop. The request's body
  (a POST) goes with `WinHttpSendRequest`, as the job sends it.
- **Linux: the easy handle comes from the pool of `request`** (http-connections.md): a download reuses the connection
  that listed the folder. A stream (`events`) does not, because it holds its handle for hours.
- **A progress is a part of the notification, not a second API.** `replace` updates a notification in place on both
  systems already; a bar is one more field. A program shows a download by calling `notify_async` again with the same
  id. It never holds a handle that lives across threads.
- **Windows: the bar is bound to data; an update with the same shape is `UpdateWithTagAndGroup`.** A toast shown again
  under its tag pops up again and plays its sound at each step; an update of its data moves the bar silently. The shape
  (`notification_shape`: the title, the body, the buttons, the icon, the urgency, the sound) decides: the same shape
  updates the data, another shows the toast again. A system without `IToastNotifier2` (before Windows 10 1607), or an
  update that fails (the person closed the toast), shows it again: a bar that pops up, never a crash.
- **Linux: the `value` hint, 0 to 100.** It is not in the specification, but KDE Plasma, dunst, mako and Xfce read it;
  a server that does not know it ignores it (the specification says to). An unknown value sends no hint: no server
  draws a bar that runs without a value. The status words go on a line after the body, which every server shows.
- **The actions of a row are data of the dialog's options** (`File_Dialog.row_actions`), beside `places`. The browser
  is a view the toolkit builds; a program has no build of it in which to add a menu. A proc and a `user` per action,
  called on the interface's thread with the entry's path, once per entry chosen (a multiple selection gives each). The
  dialog stays open: a download is not a choice that ends it.
- **`start_known` is asked of the source** (`File_Source.known`). The computer's source reads the person's folders
  once on the chores with its places, and answers from that. A server's source has no Downloads: it leaves `known` nil
  and the dialog starts where it would without it. The order: `start_dir`, the folder the dialog's memory keeps, then
  `start_known`, then the source's start. A folder the system names but the person never made is not one to start in.
- **The writer is a struct with four calls** (`writer_open`, `writer_append`, `writer_commit`, `writer_abort`), not
  a callback adaptor of `gt:http`. `fsx` imports nothing of the network; the program's chunk callback calls
  `writer_append`. The temporary file is `<target>.<pid>.<thread>.part`: beside the target (a rename never crosses a
  disk), and its name says what it is to a person who finds it after a crash. Commit closes it, then `replace` (its
  tries on Windows) renames it over the target; abort closes and deletes it. A writer is used by one thread at a time.
- **Its part can be removed from another thread.** A download waiting for data holds the part open when the program
  ends, and the program's end removes the parts it knows. On Windows the part is opened with `FILE_SHARE_DELETE`
  (`CreateFileW`, not `os.open`), so the remove marks it deleted and it goes when the writer's handle closes; before,
  the remove failed and the part stayed (opencode native's CI). POSIX removes an open file already. Refused: an abort
  safe from another thread, which would make the writer's every call take a lock for the one call at the end.

## Refused

- **A download manager in the toolkit** (a queue, retries, resumption with `Range`). One program needs it; the parts
  above are what is common. A second program that downloads moves the manager here.
- **A pull reader (`read(buf)`) over the body.** See the callback's decision.
- **A progress callback separate from the chunk callback.** The chunk carries `received` and `length`; a second
  callback would run on the same thread at the same moments.
- **The body written to the target by `gt:http` itself** (`download(url, path)`). The program decides where a chunk
  goes (a file, a hash, a pipe) and when a partial file is kept.
- **A progress notification as a toast of its own kind with a handle** (`Notification_Progress_Handle`). The ids of
  `replace` already name a notification across calls; a handle would be a second identity.
- **Writing in place to the target.** A transfer cut half-way leaves a file of the right name and the wrong content.
- **A row action that closes the dialog with a result.** The dialog's answer is `done`; an action is a side act.

## Subtle points

- A chunk's bytes are valid during the callback only: libcurl and WinHTTP reuse their buffer.
- A compressed answer (`req.compressed`) gives decoded chunks; its `length` is then -1, as the header counts the bytes
  sent, not those given.
- The callback runs on a thread with `runtime.default_context()` on Linux (libcurl calls it from C): what it allocates
  goes to the heap allocator, never to a caller's arena.
- The Windows toast's progress values are plain strings bound to `{progressValue}` and `{progressStatus}`: they are not
  XML and are not escaped.
- A notification's `progress.value` past 1 is shown as 1; below 0 is unknown (Windows: an indeterminate bar).
- `writer_commit` after a failed `writer_append` refuses: the target stays as it was, the temporary file goes.
