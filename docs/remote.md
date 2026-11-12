# remote: a value read from a server

`import remote "gt:remote"` (the package is named `tk_remote`). How the reading of a value stands, one machine for every reading
a program makes, and the ticket that drops the answer of a reading given up. Pure Odin, no thread of its own: the thread that
owns a `Remote` begins and settles it.

```
Idle ──begin──▶ Loading ──answer──▶ Ready | Refused | Failed
  ▲                │ begin again: a new ticket, the old answer no longer counts
  └────reset───────┘
```

```odin
x: remote.Remote                          // where it does not move: a request keeps its address
ticket := remote.begin(&x)                // then the request, with the ticket
...
if remote.answer(&x, ticket, .Ready) { read(body) }      // false: a stale answer, nothing changed
remote.answer(&x, ticket, .Refused, server_message)      // the server's words, kept (owned) in x.message
remote.destroy(&x)
```

| Procedure | What |
|---|---|
| `begin(x) -> ticket` | a new reading: `Loading`, and what was on its way no longer counts |
| `reset(x)` | nothing read, nothing on its way (the server changed; a dialog opened on something else) |
| `answer(x, ticket, state, message)` | the reading ends, when `ticket` is the current one; false otherwise |
| `current(x, ticket)` | whether an answer of `ticket` is of the reading on its way |
| `settle(x, state, message)` | the reading ends, its ticket checked by the caller |
| `shows(x)` | what was read is on screen: `Ready`, or `Loading` again after something was read (`known`) |
| `failed(x)` | `Refused` or `Failed`: its message is all there is |
| `destroy(x)` | its message freed; its ticket moves on, so that a late answer does not match a count started over |

`Refused`: the server answered no (its message is the server's words). `Failed`: no answer, or one that cannot be read. A program
says each in its own words, with its own Try again.

A reading asked again soon after something happened goes with `ui.Deferred` ([pacing.md](pacing.md#deferred-something-done-once-things-are-quiet)).
