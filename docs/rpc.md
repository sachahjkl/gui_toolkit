# rpc: a JSON-RPC peer over a child's pipes

`import rpc "gt:rpc"` (or the relative path of the submodule). The package is named `tk_rpc`. Linux and Windows; elsewhere
a peer ends at once with `Not_Started`. The design is in [src/md/features/rpc.md](../src/md/features/rpc.md).

A peer starts a child that speaks JSON-RPC 2.0 on its standard input and output (an ACP agent, a language server) and
gives the program its messages as values. The child runs as a process tree (`process.tree_start`,
[process.md](process.md)): it ends with the peer, and with the program however the program ends.

## An ACP agent

```odin
App :: struct {
	ui:      ui.State,
	agent:   ^rpc.Peer,
	session: string,
}

TAG_INITIALIZE :: 1
TAG_NEW_SESSION :: 2
TAG_PROMPT :: 3

agent_start :: proc(app: ^App) {
	app.agent = rpc.start({
		command   = {"gemini", "--acp"},   // or {"agy", "acp"}, {"claude-agent-acp"}, {"codex-acp"}
		wake      = proc(user: rawptr) {   // a thread of the peer: hand the drain to the interface's thread
			ui.post(&(^App)(user).ui, proc(data: rawptr, _: u64) {
				app := (^App)(data)
				rpc.drain(app.agent, on_agent, app)
			}, user)
		},
		wake_user = app,
	})
	rpc.call(app.agent, "initialize", `{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true}}}`,
		tag = TAG_INITIALIZE, timeout = 30 * time.Second)
}

on_agent :: proc(p: ^rpc.Peer, m: ^rpc.Message, user: rawptr) {
	app := (^App)(user)
	switch m.kind {
	case .Reply:
		if !m.ok { show_error(app, m.local, m.error.message); return }   // .Timed_Out, .Ended, or the agent's error
		switch m.tag {
		case TAG_INITIALIZE:
			rpc.call(p, "session/new", tk_json.to_text(new_session_params(app)), tag = TAG_NEW_SESSION)
		case TAG_NEW_SESSION:
			app.session = strings.clone(tk_json.text(m.result, "sessionId"))   // (the message lives during the handler)
		case TAG_PROMPT:
			show_stop_reason(app, tk_json.text(m.result, "stopReason"))
		}
	case .Notification:
		if m.method == "session/update" { show_update(app, m.params) }
	case .Request:
		switch m.method {
		case "session/request_permission":
			ask_the_person(app, m.id, m.params)   // keep m.id (a value); answer later with rpc.reply, from any thread
		case "fs/read_text_file":
			read_on_a_chore(app, m.id, tk_json.text(m.params, "path"))
		case:
			rpc.reply_error(p, m.id, rpc.METHOD_NOT_FOUND, "method not found")
		}
	case .Bad:
		log.warnf("agent: %v (%d bytes): %s", m.bad, m.size, m.text)
	case .Ended:
		// how (.Exited, .Signaled, .Not_Started, .Unknown), code, stopped, why, and the agent's last words on its standard error
		show_end(app, m.end.how, m.end.code, m.end.why, m.end.stderr)
		rpc.destroy(p)   // (the last message: destroy returns at once)
		app.agent = nil
	}
}

prompt :: proc(app: ^App, text: string) {
	b := strings.builder_make(context.temp_allocator)
	w := tk_json.writer_make(&b)
	tk_json.begin_object(&w)
	tk_json.key(&w, "sessionId"); tk_json.write_text(&w, app.session)
	tk_json.key(&w, "prompt")
	tk_json.begin_array(&w)
	tk_json.begin_object(&w)
	tk_json.key(&w, "type"); tk_json.write_text(&w, "text")
	tk_json.key(&w, "text"); tk_json.write_text(&w, text)
	tk_json.end_object(&w)
	tk_json.end_array(&w)
	tk_json.end_object(&w)
	if _, err := rpc.call(app.agent, "session/prompt", strings.to_string(b), tag = TAG_PROMPT); err != .None {
		show_busy(app, err)   // .Full: outbound_max bytes wait; .Ended: the agent stops or has ended
	}
}

// Stop button: ACP's own cancel of the session's work
rpc.notify(app.agent, "session/cancel", fmt.tprintf(`{{"sessionId":%s}}`, tk_json.quote(app.session)))
// Quit: the agent's input closes (it ends there), Terminate after the grace, then the tree is killed
rpc.stop(app.agent)
```

## API

| Procedure | |
|---|---|
| `start(Options) -> ^Peer` | starts the child and the peer's threads; never blocks: a failed start is an `Ended` message (`How.Not_Started`, `why`) |
| `call(p, method, params = "", tag = 0, user = nil, timeout = 0) -> (id: i64, Send_Error)` | a request; `params` is JSON text. Its `Reply` carries `tag` and `user` |
| `notify(p, method, params = "") -> Send_Error` | a notification |
| `reply(p, id, result) -> Send_Error` | the answer to the child's request `id` (`""`: null); from any thread, any time |
| `reply_error(p, id, code, message, data = "") -> Send_Error` | its error (`METHOD_NOT_FOUND`, `INVALID_PARAMS`...) |
| `cancel(p, id) -> Send_Error` | asks the child to cancel a request; the request still waits for its answer |
| `stop(p, grace = STOP_GRACE)` | the queued messages written, then the input closed; `Terminate` after `grace`; the tree killed after a second `grace` |
| `drain(p, handler, user = nil, budget = -1) -> int` | runs `handler` on the waiting messages, on this thread |
| `destroy(p)` | joins and frees: at once after `Ended`; before, it stops the child with no grace and waits (bounded by the kill); inside a handler, the free comes when the handler returns |
| `stderr_tail(p, allocator) -> string` | the last bytes of the child's standard error so far |
| `pending_messages(p)`, `peer_state(p)`, `peer_stats(p)` | messages waiting; `Starting`, `Running`, `Stopping`, `Ending`, `Ended`; counts (sent, received, dropped answers, bad) |

`Send_Error` is `.None`, `.Full` (`outbound_max` bytes wait already) or `.Ended` (the peer stops or has ended). No
send blocks.

| `Options` | |
|---|---|
| `command`, `dir`, `env` | the child; a bare name is found in `PATH` (Windows: with `PATHEXT`, an npm `.cmd` shim quoted for cmd.exe), never in the current folder |
| `framing` | `.Lines` (ACP: one message per line, the default) or `.Content_Length` (LSP's headers) |
| `cancel` | `.ACP` (`$/cancel_request` with `requestId`, the default), `.LSP` (`$/cancelRequest` with `id`) or `.None` |
| `wake`, `wake_user` | called from a thread of the peer when messages wait and no wake was called since the last drain |
| `message_max` | 16 MiB: a message beyond it is dropped (never held) and is a `Bad` message (`Too_Long`, `size`) |
| `inbound_max` | 64 MiB of message text waiting for a drain: past it the reader waits, and the child waits in its write |
| `outbound_max` | 64 MiB waiting for the writer: past it a send is `.Full` |
| `stderr_tail` | 64 KiB of the standard error kept, the oldest bytes dropped |

| `Message` | |
|---|---|
| `kind` | `Request`, `Notification`, `Reply`, `Bad`, `Ended` (the last) |
| `method`, `params` | a request's or a notification's (`params` a `json.Value`, read with `gt:json`) |
| `id` | a request's id (`Id`: a number, a string of `ID_TEXT_MAX` bytes at most inline, or null): keep it as a value, answer with it |
| `ok`, `result`, `error`, `local` | a `Reply`: `result` when `ok`; else the child's `error` (`code`, `message`, `data`), or `local` = `.Timed_Out` or `.Ended` |
| `tag`, `user` | a `Reply`: what `call` was given |
| `text`, `size` | the message's JSON text; `Bad`: its first `BAD_TEXT_MAX` bytes and its whole length |
| `bad` | `Not_Json`, `Too_Deep` (beyond `DEPTH_MAX`), `Too_Long`, `No_Length`, `Not_Rpc` |
| `end` | `how`, `code` (the exit code, or the signal), `stopped`, `why`, `stderr` |

A message lives in memory of its own and is freed when its handler returns: clone what you keep.

## Threads

Four threads per peer: the watch (the spawn, the time limits, the stop's steps, the end), a reader of the standard
output, a writer to the standard input, a reader of the standard error. None of them is the interface's, and no call
of the program waits for them, except `destroy` before `Ended`.

- The handler runs on `drain`'s thread. Messages come in the child's order; an answer to a batch comes apart into
  its messages.
- `call`, `notify`, `reply`, `reply_error`, `cancel` and `stop` may be called from any thread.
- A drain that stops at its `budget` calls the wake again: a burst of notifications is spread over frames.
- `destroy` may be called inside any handler (a tab closed while a message is handled): it stops the child, and
  `drain` frees the peer when that handler returns, then returns. The handler may still use the peer until it
  returns; nothing may use it after.

## What the peer answers itself

- A message that is no JSON: the child gets `PARSE_ERROR` (id null), the program a `Bad` message.
- An object that is no JSON-RPC message but has an id: the child gets `INVALID_REQUEST` for that id.
- An answer to an id that is not pending (its time limit passed): dropped, counted in `peer_stats(p).dropped`.
- A time limit that passes: the program gets the `Reply` with `local = .Timed_Out`, the child the cancel notification.

Tests: `tests/rpc` (the test program as the child), `src/rpc` (framing, messages, the tail).
