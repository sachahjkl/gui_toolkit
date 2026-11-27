// Package rpc: a JSON-RPC 2.0 peer over a child's standard input and output (src/md/features/rpc.md). The child runs as
// a process tree (process.tree_start): it ends with the peer, and with the program however the program ends. Both sides
// send requests, answers and notifications at any time; the program drains the messages on its own thread.
//
//	start          starts the child and the peer's threads; never blocks (a failed start is an Ended message)
//	call           a request: its Reply comes back with the tag and the user given, or with local = .Timed_Out
//	notify         a notification
//	reply          the answer to a request of the child (any thread, any time); reply_error its error
//	cancel         asks the child to cancel a request (ACP's $/cancel_request, LSP's $/cancelRequest): its Reply still comes
//	stop           ends the child: its input closed, then Terminate after `grace`, then the tree killed after another
//	drain          runs a handler on the messages that wait, on the caller's thread
//	destroy        joins the threads and frees the peer: after Ended, at once
//	stderr_tail    the last bytes of the child's standard error
package tk_rpc

import "core:encoding/json"
import "core:mem"
import "core:time"

MESSAGE_MAX_DEFAULT :: 16 * mem.Megabyte
INBOUND_MAX_DEFAULT :: 64 * mem.Megabyte
OUTBOUND_MAX_DEFAULT :: 64 * mem.Megabyte
STDERR_TAIL_DEFAULT :: 64 * mem.Kilobyte
// The time a stop gives the child at each step: after its input closed, then after Terminate.
STOP_GRACE :: 2 * time.Second
// The start of a bad message's text kept in its Message.
BAD_TEXT_MAX :: 256

// How messages are delimited on the pipes.
Framing :: enum u8 {
	Lines,            // ACP: one JSON text per line
	Content_Length,   // LSP: "Content-Length: N" headers, an empty line, N bytes
}

// How a request is cancelled: ACP's {"method":"$/cancel_request","params":{"requestId":id}}, LSP's
// {"method":"$/cancelRequest","params":{"id":id}}, or no notification.
Cancel_Style :: enum u8 { ACP, LSP, None }

Options :: struct {
	command:      []string,            // the child: its program (a bare name is found in PATH) and its arguments
	dir:          string,              // its working folder ("": this process's)
	env:          []string,            // its whole environment, "NAME=value" (nil: this process's)
	framing:      Framing,             // Lines for ACP (the default), Content_Length for LSP
	cancel:       Cancel_Style,
	wake:         proc(user: rawptr),  // called from a peer's thread when messages wait and none was said since the last drain
	wake_user:    rawptr,
	message_max:  int,                 // 0: MESSAGE_MAX_DEFAULT
	inbound_max:  int,                 // 0: INBOUND_MAX_DEFAULT
	outbound_max: int,                 // 0: OUTBOUND_MAX_DEFAULT
	stderr_tail:  int,                 // 0: STDERR_TAIL_DEFAULT
}

// What a message is.
Kind :: enum u8 {
	Request,        // the child asks: answer it with reply or reply_error (from any thread, later if need be)
	Notification,   // the child tells
	Reply,          // the answer to a call of the program
	Bad,            // what the child sent is no message: `bad` says why
	Ended,          // the child's end: the last message
}

// Why a Reply comes from the peer and not from the child.
Local :: enum u8 {
	None,        // the child's answer
	Timed_Out,   // the call's time limit passed; a later answer is dropped
	Ended,       // the child ended before it answered
}

Bad_Kind :: enum u8 {
	None,
	Not_Json,    // not JSON text (the child got a parse error back)
	Too_Deep,    // nested beyond DEPTH_MAX
	Too_Long,    // beyond message_max: `size` says its length, `text` is empty
	No_Length,   // Content_Length: a header block without its length
	Not_Rpc,     // JSON, but no JSON-RPC message (the child got an invalid request error when it gave an id)
}

How :: enum u8 {
	Exited,        // with `code`
	Signaled,      // by the signal `code` (Linux)
	Not_Started,   // `why` says why
	Unknown,       // the end was not seen within the bounds, even after the kill: `code` is 0
}

// The child's end.
End :: struct {
	how:     How,
	code:    int,
	stopped: bool,     // stop asked for it
	why:     string,   // Not_Started: the error
	stderr:  string,   // the last bytes of its standard error
}

// A message, valid during the handler only: the program clones what it keeps (an Id is a value: keep it as it is).
Message :: struct {
	kind:   Kind,
	method: string,       // Request, Notification
	params: json.Value,   // Request, Notification (nil: none)
	id:     Id,           // Request: the child's, for reply; Reply: the program's call's (a number)
	ok:     bool,         // Reply: `result` holds the answer; else `error` or `local` says why not
	result: json.Value,
	error:  Error_Object,
	local:  Local,
	tag:    u64,          // Reply: what the call was given
	user:   rawptr,
	text:   string,       // the message's JSON text; Bad: its first BAD_TEXT_MAX bytes
	bad:    Bad_Kind,
	size:   int,          // the message's bytes (Bad: the whole length)
	end:    End,          // Ended
	// (the peer's)
	arena:  mem.Dynamic_Arena,
	bytes:  int,
}

// Why a send did not go.
Send_Error :: enum u8 {
	None,
	Full,    // outbound_max bytes wait already
	Ended,   // the peer stops or has ended
}

// A message's handler, on drain's thread.
Handler :: #type proc(peer: ^Peer, m: ^Message, user: rawptr)

// Where the peer is (rpc.md, "The end, as a state machine").
State :: enum u8 { Starting, Running, Stopping, Ending, Ended }

Stats :: struct {
	sent:     int,   // messages written
	received: int,   // messages read (a batch's each)
	dropped:  int,   // answers to no pending request (timed out, unknown)
	bad:      int,
}
