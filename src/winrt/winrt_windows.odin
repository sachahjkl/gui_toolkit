#+build windows
package tk_winrt

// The calls: the runtime of the thread, strings, factories, waiting for an operation, an event handler, vectors. Every
// vtable lists its methods in the order of the SDK's headers (windows.foundation.h, windows.foundation.collections.h):
// the offsets are what matters.

import "base:runtime"
import "core:sync"
import win "core:sys/windows"
import "core:unicode/utf16"

HRESULT :: win.HRESULT
HSTRING :: distinct rawptr

S_OK          :: HRESULT(0)
E_NOINTERFACE :: HRESULT(-2147467262)   // 0x80004002
E_TIMEOUT     :: HRESULT(-2147023436)   // 0x800705B4: HRESULT_FROM_WIN32(ERROR_TIMEOUT)
E_ABORT       :: HRESULT(-2147467260)   // 0x80004004: the operation was cancelled
RPC_E_CHANGED_MODE :: HRESULT(-2147417850)   // 0x80010106: the thread's apartment is already of the other kind

foreign import runtimeobject "system:runtimeobject.lib"

@(default_calling_convention = "system", private)
foreign runtimeobject {
	RoInitialize              :: proc(init_type: i32) -> HRESULT ---
	RoUninitialize            :: proc() ---
	RoGetActivationFactory    :: proc(class_id: HSTRING, iid: ^GUID, factory: ^rawptr) -> HRESULT ---
	RoActivateInstance        :: proc(class_id: HSTRING, instance: ^rawptr) -> HRESULT ---
	WindowsCreateString       :: proc(s: [^]u16, length: u32, out: ^HSTRING) -> HRESULT ---
	WindowsDeleteString       :: proc(s: HSTRING) -> HRESULT ---
	WindowsGetStringRawBuffer :: proc(s: HSTRING, length: ^u32) -> [^]u16 ---
}

foreign import ole32 "system:ole32.lib"

@(default_calling_convention = "system", private)
foreign ole32 {
	CoWaitForMultipleHandles :: proc(flags: u32, timeout: u32, count: u32, handles: [^]win.HANDLE, index: ^u32) -> HRESULT ---
}

@(private) RO_INIT_SINGLETHREADED :: 0
@(private) RO_INIT_MULTITHREADED  :: 1

// The apartment a thread joins (init). Most APIs work in both; some only in one (the clipboard's: Single, else
// RO_E_UNSUPPORTED_FROM_MTA). A Single thread must pump its messages (a window's loop, MsgWaitForMultipleObjects).
Apartment :: enum u8 { Multi, Single }

IID_IUnknown    :: GUID{0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
IID_IAgileObject :: GUID{0x94ea2b94, 0xe9cc, 0x49e0, {0xc0, 0xff, 0xee, 0x64, 0xca, 0x8f, 0x5b, 0x90}}
IID_IAsyncInfo  :: GUID{0x00000036, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}

// The first methods of every Windows Runtime interface.
IInspectable_Vtbl :: struct {
	QueryInterface:      proc "system" (this: rawptr, riid: ^GUID, out: ^rawptr) -> HRESULT,
	AddRef:              proc "system" (this: rawptr) -> u32,
	Release:             proc "system" (this: rawptr) -> u32,
	GetIids:             rawptr,
	GetRuntimeClassName: rawptr,
	GetTrustLevel:       rawptr,
}

// The vtable of an interface pointer, as `T` (a struct that starts with `using base: IInspectable_Vtbl`).
vtable :: #force_inline proc(object: rawptr, $T: typeid) -> ^T { return (^^T)(object)^ }

ok :: #force_inline proc(hr: HRESULT) -> bool { return hr >= 0 }

// Joins the thread to an apartment (once per thread that calls Windows Runtime APIs). What RoInitialize answered: S_OK,
// or S_FALSE when the thread was in it already. A thread in the other kind already: RPC_E_CHANGED_MODE (it stays there).
init :: proc(apartment := Apartment.Multi) -> HRESULT {
	return RoInitialize(apartment == .Single ? RO_INIT_SINGLETHREADED : RO_INIT_MULTITHREADED)
}

// Leaves the apartment (after init, on the same thread, once every object of the thread is released).
uninit :: proc() { RoUninitialize() }

release :: proc(object: rawptr) {
	if object != nil { vtable(object, IInspectable_Vtbl).Release(object) }
}

// The interface `iid` of an object (owned: release it), nil when it has none.
query :: proc(object: rawptr, iid: GUID) -> rawptr {
	if object == nil { return nil }
	id := iid
	out: rawptr
	if !ok(vtable(object, IInspectable_Vtbl).QueryInterface(object, &id, &out)) { return nil }
	return out
}

////////////////////////////////
// Strings

// An HSTRING of `s` (owned: string_delete). nil for "" (the empty HSTRING is nil).
string_make :: proc(s: string) -> HSTRING {
	if s == "" { return nil }
	buf := make([]u16, len(s) + 1, context.temp_allocator)
	n := utf16.encode_string(buf, s)
	h: HSTRING
	if !ok(WindowsCreateString(raw_data(buf), u32(n), &h)) { return nil }
	return h
}

string_delete :: proc(h: HSTRING) { if h != nil { WindowsDeleteString(h) } }

// The text of an HSTRING, in UTF-8.
string_read :: proc(h: HSTRING, allocator := context.allocator) -> string {
	if h == nil { return "" }
	n: u32
	p := WindowsGetStringRawBuffer(h, &n)
	if p == nil || n == 0 { return "" }
	s, _ := win.utf16_to_utf8(p[:n], allocator)
	return s
}

////////////////////////////////
// Classes

// The activation factory of a runtime class, or its statics, as the interface `iid` (owned: release it).
factory :: proc(class_name: string, iid: GUID) -> (object: rawptr, hr: HRESULT) {
	name := string_make(class_name)
	defer string_delete(name)
	id := iid
	hr = RoGetActivationFactory(name, &id, &object)
	return
}

// A new instance of a runtime class with a default constructor, as its default interface (owned: release it).
activate :: proc(class_name: string) -> (object: rawptr, hr: HRESULT) {
	name := string_make(class_name)
	defer string_delete(name)
	hr = RoActivateInstance(name, &object)
	return
}

////////////////////////////////
// Asynchronous operations

// IAsyncOperation<T>: its completion handler goes in, its result comes out.
IAsyncOperation_Vtbl :: struct {
	using base:    IInspectable_Vtbl,
	put_Completed: proc "system" (this: rawptr, handler: rawptr) -> HRESULT,
	get_Completed: rawptr,
	GetResults:    proc "system" (this: rawptr, result: rawptr) -> HRESULT,
}

IAsyncInfo_Vtbl :: struct {
	using base:    IInspectable_Vtbl,
	get_Id:        rawptr,
	get_Status:    proc "system" (this: rawptr, status: ^Async_Status) -> HRESULT,
	get_ErrorCode: proc "system" (this: rawptr, code: ^HRESULT) -> HRESULT,
	Cancel:        proc "system" (this: rawptr) -> HRESULT,
	Close:         proc "system" (this: rawptr) -> HRESULT,
}

Async_Status :: enum i32 { Started = 0, Completed = 1, Canceled = 2, Error = 3 }

// How long await waits by default before it cancels the operation.
AWAIT_MS :: 10_000

// The completion handler await gives an operation: it sets an event. Shared with the operation, which may call it on
// any thread and release it after await returned: counted.
@(private)
Completion :: struct {
	vtbl:   ^Completion_Vtbl,
	refs:   i32,
	iid:    GUID,
	event:  win.HANDLE,
	status: Async_Status,
}

@(private)
Completion_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^Completion, riid: ^GUID, out: ^rawptr) -> HRESULT,
	AddRef:         proc "system" (this: ^Completion) -> u32,
	Release:        proc "system" (this: ^Completion) -> u32,
	Invoke:         proc "system" (this: ^Completion, operation: rawptr, status: Async_Status) -> HRESULT,
}

@(private, rodata)
COMPLETION_VTBL := Completion_Vtbl{
	QueryInterface = proc "system" (this: ^Completion, riid: ^GUID, out: ^rawptr) -> HRESULT {
		if riid^ == this.iid || riid^ == IID_IUnknown || riid^ == IID_IAgileObject {
			sync.atomic_add(&this.refs, 1)
			out^ = this
			return S_OK
		}
		out^ = nil
		return E_NOINTERFACE
	},
	AddRef = proc "system" (this: ^Completion) -> u32 { return u32(sync.atomic_add(&this.refs, 1) + 1) },
	Release = proc "system" (this: ^Completion) -> u32 {
		left := sync.atomic_sub(&this.refs, 1) - 1
		if left == 0 {
			context = runtime.default_context()
			win.CloseHandle(this.event)
			free(this, runtime.heap_allocator())
		}
		return u32(left)
	},
	Invoke = proc "system" (this: ^Completion, operation: rawptr, status: Async_Status) -> HRESULT {
		sync.atomic_store(&this.status, status)
		win.SetEvent(this.event)
		return S_OK
	},
}

// Waits for the operation `operation`. The thread keeps taking the COM calls made to it while it waits
// (CoWaitForMultipleHandles): a single-threaded apartment's objects stay reachable. (an IAsyncOperation<T>, whose completion handler's ID is `handler_iid`: see
// async_iids) and writes its result to `result` (a T: an interface pointer or an HSTRING, owned by the caller then).
// The operation is released. Past `timeout_ms` it is cancelled: E_TIMEOUT. A failed operation gives its error.
await :: proc(operation: rawptr, handler_iid: GUID, result: rawptr, timeout_ms: u32 = AWAIT_MS) -> HRESULT {
	if operation == nil { return E_ABORT }
	defer release(operation)
	c := new(Completion, runtime.heap_allocator())
	c^ = {vtbl = &COMPLETION_VTBL, refs = 1, iid = handler_iid, event = win.CreateEventW(nil, true, false, nil)}
	defer COMPLETION_VTBL.Release(c)
	if c.event == nil { return E_ABORT }
	op := vtable(operation, IAsyncOperation_Vtbl)
	if hr := op.put_Completed(operation, c); !ok(hr) { return hr }
	handles := [1]win.HANDLE{c.event}
	index: u32
	if !ok(CoWaitForMultipleHandles(0, timeout_ms, 1, &handles[0], &index)) {
		if info := query(operation, IID_IAsyncInfo); info != nil {
			vtable(info, IAsyncInfo_Vtbl).Cancel(info)
			release(info)
		}
		return E_TIMEOUT
	}
	switch sync.atomic_load(&c.status) {
	case .Completed:
		return op.GetResults(operation, result)
	case .Error:
		code := E_ABORT
		if info := query(operation, IID_IAsyncInfo); info != nil {
			vtable(info, IAsyncInfo_Vtbl).get_ErrorCode(info, &code)
			release(info)
		}
		return code
	case .Canceled, .Started:
	}
	return E_ABORT
}

////////////////////////////////
// Events

// An event handler of the program's own (an EventHandler<T>, a TypedEventHandler<S, T>, or any delegate whose Invoke
// takes two pointers): it calls `callback` with `user` and the event's sender and arguments (borrowed: valid during the
// call), on the thread the source raises the event on. Counted: the source keeps its own reference; `done` (nil: none)
// runs once the last reference went, so that what `user` points to can be freed then.
Event_Handler :: struct {
	vtbl:     ^Event_Handler_Vtbl,
	refs:     i32,
	iid:      GUID,
	callback: proc(user: rawptr, sender: rawptr, args: rawptr),
	done:     proc(user: rawptr),
	user:     rawptr,
}

@(private)
Event_Handler_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^Event_Handler, riid: ^GUID, out: ^rawptr) -> HRESULT,
	AddRef:         proc "system" (this: ^Event_Handler) -> u32,
	Release:        proc "system" (this: ^Event_Handler) -> u32,
	Invoke:         proc "system" (this: ^Event_Handler, sender: rawptr, args: rawptr) -> HRESULT,
}

@(private, rodata)
EVENT_HANDLER_VTBL := Event_Handler_Vtbl{
	QueryInterface = proc "system" (this: ^Event_Handler, riid: ^GUID, out: ^rawptr) -> HRESULT {
		if riid^ == this.iid || riid^ == IID_IUnknown || riid^ == IID_IAgileObject {
			sync.atomic_add(&this.refs, 1)
			out^ = this
			return S_OK
		}
		out^ = nil
		return E_NOINTERFACE
	},
	AddRef = proc "system" (this: ^Event_Handler) -> u32 { return u32(sync.atomic_add(&this.refs, 1) + 1) },
	Release = proc "system" (this: ^Event_Handler) -> u32 {
		left := sync.atomic_sub(&this.refs, 1) - 1
		if left == 0 {
			context = runtime.default_context()
			if this.done != nil { this.done(this.user) }
			free(this, runtime.heap_allocator())
		}
		return u32(left)
	},
	Invoke = proc "system" (this: ^Event_Handler, sender: rawptr, args: rawptr) -> HRESULT {
		context = runtime.default_context()
		this.callback(this.user, sender, args)
		return S_OK
	},
}

// A handler of ID `iid` (see event_handler_iid, typed_event_handler_iid) that calls `callback(user, sender, args)`.
// Give it to the source's add method, then release it: the source keeps it until its remove method. `done(user)` runs
// when the last reference goes (nil: nothing to do).
event_handler_make :: proc(iid: GUID, callback: proc(user: rawptr, sender: rawptr, args: rawptr), user: rawptr, done: proc(user: rawptr) = nil) -> ^Event_Handler {
	h := new(Event_Handler, runtime.heap_allocator())
	h^ = {vtbl = &EVENT_HANDLER_VTBL, refs = 1, iid = iid, callback = callback, done = done, user = user}
	return h
}

////////////////////////////////
// Vectors

// IVectorView<T>.
IVectorView_Vtbl :: struct {
	using base: IInspectable_Vtbl,
	GetAt:      proc "system" (this: rawptr, index: u32, item: rawptr) -> HRESULT,
	get_Size:   proc "system" (this: rawptr, size: ^u32) -> HRESULT,
	IndexOf:    rawptr,
	GetMany:    rawptr,
}

vector_size :: proc(vector: rawptr) -> (n: u32) {
	if vector == nil { return 0 }
	if !ok(vtable(vector, IVectorView_Vtbl).get_Size(vector, &n)) { return 0 }
	return
}

// The item `index` of a vector, written to `item` (a T: an interface pointer or an HSTRING, owned by the caller then).
vector_at :: proc(vector: rawptr, index: u32, item: rawptr) -> HRESULT {
	return vtable(vector, IVectorView_Vtbl).GetAt(vector, index, item)
}
