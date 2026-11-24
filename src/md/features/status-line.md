# Status line

A program's status bar says what just happened ("Copied", "Saved", "3 files removed") for a few seconds, then shows its
usual words again. papier, inspecteur and feuille had the same `say` (a text, an end time, `STATUS_SHOWN_MS`, a wake);
classeur had a variant. `ui.Status_Line` is that state and its three procedures.

## What it holds and what it does not

- It holds the text and the time it goes, on the interface's clock (`now_ms`). A test's session moves that clock
  (`session.advance`): the message goes with no wait.
- It draws nothing. The bar's layout, its usual words and the words of each message stay the program's. A widget would
  take the bar's layout from programs that each lay it out their own way.
- `STATUS_SHOWN_MS` (3 s) is the default; `shown_ms` sets another for one message. inspecteur showed its messages for
  4 s: it passes 4000, or takes the default.

## The wake

The window must make a frame when the message goes, or the message stays on screen until the next input.

- `status_say` in a build asks the window's state for a wake at the end (`wake_within`).
- A build's wake is cleared at the next build. `status_text`, read in each build, asks the wake again for the time left.
  So the wake holds however many frames come between, and a message said outside a build (a worker's answer read in
  the loop) gets its wake at the frame that first shows it.
- `status_text` gives "" once the time is past, and keeps the text. The text is freed at the next `status_say`, at
  `status_clear` or at `status_destroy`. A getter that frees would make a message read twice in a frame differ.

## Refused

- **A queue of messages.** A new message replaces the one shown: each program did so, and a status line is not a log.
  A message that must stay is a toast or the bar's own words.
- **A timer thread.** The window's own wake does it, on the interface's thread.
