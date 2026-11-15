package tk_secrets

// DPAPI, current user: the field holds the blob, which only this Windows account can open. No item to forget, nothing
// to start: the store is always there.

import "core:encoding/base64"
import "core:mem"
import "core:strings"
import win "core:sys/windows"

foreign import crypt32 "system:Crypt32.lib"

@(private = "file")
Data_Blob :: struct {
	size: u32,
	data: [^]u8,
}

@(default_calling_convention = "system", private = "file")
foreign crypt32 {
	CryptProtectData :: proc(data_in: ^Data_Blob, description: cstring16, entropy: ^Data_Blob, reserved, prompt: rawptr, flags: u32, data_out: ^Data_Blob) -> win.BOOL ---
	CryptUnprotectData :: proc(data_in: ^Data_Blob, description: ^cstring16, entropy: ^Data_Blob, reserved, prompt: rawptr, flags: u32, data_out: ^Data_Blob) -> win.BOOL ---
}

// (No dialog: the call runs on a worker, where a prompt would wait for nobody.)
@(private = "file") CRYPTPROTECT_UI_FORBIDDEN :: u32(0x1)

@(private)
seal_system :: proc(app, name, secret: string, allocator := context.allocator) -> (field: string, result: Seal_Result) {
	plain := Data_Blob{u32(len(secret)), raw_data(transmute([]u8)secret)}
	out: Data_Blob
	if !CryptProtectData(&plain, nil, nil, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, &out) { return "", .Unavailable }
	defer win.LocalFree(out.data)
	text, err := base64.encode(out.data[:out.size], allocator = context.temp_allocator)
	if err != nil { return "", .Unavailable }
	return strings.concatenate({DPAPI_MARK, text}, allocator), .Sealed
}

@(private)
open_system :: proc(app, field: string, allocator := context.allocator) -> (secret: string, result: Open_Result) {
	if !strings.has_prefix(field, DPAPI_MARK) { return "", .Refused }   // (the Secret Service's: another system)
	data, err := base64.decode(field[len(DPAPI_MARK):], allocator = context.temp_allocator)
	if err != nil || len(data) == 0 { return "", .Refused }
	blob := Data_Blob{u32(len(data)), raw_data(data)}
	out: Data_Blob
	if !CryptUnprotectData(&blob, nil, nil, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, &out) { return "", .Refused }
	defer win.LocalFree(out.data)
	secret = strings.clone(string(out.data[:out.size]), allocator)
	// (the system's copy goes back to the heap: no secret left in memory nobody owns)
	mem.zero_explicit(out.data, int(out.size))
	return secret, .Opened
}

@(private)
forget_system :: proc(app, field: string) {}

@(private)
available_system :: proc() -> bool { return true }
