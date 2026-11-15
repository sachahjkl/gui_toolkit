// Package tk_secrets: a secret (a password, a token) sealed for the user's account, so that a program keeps in its own
// file only a field that stands for it. Windows: DPAPI, the field holds the encrypted blob. Linux: the Secret Service
// (org.freedesktop.secrets over the session bus), the field names the item. Elsewhere there is no store.
// (Named tk_secrets: a program may have a `secrets` package of its own.)
//
// Every call may wait on the system (a D-Bus round trip, DPAPI): call it on a worker (gt:tasks), never in a frame. The
// package keeps no state: what a program remembers of the store (whether a service answered) is the program's.
//
// The package never writes a secret in clear. When seal is Unavailable, the program decides: keep the secret in clear
// and say so, or refuse.
//
//	field, sealed := secrets.seal("my-app", "server 1", password)
//	if sealed == .Unavailable { /* the program's choice */ }
//	password, opened := secrets.open("my-app", field)
//
// See docs/secrets.md and src/md/features/secrets.md.
package tk_secrets

import "core:strings"

// What seal did.
Seal_Result :: enum u8 {
	Sealed,        // the field stands for the secret
	Unavailable,   // no store here now: no Secret Service, a locked keyring, a system without one
}

// What open found.
Open_Result :: enum u8 {
	Opened,       // the secret is returned
	Not_Sealed,   // the field is not seal's work (a value in clear): the caller decides what it is
	Refused,      // it is seal's work, but cannot be opened here (another account or system, a locked keyring, the item gone)
}

// The start of a field that DPAPI sealed: the base64 of the blob follows.
DPAPI_MARK :: "dpapi:v1:"
// The start of a field kept in the Secret Service: the secret's name follows, so a renamed thing keeps its item.
SERVICE_MARK :: "secret-service:v1:"

// Seals `secret` for the user's account. `app` names the program, `name` the secret within it (Linux: the item's
// attributes and its label "<app>: <name>"; Windows: unused). `field` is allocated with `allocator`; "" when Unavailable.
// Blocks on the system: call it on a worker.
seal :: proc(app, name, secret: string, allocator := context.allocator) -> (field: string, result: Seal_Result) {
	return seal_system(app, name, secret, allocator)
}

// The secret a field of seal stands for. `secret` is allocated with `allocator`; "" unless Opened. Blocks on the system:
// call it on a worker.
open :: proc(app, field: string, allocator := context.allocator) -> (secret: string, result: Open_Result) {
	if !is_sealed(field) { return "", .Not_Sealed }
	return open_system(app, field, allocator)
}

// Takes the secret a field stands for out of the store (Linux: deletes the service's item; Windows: nothing, the field
// holds it). A field that is not seal's work is left alone. Blocks on the system: call it on a worker.
forget :: proc(app, field: string) {
	if !is_sealed(field) { return }
	forget_system(app, field)
}

// Whether seal can store here now (Linux: a Secret Service answers; a locked keyring still answers, and seal then says
// Unavailable). Blocks on the system: call it on a worker.
available :: proc() -> bool { return available_system() }

// Whether a field is seal's work, on any system: a field of the other system's mark is Refused, never taken for a value
// in clear.
is_sealed :: proc(field: string) -> bool {
	return strings.has_prefix(field, DPAPI_MARK) || strings.has_prefix(field, SERVICE_MARK)
}
