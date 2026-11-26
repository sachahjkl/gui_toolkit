# A window's taskbar button

A program says three things on its button in the task bar or the dock: how far a work is (a progress), how many things
wait for the person (a count), and that it wants to be looked at (attention). The first user is opencode native: its
sessions running are a progress, its sessions waiting for the person are a count, a session that just stopped to ask is
attention. How to call it: [docs/platform.md](../../../docs/platform.md#taskbar-button).

```odin
platform.taskbar_progress(w, .Indeterminate)
ui.taskbar_badge(w, 3, "3 sessions are waiting for you")   // the theme's accent
platform.taskbar_attention(w, true)
```

## Decisions

- **One call per state, and the state is the window's.** `taskbar_progress`, `taskbar_badge` and `taskbar_attention`
  each set one part of `Window.taskbar` (`Taskbar_State`). A call with the values the window already has does nothing
  and answers false: a program calls them where its own state changes, or at each build; the system is called only for
  a change. The fraction is kept in thousandths (`TASKBAR_STEPS`), so a progress told at each received byte calls the
  system a thousand times at most. A handle per progress, a builder, or one call with every part were refused: the
  parts change at different times, and each one alone is the program's sentence.
- **What the system is asked is derived from the state, never kept apart.** The backends read `Window.taskbar` and
  apply it whole when the system needs it again (a taskbar button created, Explorer restarted). So there is no queue of
  calls to replay and no second copy to keep in step. This is the one state machine of the feature: the wanted state,
  then per system whether it can be shown now (Windows: the button exists; Wayland: the surface was presented).
- **Each system its own best, no lowest common denominator.** Windows has the richest button and gets all of it: the
  progress's five states, a picture over the icon with its spoken words, a flash. Linux docks read the Unity launcher
  entry: count, progress and urgent, with no state for paused or failed. The table below says the difference; Windows
  is not brought down to Linux's level.
- **Attention ends when the person comes.** A window that becomes active clears its attention on every system: Windows
  stops the flash itself, X11 and the launcher entry are told. Attention asked by an active window is refused (false):
  there is nothing to draw the eyes to. `flashes` (Windows) flashes that many times, then the button stays lit until
  the window is activated; 0 flashes until then.
- **The count's picture is the toolkit's, drawn in the theme's accent.** `taskbar_badge_pixels` draws a disc and the
  number with stroked digits (no font: the platform package has none, and the picture is 16 to 32 pixels). 1 to 99 are
  written; 100 and more are a plus sign, and the words say the number. The ink is white or black, the one with the
  higher contrast on the accent. `ui.taskbar_badge` passes the theme's accent; a call of the platform's alone gets
  `TASKBAR_BADGE_RED`. Windows' own badge glyphs (the mail app's) were refused: a count is not a glyph.
- **The words are spoken.** Windows' overlay has a description that a screen reader says with the button. A count
  given without words gets the toolkit's "%d waiting" in the person's language.
- **Linux: one entry per program.** The Unity entry names the program's desktop file
  (`application://<app id>.desktop`, `set_app_id`), not a window. The window that changed last decides what the dock
  shows; its end clears the entry, the end of another window does not. The entry goes as a signal on the thread's
  session bus (`dbus.emit_signal`: no reply is waited for). Its object path is libunity's
  (`/com/canonical/unity/launcherentry/<hash of the URI>`); docks match the interface, not the path.
- **Wayland's attention is an activation the compositor refuses, asked only where it marks.** Wayland has no urgency
  request. An `xdg_activation_v1` token asked with no input serial is one the compositor does not grant; KWin, Mutter
  and sway then mark the window as demanding attention, as Qt's `QWindow::alert` relies on. A compositor that grants
  such a token focuses the window instead, and the person's typing goes to it: worse than no mark. So the token is asked
  only when `XDG_CURRENT_DESKTOP` names KDE, GNOME or sway (`wayland_attention_marks`); elsewhere the launcher
  entry's `urgent` is the only sign. Always asking was refused for that focus theft; never asking was refused because
  Plasma and GNOME users would lose the mark. A mark cannot be taken back: the compositor clears it when the window is
  focused; a token not spent yet is dropped when the attention stops. ShojiWM refuses such a token and does nothing;
  its task bar reads `urgent`.
- **X11: both hints.** `WM_HINTS` with `UrgencyHint` (ICCCM: the client sets and clears it) and
  `_NET_WM_STATE_DEMANDS_ATTENTION` (EWMH). Window managers read one or the other.
- **Windows: the taskbar list on the window's thread, after its button exists.** `ITaskbarList3` answers only once
  Explorer sent the window `TaskbarButtonCreated`. That message comes again when Explorer restarts: the list is
  released, made again and given the whole state. COM is joined on the window's thread there (single-threaded; a thread
  already in the multithreaded apartment keeps it). A process running as administrator lets that one message through
  (`ChangeWindowMessageFilterEx`), as the tray lets `TaskbarCreated`: the elevated window still takes no message of
  lower integrity that carries data ([elevated-process.md](elevated-process.md)). This one carries nothing; a program
  that sends it only makes the window ask Explorer again for its own state. A list per process on a worker thread was refused: its calls are message sends to
  Explorer with nothing to wait for, and a worker would add a queue and an order to keep.
- **An offscreen window keeps its state and sends nothing.** It has no button: Windows calls nothing. On Linux the
  entry needs no surface, but a program's tests call `ui.taskbar_badge` at each build: their count would go to the
  developer's own dock. A test that reads the entry asks for it (`taskbar_offscreen_entry`) and gives the thread a bus
  of its own.

## Per system

| | Windows | Linux, Wayland | Linux, X11 | macOS |
|---|---|---|---|---|
| Progress | `SetProgressState` and `SetProgressValue`: normal green, paused yellow, error red, indeterminate | the entry's `progress` and `progress-visible`; paused and error show as normal; indeterminate shows nothing | as Wayland | `NSDockTile` with a progress view (not built: no backend) |
| Count | `SetOverlayIcon`: the toolkit's disc and number, its words spoken | the entry's `count` and `count-visible` (the dock draws it) | as Wayland | `NSDockTile.badgeLabel` (not built) |
| Attention | `FlashWindowEx` on the button, until active or `flashes` times | on KDE, GNOME and sway an `xdg_activation_v1` token with no serial (the compositor marks the window), and the entry's `urgent` | `UrgencyHint` and `_NET_WM_STATE_DEMANDS_ATTENTION`, and the entry's `urgent` | `requestUserAttention` (not built) |
| Who reads it | Explorer | KDE Plasma, Dash to Dock, Dash to Panel, Plank, Latte, ShojiWM's task bar | as Wayland, and the window manager | the Dock |

## Subtleties

- **The launcher entry has no `Query` here.** libunity answers a dock that starts after the program; most docks only
  listen. A dock that starts later sees the state at the program's next change.
- **A program that ends badly leaves its entry.** A crash, or an exit that does not destroy its windows, sends no
  cleared entry. Plasma forgets an entry when its sender leaves the bus; ShojiWM's task bar keeps the count (see below).
- **Two windows, one entry.** The entry shows the window that changed last; when that window ends, the entry is cleared
  even if another window still has a count. That window's next change shows it again.
- **The send never waits for an answer, but it is a write.** The first call on a thread with no bus yet connects
  (as every other bus user does). A bus that stops reading fills the socket: the write then waits up to the dbus
  package's send stall before it calls the bus lost.
- **The badge picture has the window's scale at the call.** A move to a screen of another scale keeps the old picture
  until the next change; Windows scales it.

## ShojiWM

ShojiWM's task bar (`shojiwm-desktop`, `crates/shell/src/taskbar/launcher_entries.rs`) reads the entry with
`busctl --user monitor`: the progress fills the button green, `urgent` fills it orange, a count over 0 is a red badge
on the icon. It reads all that this API sends on Linux. A pull request would add:

- forgetting a program's entry when its sender leaves the bus (`NameOwnerChanged`), so that a program that crashed with
  a count does not keep it;
- marking a window as demanding attention on an `xdg_activation_v1` activation with a token it refused
  (`token_created` false), as KWin and Mutter do, for programs that do not send the entry.
