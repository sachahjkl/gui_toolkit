// Package winrt: what a program needs to call Windows Runtime APIs from Odin, with no projection: strings (HSTRING),
// activation factories, the interface IDs of generic types (IAsyncOperation<T>, its completion handler, EventHandler<T>),
// waiting for an asynchronous operation, an event handler of the program's own, and read-only vectors.
//
// The interface ID of a generic instance is not in any header: Windows computes it from the type's signature (a UUID
// version 5, SHA-1, in the WinRT namespace). piid_of does the same; the signatures come from sig_* below. This part is
// pure and runs on every system (tests/winrt checks known IDs); the calls themselves are in winrt_windows.odin.
package tk_winrt

import "core:crypto/legacy/sha1"
import "core:fmt"
import "core:strings"

GUID :: struct {
	data1: u32,
	data2: u16,
	data3: u16,
	data4: [8]u8,
}

// The generic interfaces of Windows.Foundation, by their own ID (what their instances' IDs are computed from).
PIID_IAsyncOperation                :: GUID{0x9fc2b0bb, 0xe446, 0x44e2, {0xaa, 0x61, 0x9c, 0xab, 0x8f, 0x63, 0x6a, 0xf2}}
PIID_AsyncOperationCompletedHandler :: GUID{0xfcdcf02c, 0xe5d8, 0x4478, {0x91, 0x5a, 0x4d, 0x90, 0xb7, 0x4b, 0x83, 0xa5}}
PIID_EventHandler                   :: GUID{0x9de1c535, 0x6ae1, 0x11e0, {0x84, 0xe1, 0x18, 0xa9, 0x05, 0xbc, 0xc5, 0x3f}}
PIID_IVectorView                    :: GUID{0xbbe1fa4c, 0xb0e3, 0x4583, {0xba, 0xef, 0x1f, 0x1b, 0x2e, 0x48, 0x3e, 0x56}}

// The namespace of the IDs of generic instances: 11f47ad5-7b73-42c0-abae-878b1e16adee.
@(private, rodata)
PINTERFACE_NAMESPACE := [16]u8{0x11, 0xf4, 0x7a, 0xd5, 0x7b, 0x73, 0x42, 0xc0, 0xab, 0xae, 0x87, 0x8b, 0x1e, 0x16, 0xad, 0xee}

// The text of a GUID as signatures write it: lower case, in braces.
guid_string :: proc(g: GUID, allocator := context.temp_allocator) -> string {
	d := g.data4
	return fmt.aprintf("{{%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x}}", g.data1, g.data2, g.data3,
		d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7], allocator = allocator)
}

// The signature of a runtime class: its full name and its default interface.
sig_class :: proc(name: string, default_interface: GUID, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("rc(%s;%s)", name, guid_string(default_interface), allocator = allocator)
}

// The signature of an interface: its ID.
sig_interface :: proc(iid: GUID, allocator := context.temp_allocator) -> string { return guid_string(iid, allocator) }

// The signature of a generic instance: the generic's ID and its arguments' signatures.
sig_generic :: proc(piid: GUID, args: ..string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "pinterface(%s", guid_string(piid))
	for a in args { fmt.sbprintf(&b, ";%s", a) }
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// The signatures of the fundamental types this package uses.
SIG_STRING :: "string"

// The interface ID of a type by its signature, as Windows computes it: SHA-1 of the namespace and the UTF-8 signature,
// the first 16 bytes read big-endian, version 5, variant RFC 4122.
piid_of :: proc(signature: string) -> GUID {
	ctx: sha1.Context
	sha1.init(&ctx)
	ns := PINTERFACE_NAMESPACE
	sha1.update(&ctx, ns[:])
	sha1.update(&ctx, transmute([]u8)signature)
	sum: [sha1.DIGEST_SIZE]u8
	sha1.final(&ctx, sum[:])
	sum[6] = (sum[6] & 0x0f) | 0x50
	sum[8] = (sum[8] & 0x3f) | 0x80
	return GUID{
		data1 = u32(sum[0]) << 24 | u32(sum[1]) << 16 | u32(sum[2]) << 8 | u32(sum[3]),
		data2 = u16(sum[4]) << 8 | u16(sum[5]),
		data3 = u16(sum[6]) << 8 | u16(sum[7]),
		data4 = {sum[8], sum[9], sum[10], sum[11], sum[12], sum[13], sum[14], sum[15]},
	}
}

// The IDs of IAsyncOperation<T> and of its completion handler, for T of signature `result`.
async_iids :: proc(result: string) -> (operation, handler: GUID) {
	return piid_of(sig_generic(PIID_IAsyncOperation, result)), piid_of(sig_generic(PIID_AsyncOperationCompletedHandler, result))
}

// The ID of EventHandler<T>, for T of signature `args`.
event_handler_iid :: proc(args: string) -> GUID { return piid_of(sig_generic(PIID_EventHandler, args)) }
