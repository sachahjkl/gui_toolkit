// Package remote: a value read from a server, and how its reading stands. One machine for every reading a program makes:
//
//	Idle ──begin──▶ Loading ──settle──▶ Ready | Refused | Failed
//	  ▲                │ begin again: a new ticket, the old answer no longer counts
//	  └────reset───────┘
//
// A request carries the ticket `begin` gave; its answer counts only while that ticket is the current one (`current`, `answer`):
// an answer of a reading given up (asked again, reset, another server) is dropped before anything reads it.
//
//	x: remote.Remote                                 // where it does not move: a request keeps its address
//	ticket := remote.begin(&x)                       // then send, with the ticket
//	...
//	if remote.answer(&x, ticket, .Ready) { use(body) }   // false: a stale answer, dropped
//
// The words a program shows for each state, and its Try again, are the program's. No thread: one thread owns a Remote.
package tk_remote

import "core:strings"

State :: enum u8 {
	Idle,      // nothing read, nothing on its way
	Loading,   // a reading on its way
	Ready,     // read
	Refused,   // the server said no: `message` is its words
	Failed,    // it did not answer, or not in a way that can be read: `message` says why
}

Remote :: struct {
	state:   State,
	ticket:  u64,      // of the last reading: an answer with another one is of a reading given up
	message: string,   // why it did not end well (owned)
	known:   bool,     // something was read since the last reset: a reading again leaves it on screen until it ends
}

// A new reading: what was on its way no longer counts. The ticket goes with the request.
begin :: proc(x: ^Remote) -> (ticket: u64) {
	x.ticket += 1
	settle(x, .Loading, "")
	return x.ticket
}

// Nothing read, nothing on its way (the server changed; a dialog opened on something else).
reset :: proc(x: ^Remote) {
	x.ticket += 1
	x.known = false
	settle(x, .Idle, "")
}

// The reading ends in `state` (its ticket checked by the caller: `current`, or use `answer`).
settle :: proc(x: ^Remote, state: State, message: string) {
	delete(x.message)
	x.state = state
	x.message = strings.clone(message)
	if state == .Ready { x.known = true }
}

// Whether an answer of `ticket` is of the reading on its way, not of one given up.
current :: proc(x: ^Remote, ticket: u64) -> bool { return x.ticket == ticket }

// An answer of `ticket`: it settles the reading when it is the current one. false: a stale answer, nothing changed.
answer :: proc(x: ^Remote, ticket: u64, state: State, message := "") -> bool {
	if !current(x, ticket) { return false }
	settle(x, state, message)
	return true
}

// What was read is what is on screen: it came, or it is being read again.
shows :: proc(x: ^Remote) -> bool { return x.state == .Ready || (x.state == .Loading && x.known) }

// It ended badly, and what it says is all there is.
failed :: proc(x: ^Remote) -> bool { return x.state == .Failed || x.state == .Refused }

// Its message freed; the ticket kept, so that an answer still on its way does not match a count started over.
destroy :: proc(x: ^Remote) {
	delete(x.message)
	x^ = {ticket = x.ticket + 1}
}
