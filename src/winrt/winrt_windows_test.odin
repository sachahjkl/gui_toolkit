#+build windows
package tk_winrt

import "core:fmt"
import "core:os"
import "core:testing"

// Windows.Storage.PathIO's statics: ReadTextAsync, an IAsyncOperation<HSTRING> with nothing to set up.
@(private = "file")
IID_IPathIOStatics :: GUID{0x0f2f3758, 0x8ec7, 0x4381, {0x92, 0x2b, 0x8f, 0x6c, 0x07, 0xd2, 0x88, 0xf3}}

@(private = "file")
IPathIOStatics_Vtbl :: struct {
	using base:    IInspectable_Vtbl,
	ReadTextAsync: proc "system" (this: rawptr, path: HSTRING, operation: ^rawptr) -> HRESULT,
}

// A string goes to an HSTRING and back; an operation is awaited and gives its result; one that fails gives its error.
@(test)
an_operation_is_awaited :: proc(t: ^testing.T) {
	testing.expect(t, init())
	defer uninit()

	h := string_make("héllo, wörld")
	testing.expect_value(t, string_read(h, context.temp_allocator), "héllo, wörld")
	string_delete(h)

	path := fmt.tprintf("%s\\tk_winrt_test_%d.txt", os.get_env("TEMP", context.temp_allocator), os.get_pid())
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("read by WinRT")) == nil)
	defer os.remove(path)

	statics, hr := factory("Windows.Storage.PathIO", IID_IPathIOStatics)
	testing.expectf(t, ok(hr), "PathIO's statics: %x", u32(hr))
	defer release(statics)
	_, handler := async_iids(SIG_STRING)

	hpath := string_make(path)
	defer string_delete(hpath)
	op: rawptr
	testing.expect(t, ok(vtable(statics, IPathIOStatics_Vtbl).ReadTextAsync(statics, hpath, &op)))
	text: HSTRING
	hr = await(op, handler, &text)
	testing.expectf(t, ok(hr), "awaited: %x", u32(hr))
	testing.expect_value(t, string_read(text, context.temp_allocator), "read by WinRT")
	string_delete(text)

	missing := string_make(fmt.tprintf("%s.missing", path))
	defer string_delete(missing)
	op = nil
	testing.expect(t, ok(vtable(statics, IPathIOStatics_Vtbl).ReadTextAsync(statics, missing, &op)))
	hr = await(op, handler, &text)
	testing.expect(t, !ok(hr), "a file that is not there: an error")
}
