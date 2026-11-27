# A program driven by its tool: the session, the port, the waits

A program's tool (`live`, `shots`, `bench`) starts the program on a desktop nobody sees, drives its window over the
DevTools protocol, then ends it. Four programs wrote this part each: two whole sessions (papier, inspecteur) and two
more connect loops (atelier, opencode native). Their copies drifted: fixed ports in three of them, fixed sleeps in
three. The toolkit now has one session (`toolbox.Program_Session`), one free port (`toolbox.free_port`), one bounded
connection (`cdp.connect_wait`) and the waits that let a tool drop its sleeps.

## The irreducible parts

- A desktop of its own: `toolbox.Sway` (homes, cache, config, renderer). The session only composes it.
- The program in it, with `TOOLKIT_DEVTOOLS=<port>`, its own environment and its log.
- Files the program reads at its start, written after the desktop's folder is made anew (`sway_start` empties it) and
  before the program starts: preferences, a desktop entry.
- A first connection with a bound, which fails at once when the program ended.
- An end: the program asked to quit, waited for with a bound, its exit code; then the desktop stopped with all it
  started.
- A restart in the same desktop and folders (what the program kept is read again).

## Decisions

- **The port is free, never fixed.** `free_port` asks the system for a listener on port 0 and lets it go. With a fixed
  port, a second run (another checkout's `live`, a `shots` beside it) cannot listen, and its tool drives the first run's
  window as its own: inspecteur's `shots` and atelier's `live` shared 9373. A port given back can be taken again before
  the program listens: `program_session_connect` then reads the program's log for the devtools server's "cannot
  listen" and says so, instead of driving another window.
- **The session does not connect at its start.** papier starts hidden and serves its window only after `show`; a tool
  connects when its window exists (`program_session_connect`), as many times as it needs (a window hidden and shown).
- **Files are data, not a callback.** `Program_File{path, text}` under the session's folder: what papier and inspecteur
  wrote before their start is a fixed text, and data needs no state passed through a `rawptr`.
- **The quit is the program's own.** `quit` is a command run in the session (papier: `papier quit`); none closes the
  window over the protocol (`Browser.close`). A program that does not end within its bound is stopped with the desktop,
  and its exit code is -1.
- **`connect_wait` belongs to `gt:cdp`, the session to `gt:toolbox`.** opencode native starts its program without a
  desktop (Windows too): it needs the free port and the bounded connection, not sway. `connect_wait` takes the program's
  process, optional, so a program that ended at its start fails the wait at once and not at its bound.
- **Linux only through sway.** The session's file has no system suffix: `sway_start` already says why it does not run
  elsewhere, and the session returns that.

## Waits

A tool waits for a condition, with a bound; it never sleeps a guess. The window answers the conditions it can see:

- `wait_for`, `wait_name`: a box there or gone. `wait_name` also takes a `text`: the box of that name whose text holds
  it (a column's cell that shows its value: "every row has its CPU %"). The server already matched both; the client
  could not ask for both.
- `wait_idle`: three builds in a row with no animation and no posted call. A fade, an opening dialog.
- `wait_still`: the window's picture unchanged for a time. For what the box tree does not show and the interface does
  not call "moving": a terminal's grid, a picture uploaded by a chore, an icon decoded on a worker. Two captures with
  the same PNG bytes are the same pixels (one encoder, one input), so nothing is decoded. Its `still` is part of the
  condition (Playwright's "network idle" has the same shape), not a delay: the wait ends as soon as the picture has
  held that long, and fails at its bound.

A wait's bound is time, but it fails only on a tree built after the bound: the window first makes the builds the wait
needs to answer (`wait_ripe`). A window stalls at its start (a device made again for its surface, a first frame under
lavapipe) longer than a wait's bound; the first look after the stall read the tree from before it and failed, while the
text was on the screen one frame later. A window that never builds again never answers, as it never answers anything.

What no wait can see stays the program's to say: a history of samples that must grow (inspecteur's graphs). A program
that shows such data in a picture makes it ready at once in its demo mode; the tool does not sleep for it.

## Refused

- A session per program: the copies drifted in their ports, waits and stops.
- A fixed port per tool, or a block of ports (`testkit.Ports`): a block fits servers a test addresses by text; a window's
  port is asked once and passed to the program.
- Counting a window's chores in flight in `wait_idle`: it would answer more conditions, but it changes what "idle" means
  for every caller of the devtools server; `wait_still` answers the same need from the outside.
- An empty event injected while a wait is pending, to force builds of a window at rest: the ticker's wake already makes
  the host loop build a frame (`host_frame` builds on every wake), so a window at rest was never the cause.
