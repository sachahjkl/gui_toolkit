# A second start: the launch message and the window's handler

A second start of a program hands what it was asked to the copy that runs (`gt:instance`). Seven programs wrote the same
steps: encode the launcher's activation token and the arguments, switch on PING and QUIT, post to the interface's thread,
raise the window with the token. The shared layer has two parts:

- `instance.Launch{token, args}` with `launch_encode` and `launch_decode`: the message's format.
- `host.instance_serve`: the handler on the instance's thread and the hand-over to the window's thread.

## The message

`Launch.args` is a list of words. The program decides what a word means:

- A program that opens files (classeur, feuille) gives absolute paths.
- A program that takes commands (cliche, papier) gives the command's words: `{"show"}`, `{"copy", "12"}`.
- A program with options (opencode native) gives its command line's options as written (`--session=…`), and reads them
  with its own option reader.
- A program that only comes to the front gives none.

So one format carries paths and commands. The program's own reader turns the words into its action. A word is never split
again: a path with a space or a newline stays one word.

The bytes: the mark `0x01`; the token as a 32-bit little-endian length and its bytes; the count of words; each word as
a length and its bytes. Decisions:

- **Lengths, not a separator.** A NUL never comes in a command line's word, but a path from another source (a drop, a
  file list) can hold any byte the system allows, and the encoder must not refuse a word. A length carries any byte.
- **A mark byte first.** `MESSAGE_PING` and `MESSAGE_QUIT` start with `0x02`. A message that does not start with
  `0x01` is no launch: `launch_decode` says so and the handler drops it.
- **The decode checks every length and the count.** A message cut short, even between two words, or with bytes after
  the last word is refused whole. Half a launch is never acted on. A count larger than the bytes can hold is refused
  before any allocation.
- **No version field.** Before 1.0, a format change changes both sides in the same release. A launch from an older copy
  is refused, and the identity check of `acquire` already keeps another executable apart.

## The handler: host.instance_serve

`instance_serve(&service, h, owner, on_launch, on_quit)` serves the Owner on its own thread (`instance.serve_start`):

- **PING**: no work. The answer alone says that a copy runs.
- **QUIT**: `on_quit(h)` on the window's thread. nil: `platform.request_close(h.win)`, as the title bar's close.
- **A launch**: `on_launch(h, launch)` on the window's thread. If it returns true, the host raises `h.win` with the
  launch's token and settles a few frames (`host_settle`).
- **Anything else**: dropped.

Decisions:

- **The service is the caller's memory (`Instance_Service`), not a heap object.** A posted call points to it. The
  program keeps it beside its Host, so it lives as long as any call the State still holds. A heap object freed by the
  stop would be read by a call that runs after it.
- **The launches wait in the service's queue, under its lock. The post carries no data.** A post can fail: the State's
  queue is closed at the window's end. A failed post then loses nothing and leaks nothing: the launch stays in the
  queue, and `instance_serve_stop` frees it. A call already posted that runs after the stop finds the service stopped
  and does nothing.
- **Launches run in their order, then the quit.** A start that asks to open a file and an installer's quit that comes
  next both act, in that order.
- **on_launch says whether to raise.** cliche and papier take commands that open no window (a capture, a copy). The
  program decides; the host does the raise with the token, which every program wrote the same way.
- **The strings of a launch are valid only during on_launch.** The program copies what it keeps, as with any message
  of `gt:instance`.
- **The host knows nothing of the words.** No paths are made absolute here: the second start does that, in its own
  folder, before it encodes.

## Subtle points

- Call `instance_serve_stop` before `host_close`: `host_close` destroys the State that the thread posts to.
- papier serves its instance in a watcher with no window. It takes the message format (`launch_encode`,
  `launch_decode`), not `instance_serve`.
- The test that breaks a separator format: a path that holds the separator, a newline and non-ASCII letters, sent and
  read back as one word.
