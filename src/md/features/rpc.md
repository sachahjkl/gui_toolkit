# A JSON-RPC peer over a child's pipes (`gt:rpc`, package `tk_rpc`)

## Purpose

A program drives another program that speaks JSON-RPC 2.0 on its standard input and output: an agent of the Agent
Client Protocol (Gemini CLI `gemini --acp`, Antigravity `agy acp`, Claude Code `claude-agent-acp`, Codex `codex-acp`)
for Tower, a language server for plume later. Both sides send requests, answers and notifications at any time. The
package starts the child as a process tree (`process.tree_start`), owns its three pipes and gives the program values:
messages to handle, and an end with its exit code and the tail of its standard error.

## The framing

- **ACP: one message per line.** The ACP stdio transport (v1 and v2, "Transports"): each message is one JSON-RPC
  object, UTF-8, delimited by `\n`, and it MUST NOT contain an embedded newline. Logs go to the standard error. This
  is `Framing.Lines`, the default.
- **LSP: `Content-Length` headers.** A header block (`Content-Length: N`, other headers ignored, `\r\n` after
  each, an empty line), then N bytes of body. It costs one more state in the reader and one header in the writer, and
  plume needs it: it is `Framing.Content_Length`.
- A line ends at `\n`; a `\r` before it is dropped (a child on Windows). An empty line is skipped.
- An outgoing message in `Lines` must hold no newline. JSON allows a raw newline only as whitespace between tokens
  (never inside a string), so the peer replaces `\n` and `\r` in the program's JSON text with spaces: an indented
  `tk_json.Writer` output stays valid.
- **Batches.** JSON-RPC 2.0 defines them; ACP and LSP never send them. An incoming array is taken apart and each
  element is handled as its own message; the answers to its requests go one by one, not as an array. An empty array
  is an invalid request. The peer never sends a batch.

## The threads

Four threads per peer, none of them the interface's:

| Thread | Does |
|---|---|
| watch | starts the tree, then waits for its end, a wake or the next deadline: per-request time limits, the stop's steps |
| reader | reads the standard output, frames, parses, matches answers to requests, queues messages |
| writer | writes the queued messages to the standard input, then closes it at a stop |
| errors | reads the standard error into a ring of its last bytes |

- **Every call of the program is non-blocking.** `start` allocates the peer and starts the watch; the spawn (a fork or
  a `CreateProcess`, tens of milliseconds) happens there. A failed start is an `Ended` message, not a return value.
  `call`, `notify`, `reply`, `cancel` and `stop` take a lock and queue. Only `destroy` joins the threads: after
  `Ended` it returns at once.
- **`destroy` inside a handler is deferred.** A program closes a tab while its handler runs, and the handler goes
  on with the peer after the call. `drain` notes its thread while a handler runs; a `destroy` from that thread stops
  the child at once but leaves the join and the free to `drain`, which does them when the handler returns, then
  returns. Refused: an assert, which would turn a natural call into a crash in a program's hands.
- **The watch waits on the process, not on the pipes.** A grandchild that inherited the standard output keeps the pipe
  open after the child ended; an end found by EOF would then never come. The watch waits on the process (Linux: a
  pidfd and the peer's wake pipe in one `poll`; Windows: `WaitForMultipleObjects` on the process and an event), and a
  deadline is its time limit. At the end it kills what is left of the tree, so the pipes close.
- **The deadlines are not the writer's.** A writer blocked in a write to a child that reads nothing cannot keep time.
  The watch does, and its last step (the tree killed) makes that write fail.
- **The readers and the writer poll a stop pipe on Linux.** A process that left the tree (its own `setsid`) can keep
  the output or the input open after the kill. The readers and the writer wait in a `poll` on their pipe and the stop
  pipe; the input's end is non-blocking, so a write never waits outside that `poll` (a blocking write to a full pipe
  that nobody reads never returns). Once the tree is gone the watch closes the stop pipe when both readers are done,
  or after `ENDING_BOUND`: nothing that left the tree holds the end back. On Windows no process leaves
  the job (breakaway refused), and the readers block in `ReadFile`.

## Delivery to the program

- Messages wait in a queue that the program drains on its thread: `drain(peer, handle, user, budget)`. `Options.wake`
  is called (from a thread of the peer) when the queue goes from empty to not empty, once per drain: the program posts
  a drain to its interface (`ui.post`) or wakes its loop. A drain that stops at its budget calls the wake again.
- A message lives in memory of its own (an arena per message); it is valid during the handler only. The program
  clones what it keeps. The reader parses a message once, into its arena, and nothing copies it after.
- `gt:rpc` does not import `ui`: the wake is a procedure. A tool, a test or a server without an interface drains in
  its own loop.

## Bounds (memory)

| Bound | Default | When it is reached |
|---|---|---|
| `message_max` | 16 MiB | a line or a body beyond it is dropped (read and thrown away up to its end, never held) and a `Bad` message (`Too_Long`) says its size |
| `inbound_max` | 64 MiB | the bytes of the messages waiting for a drain: the reader stops reading, the pipe fills and the child waits in its write (back-pressure). One message always goes in, whatever its size, so a large message cannot stop the peer |
| `outbound_max` | 64 MiB | the bytes waiting for the writer: `call`, `notify` and `reply` return `.Full` |
| `stderr_tail` | 64 KiB | a ring: the oldest bytes go |
| `DEPTH_MAX` | 128 | a message nested deeper is `Bad` (`Too_Deep`): a scan before the parse bounds the parser's recursion |

## Requests, answers and their ends

- **Our ids are integers from 1, the peer's own.** The reader matches an answer by its id, under the pending table's
  lock; the message carries the `tag` and the `user` given to `call`. An answer to an id that is not pending (timed
  out, unknown) is dropped and counted.
- **A request has a time limit** (`call(..., timeout)`; 0: none). At the limit the program gets the `Reply` with
  `local = .Timed_Out`, the entry goes, and the cancel notification is sent so that the child can stop the work.
- **`cancel` does not end the request.** ACP's `$/cancel_request` and LSP's `$/cancelRequest` are advice: the receiver
  MUST still answer, and an ACP `session/prompt` cancelled after it was inserted still succeeds with its `messageId`.
  So `cancel` sends the notification and the request waits for its answer as before. The method and the key of the id
  are options (`cancel_method`, `cancel_key`): ACP's `$/cancel_request` and `requestId` by default, LSP's
  `$/cancelRequest` and `id`.
- **The child's requests are answered from any thread, later.** A `Request` carries the child's id as a value (`Id`:
  a number, a string of at most `ID_TEXT_MAX` bytes inline, or null) that the program keeps without an allocation;
  `reply` and `reply_error` take it. The peer answers a string id longer than that with an invalid request error.
  An object that is neither a request, a notification nor an answer is answered with `-32600` when it has an id,
  else it is a `Bad` message.
- **At the end every pending request gets its `Reply` with `local = .Ended`**, before `Ended` itself.

## The end, as a state machine

```
Starting --spawn ok--> Running --stop()--> Stopping --exit--> Ending --pipes closed--> Ended
    |                     |                                     ^
    |                     +----------------exit-----------------+
    +--spawn failed---------------------------------------------------------------> Ended (Not_Started)
```

- **`stop(grace)`**: the writer writes what is queued, then closes the standard input (an ACP agent ends at the end of
  its input). If the child has not ended after `grace`, the tree gets `Terminate` (Linux: SIGTERM to its group;
  Windows has no gentle signal for a child without a console window: the job is ended). After a second `grace`, the
  tree is killed. A stop takes at most two graces and the kill.
- **Ending**: the child has exited; the rest of the tree is killed, the pipes close, the reader delivers what it had.
  Then `Ended` is queued, the last message: no message comes after it.
- **`Ended`** carries how (`Exited`, `Signaled`, `Not_Started`; `Unknown` when the end is not seen even after the
  kill, a wait woken by a `poll` error), the exit code or the signal, whether a stop asked
  for it, and the last bytes of the standard error. The tail is the child's own words on why it failed: the program
  shows it.

## Errors are values

A bad message never panics and never ends the peer: invalid JSON, a value that is no JSON-RPC object, a line too long
or too deep is a `Bad` message with its kind and the start of its text. A send after the end returns `.Ended`; a
full queue `.Full`. A parameter text that is not one JSON value is the program's error: it is sent as it is, and the
child answers it.

## Refused

- **A callback per request.** Messages are values drained by the program in one place; a `tag` says which request an
  answer is for. A callback would run the program's code on a thread it did not choose, or need a second queue.
- **`ui.post` inside the package.** `ui` is the interface layer; `rpc` sits under it. The wake procedure is the seam.
- **Batches sent.** No protocol in view uses them.
- **A local `cancel` that ends the request.** It would lose an answer that ACP defines as meaningful.
- **Blocking sends.** A full outbound queue is `.Full`: the interface's thread never waits for a child.
- **The end found by the pipes' EOF.** A grandchild holds them open.

## The test that breaks it

`tests/rpc` runs the test program itself as the child (its `@(init)` sees a mode in its environment). The child echoes
requests, sends notifications and requests back, floods its standard error, exits with a code, crashes, never answers,
writes a line beyond `message_max`. The peer must answer each case with values: replies matched by tag, time limits,
a `Too_Long` message with the next message still read, the stderr tail, the exit code or the signal, a stop within its
graces.
