# notices: what the user missed

`import notices "gt:notices"` (the package is `tk_notices`). Odin, any target; it uses [store](store.md) for its file and
`platform.Notification_Id` for the system notification of an entry.

A program that runs long tasks keeps a log of what its user missed: a run ended, a permission or a question waits, a
command ended. The log is a projection of the program's own truth. The program puts an entry when something happens,
acknowledges it when the user opens the thing it is about, and removes it when the thing is gone. The log keeps the time,
an excerpt, a state and a history.

## The states

An entry is `New` (not shown yet), `Seen` (the view of the log was opened) or `Acknowledged` (the user went to the
thing). `step(state, event)` is that machine, pure; `put`, `seen_all` and `acknowledge` use it:

| event | New | Seen | Acknowledged |
|---|---|---|---|
| `Put` | New | New | (a new entry) |
| `Seen` | Seen | Seen | Acknowledged |
| `Acknowledge` | Acknowledged | Acknowledged | Acknowledged |

An entry not acknowledged is open. A key (one session's run, one question) has at most one open entry. A `put` of a key
that is open updates its entry: its fields, `count + 1`, New again. A `put` of a key that is not open adds an entry. An
acknowledged entry stays in the history. Past `cap` entries, the oldest acknowledged entry goes. An open entry never goes.

## A log

```odin
log: notices.Log
notices.open(&log, path)                         // at the start, before the window: it reads the file
log.close_system = proc(user: rawptr, id: platform.Notification_Id) { platform.notify_close((^App)(user).window, id) }
log.close_user = app

e, fresh := notices.put(&log, {key = "run:ses_1", group = "ses_1", title = "Run ended", text = excerpt, at = now_ms})
notices.acknowledge(&log, "run:ses_1")           // the user opened the session
notices.seen_all(&log)                           // the view of the log was opened
notices.remove_group(&log, "ses_1")              // the session was deleted
for g in notices.groups(&log, false) { for e in g.entries { row(e) } }
notices.close(&log)                              // at the end: written, freed
```

| Procedure | |
|---|---|
| `open(log, path, cap = CAP, allocator) -> (loaded: bool)` | reads the file (a `store`; `""`: in memory only) and starts its worker; false: no file. `CAP` is 200 |
| `close(log)` | writes what changed, ends the worker, frees every entry |
| `flush(log)` | writes what changed now and waits for the disk (the end of a program, a test) |
| `put(log, Desc) -> (e: ^Entry, fresh: bool)` | the key's open entry updated (`fresh` false), else a new one |
| `acknowledge(log, key) -> ^Entry` | the key's open entry goes to the history; nil: none was open |
| `acknowledge_group(log, group) -> int`, `acknowledge_all(log) -> int` | every open entry of the group, or every one |
| `seen_all(log) -> int` | every New entry is Seen |
| `remove(log, key) -> int`, `remove_group(log, group) -> int` | the thing is gone: its entries go, the history too |
| `find(log, key) -> ^Entry` | the key's open entry; else the newest of its history; else nil |
| `groups(log, with_acknowledged) -> []Group` | the entries by group (below) |
| `set_system(log, key, id)` | the system notification of the key's open entry (the answer of `notify_async`) |
| `system_closed(log, id)` | the system says the notification is gone (`Notification_Closed`) |
| `step(State, Event) -> State` | the machine of the states |

`Desc` has `key`, `group`, `title`, `text`, `kind` (u16), `outcome` (u8), `at` (ms since 1970) and `user` (u64). `kind`,
`outcome` and `user` are the program's. The log copies the strings.

`Entry` has the same fields, then `id` (increasing: the order of the entries), `count` (the puts while it was open),
`state`, and `system` (its system notification, 0: none). A `^Entry` is valid until the next change of the log.

`Log` fields that a program reads:

- `entries`: every entry, the oldest first.
- `counts: [State]int`: how many entries are in each state. It is always a recount. A badge shows `counts[.New]`, or
  `counts[.New] + counts[.Seen]`.
- `ver`: bumped at every change. A view compares it to know that it must redraw.

The log belongs to the interface's thread: it has no lock. Only `open` reads the disk. The store's worker writes the file.

## Groups

`groups(log, with_acknowledged)` gives the entries by `group` (a session). The groups come newest first, and the entries
in a group come newest first. A `Group` has `group`, `entries`, `newest` (the time of its newest entry) and `open` (its
entries not acknowledged). With `with_acknowledged` false, the list has the open entries only, and a group with none is
left out.

The log keeps the list. It makes the list again only when `ver` moved, so a view can call `groups` at every frame.
`groups_made` counts the times it made the list. The list is valid until the next change of the log.

## System notifications

The program shows a system notification for an entry with `platform.notify_async` ([notifications.md](notifications.md)).
Its `done` calls `set_system(log, key, id)`. If the entry was acknowledged meanwhile, the notification goes at once.

The log calls `close_system(close_user, id)` when an entry with a notification is acknowledged or removed. The program
calls `platform.notify_close` there. When a `put` updates an open entry (`fresh` false), the program gives `e.system` as
`Notification.replace`. On `Notification_Closed`, the program calls `system_closed(log, id)`. The `system` field is not
saved: a notification does not survive the program.

## The file

One `store` line per entry. The key is the entry's id. The value is `state`, `count`, `at`, `kind`, `outcome`, `user`,
`key`, `group`, `title` and `text`, separated by tabs. The strings are escaped (`\\`, `\t`, `\n`, `\r`): a store line
holds no line break. `open` drops a line that it cannot read. If two open entries have one key, the newer stays open.

## ui.badge: a count on a button

`ui.badge(box, count, intent = .Primary)` draws `count` on the top right corner of `box`. Call it right after the box is
built (a `button`'s). The count is in a pill of the intent's hue, its digits in `ink_on` of it.
Past 99 it shows "99+". At 0 or less it shows nothing.

```odin
sig := ui.button("notices", icon = ui.ICON_UP)
ui.badge(sig.box, app.log.counts[.New])
```

The pill floats over the box and takes no click: the press goes to the button. A screen reader reads the count as the
button's description, unless the program gave one.

## Tests

`odin run tools/run_tests -- notices` tests the log. `tests/scenarios/badge_test.odin` tests `ui.badge`.
