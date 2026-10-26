#+build windows
package platform

// Drag and drop on Windows (dragdrop.odin has the API): the window's IDropTarget (OLE, RegisterDragDrop) turns the
// system's drag callbacks into Drop_* events; drag_start fills a shell data object (SHCreateDataObject) and runs
// SHDoDragDrop with the shell's default drop source. The drag image of the system (IDropTargetHelper,
// IDragSourceHelper) follows the pointer over the window and from it.
//
// Formats read and written: CF_HDROP (files), CF_UNICODETEXT, "HTML Format" (UTF-8 with the CF_HTML header),
// "UniformResourceLocatorW" (a link; also its ANSI form when reading), "PNG" (an image), and one private format with the
// app's own MIME types ("gui_toolkit drag entries", drag_custom_encode).

import "base:runtime"
import "core:time"
import win "core:sys/windows"

@(private) POINTL :: struct { x, y: i32 }

@(private) FORMATETC :: struct {
	cfFormat: u16,
	ptd:      rawptr,
	dwAspect: u32,
	lindex:   i32,
	tymed:    u32,
}

@(private) STGMEDIUM :: struct {
	tymed:          u32,
	hGlobal:        win.HGLOBAL,   // (a union: the other members are never used here)
	pUnkForRelease: rawptr,
}

@(private) DVASPECT_CONTENT :: 1
@(private) TYMED_HGLOBAL :: 1
@(private) CF_UNICODETEXT :: 13
@(private) CF_HDROP :: 15
@(private) DROPEFFECT_COPY :: 1
@(private) DROPEFFECT_MOVE :: 2
@(private) DROPEFFECT_LINK :: 4
@(private) DRAGDROP_S_DROP :: 0x0004_0100
@(private) MK_LBUTTON :: 0x1
@(private) MK_SHIFT :: 0x4
@(private) MK_CONTROL :: 0x8
@(private) MK_ALT :: 0x20

@(private) IDataObject_VTable :: struct {
	QueryInterface:        proc "system" (this: ^IDataObject, riid: ^win.GUID, ppv: ^rawptr) -> win.HRESULT,
	AddRef:                proc "system" (this: ^IDataObject) -> u32,
	Release:               proc "system" (this: ^IDataObject) -> u32,
	GetData:               proc "system" (this: ^IDataObject, fmt: ^FORMATETC, medium: ^STGMEDIUM) -> win.HRESULT,
	GetDataHere:           rawptr,
	QueryGetData:          proc "system" (this: ^IDataObject, fmt: ^FORMATETC) -> win.HRESULT,
	GetCanonicalFormatEtc: rawptr,
	SetData:               proc "system" (this: ^IDataObject, fmt: ^FORMATETC, medium: ^STGMEDIUM, release: win.BOOL) -> win.HRESULT,
	EnumFormatEtc:         rawptr,
	DAdvise:               rawptr,
	DUnadvise:             rawptr,
	EnumDAdvise:           rawptr,
}
@(private) IDataObject :: struct { vt: ^IDataObject_VTable }

@(private) IDropTargetHelper_VTable :: struct {
	QueryInterface: rawptr,
	AddRef:         rawptr,
	Release:        proc "system" (this: ^IDropTargetHelper) -> u32,
	DragEnter:      proc "system" (this: ^IDropTargetHelper, hwnd: win.HWND, data: ^IDataObject, pt: ^win.POINT, effect: u32) -> win.HRESULT,
	DragLeave:      proc "system" (this: ^IDropTargetHelper) -> win.HRESULT,
	DragOver:       proc "system" (this: ^IDropTargetHelper, pt: ^win.POINT, effect: u32) -> win.HRESULT,
	Drop:           proc "system" (this: ^IDropTargetHelper, data: ^IDataObject, pt: ^win.POINT, effect: u32) -> win.HRESULT,
	Show:           rawptr,
}
@(private) IDropTargetHelper :: struct { vt: ^IDropTargetHelper_VTable }

@(private) SHDRAGIMAGE :: struct {
	sizeDragImage: win.SIZE,
	ptOffset:      win.POINT,
	hbmpDragImage: win.HBITMAP,
	crColorKey:    u32,
}

@(private) IDragSourceHelper_VTable :: struct {
	QueryInterface:        rawptr,
	AddRef:                rawptr,
	Release:               proc "system" (this: ^IDragSourceHelper) -> u32,
	InitializeFromBitmap:  proc "system" (this: ^IDragSourceHelper, img: ^SHDRAGIMAGE, data: ^IDataObject) -> win.HRESULT,
	InitializeFromWindow:  rawptr,
}
@(private) IDragSourceHelper :: struct { vt: ^IDragSourceHelper_VTable }

@(private) Drop_Target_VTable :: struct {
	QueryInterface: proc "system" (this: ^Drop_Target, riid: ^win.GUID, ppv: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: ^Drop_Target) -> u32,
	Release:        proc "system" (this: ^Drop_Target) -> u32,
	DragEnter:      proc "system" (this: ^Drop_Target, data: ^IDataObject, keys: u32, pt: POINTL, effect: ^u32) -> win.HRESULT,
	DragOver:       proc "system" (this: ^Drop_Target, keys: u32, pt: POINTL, effect: ^u32) -> win.HRESULT,
	DragLeave:      proc "system" (this: ^Drop_Target) -> win.HRESULT,
	Drop:           proc "system" (this: ^Drop_Target, data: ^IDataObject, keys: u32, pt: POINTL, effect: ^u32) -> win.HRESULT,
}

// The window's IDropTarget. Owned by the window (Dnd_State): OLE's references only keep it registered.
@(private) Drop_Target :: struct {
	vt:   ^Drop_Target_VTable,
	refs: i32,
	w:    ^Window,
}

// What a window keeps for drag and drop (Native_Window.dnd, made on first use).
@(private) Dnd_State :: struct {
	target:     Drop_Target,
	registered: bool,
	data:       Drag_Data,     // the drag over the window, or the last one dropped (until the next enters)
	effect:     Maybe(Drop_Effect),   // the app's answer (drop_set_effect)
	allowed:    Drop_Effects,  // the source's
	over:       bool,          // between Drop_Enter and Drop_Leave / Drop
	helper:     ^IDropTargetHelper,
	sending:    bool,          // drag_start runs from this window
	allocator:  runtime.Allocator,   // the app's, when the state was made: `data` lives in it (the system's callbacks have no context)
	sync:       Drop_Sync,     // drop_sync_set: asked at once while drag_start runs from this window
	sync_user:  rawptr,
	script:     [dynamic]Drag_Step,   // drag_script: the next drag_start follows these steps instead of the mouse
	image_size:   [2]int,      // what the system's drag image helper holds for the last drag_start (drag_image_held)
	image_offset: [2]int,
	image_held:   bool,
}

@(private) IID_IUnknown := win.GUID{0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
@(private) IID_IDropTarget := win.GUID{0x00000122, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
@(private) IID_IDataObject := win.GUID{0x0000010e, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
@(private) CLSID_DragDropHelper := win.GUID{0x4657278A, 0x411B, 0x11D2, {0x83, 0x9A, 0x00, 0xC0, 0x4F, 0xD9, 0x18, 0xD0}}
@(private) IID_IDropTargetHelper := win.GUID{0x4657278B, 0x411B, 0x11D2, {0x83, 0x9A, 0x00, 0xC0, 0x4F, 0xD9, 0x18, 0xD0}}
@(private) IID_IDragSourceHelper := win.GUID{0xDE5BF786, 0x477A, 0x11D2, {0x83, 0x9D, 0x00, 0xC0, 0x4F, 0xD9, 0x18, 0xD0}}

foreign import ole32_dnd "system:Ole32.lib"
@(default_calling_convention = "system", private)
foreign ole32_dnd {
	OleInitialize    :: proc(reserved: rawptr) -> win.HRESULT ---
	RegisterDragDrop :: proc(hwnd: win.HWND, target: rawptr) -> win.HRESULT ---
	RevokeDragDrop   :: proc(hwnd: win.HWND) -> win.HRESULT ---
	ReleaseStgMedium :: proc(medium: ^STGMEDIUM) ---
}

foreign import shell32_dnd "system:Shell32.lib"
@(default_calling_convention = "system", private)
foreign shell32_dnd {
	SHCreateDataObject :: proc(folder: rawptr, cidl: u32, apidl: rawptr, inner: rawptr, riid: ^win.GUID, ppv: ^rawptr) -> win.HRESULT ---
	SHDoDragDrop       :: proc(hwnd: win.HWND, data: rawptr, source: rawptr, ok_effects: u32, effect: ^u32) -> win.HRESULT ---
}

@(private) drop_target_vtable := Drop_Target_VTable{
	QueryInterface = proc "system" (this: ^Drop_Target, riid: ^win.GUID, ppv: ^rawptr) -> win.HRESULT {
		if riid^ == IID_IUnknown || riid^ == IID_IDropTarget {
			ppv^ = this
			this.refs += 1
			return win.S_OK
		}
		ppv^ = nil
		return win.HRESULT(transmute(i32)u32(0x8000_4002))   // E_NOINTERFACE
	},
	AddRef = proc "system" (this: ^Drop_Target) -> u32 { this.refs += 1; return u32(this.refs) },
	Release = proc "system" (this: ^Drop_Target) -> u32 { this.refs = max(this.refs - 1, 0); return u32(this.refs) },
	DragEnter = proc "system" (this: ^Drop_Target, data: ^IDataObject, keys: u32, pt: POINTL, effect: ^u32) -> win.HRESULT {
		context = dnd_context(this)
		w := this.w
		d := w.dnd
		drag_data_destroy(&d.data)
		d.data = read_data_object(data)
		d.allowed = effects_from_win(effect^)
		d.over = true
		d.effect = nil   // a new drag: nothing accepted until the app says so
		pos := client_point(w, pt)
		effect^ = deliver(w, .Drop_Enter, pos, keys)
		if d.helper != nil { p := win.POINT{pt.x, pt.y}; d.helper.vt.DragEnter(d.helper, w.hwnd, data, &p, effect^) }
		return win.S_OK
	},
	DragOver = proc "system" (this: ^Drop_Target, keys: u32, pt: POINTL, effect: ^u32) -> win.HRESULT {
		context = dnd_context(this)
		w := this.w
		d := w.dnd
		d.allowed = effects_from_win(effect^)
		effect^ = deliver(w, .Drop_Over, client_point(w, pt), keys)
		if d.helper != nil { p := win.POINT{pt.x, pt.y}; d.helper.vt.DragOver(d.helper, &p, effect^) }
		return win.S_OK
	},
	DragLeave = proc "system" (this: ^Drop_Target) -> win.HRESULT {
		context = dnd_context(this)
		w := this.w
		d := w.dnd
		d.over = false
		deliver(w, .Drop_Leave, {}, 0)
		if d.helper != nil { d.helper.vt.DragLeave(d.helper) }
		return win.S_OK
	},
	Drop = proc "system" (this: ^Drop_Target, data: ^IDataObject, keys: u32, pt: POINTL, effect: ^u32) -> win.HRESULT {
		context = dnd_context(this)
		w := this.w
		d := w.dnd
		// the data again: a source may render some formats only now
		fresh := read_data_object(data)
		if !drag_data_empty(fresh) { drag_data_destroy(&d.data); d.data = fresh } else { drag_data_destroy(&fresh) }
		d.allowed = effects_from_win(effect^)
		d.over = false
		effect^ = deliver(w, .Drop, client_point(w, pt), keys)
		if d.helper != nil { p := win.POINT{pt.x, pt.y}; d.helper.vt.Drop(d.helper, data, &p, effect^) }
		return win.S_OK
	},
}

@(private)
dnd_state :: proc(w: ^Window) -> ^Dnd_State {
	if w.dnd == nil {
		w.dnd = new(Dnd_State)
		w.dnd.target = Drop_Target{vt = &drop_target_vtable, w = w}
		w.dnd.allocator = context.allocator
	}
	return w.dnd
}

// The context of a callback of the system: the app's allocator for the data it keeps.
@(private)
dnd_context :: proc "contextless" (t: ^Drop_Target) -> runtime.Context {
	c := runtime.default_context()
	if t.w != nil && t.w.dnd != nil { c.allocator = t.w.dnd.allocator }
	return c
}

@(private)
client_point :: proc(w: ^Window, pt: POINTL) -> [2]f32 {
	p := win.POINT{pt.x, pt.y}
	win.ScreenToClient(w.hwnd, &p)
	return {f32(p.x), f32(p.y)}
}

@(private)
mods_from_keys :: proc(keys: u32) -> (m: Modifiers) {
	if keys & MK_CONTROL != 0 { m += {.Ctrl} }
	if keys & MK_SHIFT != 0 { m += {.Shift} }
	if keys & MK_ALT != 0 { m += {.Alt} }
	return
}

// One callback of the system as an event: queued for the app's next poll (the app may be waiting in poll_events: the
// event is queued inside its own message pump, which returns it), or, while drag_start runs from this window and the
// app asked for it (drop_sync_set), handed to the app at once. Returns the effect to give the system.
@(private)
deliver :: proc(w: ^Window, kind: Event_Kind, pos: [2]f32, keys: u32) -> u32 {
	d := w.dnd
	ev := Event{kind = kind, pos = pos, mods = mods_from_keys(keys), drop_allowed = d.allowed, stamp = time.tick_now()}
	if d.sending && d.sync != nil {
		e := d.sync(d.sync_user, w, ev)
		if kind == .Drop_Leave { return 0 }
		d.effect = e
		if v, ok := e.?; ok && v in d.allowed { return effects_to_win({v}) }
		return 0
	}
	append(&w.events, ev)
	return kind == .Drop_Leave ? 0 : answer(d)
}

@(private)
effects_from_win :: proc(e: u32) -> (out: Drop_Effects) {
	if e & DROPEFFECT_COPY != 0 { out += {.Copy} }
	if e & DROPEFFECT_MOVE != 0 { out += {.Move} }
	if e & DROPEFFECT_LINK != 0 { out += {.Link} }
	return
}

@(private)
effects_to_win :: proc(e: Drop_Effects) -> (out: u32) {
	if .Copy in e { out |= DROPEFFECT_COPY }
	if .Move in e { out |= DROPEFFECT_MOVE }
	if .Link in e { out |= DROPEFFECT_LINK }
	return
}

// The app's last answer, when the source allows it.
@(private)
answer :: proc(d: ^Dnd_State) -> u32 {
	if e, ok := d.effect.?; ok && e in d.allowed { return effects_to_win({e}) }
	// the app's own drag came back over its window while drag_start blocks: the app cannot answer before the drop,
	// which it receives as Drop events once drag_start returns
	if d.sending { if e, ok := drop_effect_for(d.allowed, {}).?; ok { return effects_to_win({e}) } }
	return 0
}

////////////////////////////////
// Reading a data object

@(private)
registered_format :: proc(name: string) -> u16 {
	return u16(win.RegisterClipboardFormatW(win.utf8_to_wstring(name, context.temp_allocator)))
}

CUSTOM_FORMAT_NAME :: "gui_toolkit drag entries"

// The bytes of one format (HGLOBAL), nil when absent.
@(private)
get_bytes :: proc(obj: ^IDataObject, cf: u16, allocator := context.allocator) -> []u8 {
	if cf == 0 { return nil }
	f := FORMATETC{cfFormat = cf, dwAspect = DVASPECT_CONTENT, lindex = -1, tymed = TYMED_HGLOBAL}
	m: STGMEDIUM
	if obj.vt.GetData(obj, &f, &m) < 0 { return nil }
	defer ReleaseStgMedium(&m)
	if m.tymed != TYMED_HGLOBAL || m.hGlobal == nil { return nil }
	n := int(win.GlobalSize(m.hGlobal))
	p := cast([^]u8)win.GlobalLock(m.hGlobal)
	if p == nil { return nil }
	defer win.GlobalUnlock(m.hGlobal)
	out := make([]u8, n, allocator)
	copy(out, p[:n])
	return out
}

// UTF-16 bytes (up to the first NUL) as UTF-8.
@(private)
wide_bytes_string :: proc(b: []u8, allocator := context.allocator) -> string {
	n := len(b) / 2
	w := ([^]u16)(raw_data(b))[:n]
	end := 0
	for end < n && w[end] != 0 { end += 1 }
	s, _ := win.utf16_to_utf8(w[:end], allocator)
	return s
}

@(private)
ansi_bytes_string :: proc(b: []u8, allocator := context.allocator) -> string {
	end := 0
	for end < len(b) && b[end] != 0 { end += 1 }
	if end == 0 { return "" }
	// the system's code page to UTF-16, then UTF-8
	n := win.MultiByteToWideChar(win.CP_ACP, 0, raw_data(b), i32(end), nil, 0)
	if n <= 0 { return "" }
	wide := make([]u16, n, context.temp_allocator)
	win.MultiByteToWideChar(win.CP_ACP, 0, raw_data(b), i32(end), raw_data(wide), n)
	s, _ := win.utf16_to_utf8(wide, allocator)
	return s
}

@(private)
read_files :: proc(obj: ^IDataObject, out: ^Drag_Data) {
	f := FORMATETC{cfFormat = CF_HDROP, dwAspect = DVASPECT_CONTENT, lindex = -1, tymed = TYMED_HGLOBAL}
	m: STGMEDIUM
	if obj.vt.GetData(obj, &f, &m) < 0 { return }
	defer ReleaseStgMedium(&m)
	if m.tymed != TYMED_HGLOBAL || m.hGlobal == nil { return }
	hdrop := win.HDROP(m.hGlobal)
	count := win.DragQueryFileW(hdrop, 0xFFFF_FFFF, nil, 0)
	for i in 0 ..< count {
		n := win.DragQueryFileW(hdrop, i, nil, 0)
		if n == 0 { continue }
		buf := make([]u16, n + 1, context.temp_allocator)
		got := win.DragQueryFileW(hdrop, i, raw_data(buf), n + 1)
		if s, err := win.utf16_to_utf8(buf[:got], context.allocator); err == nil { append(&out.files, s) }
	}
}

// Everything a data object offers that the API knows. Heap (owned by the result).
@(private)
read_data_object :: proc(obj: ^IDataObject) -> (out: Drag_Data) {
	if obj == nil { return }
	read_files(obj, &out)
	if b := get_bytes(obj, CF_UNICODETEXT, context.temp_allocator); b != nil { out.text = wide_bytes_string(b) }
	if b := get_bytes(obj, registered_format("HTML Format"), context.temp_allocator); b != nil {
		end := 0
		for end < len(b) && b[end] != 0 { end += 1 }
		out.html = clone_string(html_format_fragment(string(b[:end])))
	}
	if b := get_bytes(obj, registered_format("UniformResourceLocatorW"), context.temp_allocator); b != nil {
		out.url = wide_bytes_string(b)
	} else if a := get_bytes(obj, registered_format("UniformResourceLocator"), context.temp_allocator); a != nil {
		out.url = ansi_bytes_string(a)
	}
	if out.url != "" && out.text != "" && out.text != out.url { out.url_title = clone_string(out.text) }
	if len(out.files) == 0 {
		if b := get_bytes(obj, registered_format("PNG")); b != nil { out.image = b }
	}
	if b := get_bytes(obj, registered_format(CUSTOM_FORMAT_NAME), context.temp_allocator); b != nil {
		if entries, ok := drag_custom_decode(b); ok { out.custom = entries }
	}
	return
}

////////////////////////////////
// Writing a data object

@(private)
global_of :: proc(bytes: []u8, extra_zeros := 0) -> win.HGLOBAL {
	total := len(bytes) + extra_zeros
	mem := win.GlobalAlloc(win.GMEM_MOVEABLE, uint(total))
	if mem == nil { return nil }
	p := cast([^]u8)win.GlobalLock(win.HGLOBAL(mem))
	if p == nil { win.GlobalFree(win.HGLOBAL(mem)); return nil }
	copy(p[:len(bytes)], bytes)
	for i in 0 ..< extra_zeros { p[len(bytes) + i] = 0 }
	win.GlobalUnlock(win.HGLOBAL(mem))
	return win.HGLOBAL(mem)
}

@(private)
set_global :: proc(obj: ^IDataObject, cf: u16, mem: win.HGLOBAL) -> bool {
	if cf == 0 || mem == nil { if mem != nil { win.GlobalFree(mem) }; return false }
	f := FORMATETC{cfFormat = cf, dwAspect = DVASPECT_CONTENT, lindex = -1, tymed = TYMED_HGLOBAL}
	m := STGMEDIUM{tymed = TYMED_HGLOBAL, hGlobal = mem}
	if obj.vt.SetData(obj, &f, &m, true) < 0 { win.GlobalFree(mem); return false }   // on success the object owns it
	return true
}

@(private)
wide_global :: proc(s: string) -> win.HGLOBAL {
	w := win.utf8_to_utf16(s, context.temp_allocator)
	return global_of(([^]u8)(raw_data(w))[:len(w) * 2], 2)
}

// A shell data object holding `data` in every format the API writes; nil when the system refused.
@(private)
make_data_object :: proc(data: Drag_Data) -> ^IDataObject {
	obj: ^IDataObject
	if SHCreateDataObject(nil, 0, nil, nil, &IID_IDataObject, cast(^rawptr)&obj) < 0 || obj == nil { return nil }
	if len(data.files) > 0 {
		// DROPFILES (20 bytes: offset of the list, a point, two BOOLs) then the paths, each NUL-terminated, then a NUL
		list := make([dynamic]u16, context.temp_allocator)
		for f in data.files {
			w := win.utf8_to_utf16(f, context.temp_allocator)
			append(&list, ..w)
			append(&list, 0)
		}
		append(&list, 0)
		header := [5]u32{20, 0, 0, 0, 1}   // pFiles, pt.x, pt.y, fNC, fWide
		bytes := make([]u8, 20 + len(list) * 2, context.temp_allocator)
		copy(bytes, ([^]u8)(&header)[:20])
		copy(bytes[20:], ([^]u8)(raw_data(list))[:len(list) * 2])
		set_global(obj, CF_HDROP, global_of(bytes))
	}
	text := data.text != "" ? data.text : data.url
	if text != "" { set_global(obj, CF_UNICODETEXT, wide_global(text)) }
	if data.url != "" { set_global(obj, registered_format("UniformResourceLocatorW"), wide_global(data.url)) }
	if data.html != "" {
		h := html_format_wrap(data.html, data.url, context.temp_allocator)
		set_global(obj, registered_format("HTML Format"), global_of(transmute([]u8)h, 1))
	}
	if len(data.image) > 0 { set_global(obj, registered_format("PNG"), global_of(data.image)) }
	if len(data.custom) > 0 {
		b := drag_custom_encode(data.custom[:], context.temp_allocator)
		set_global(obj, registered_format(CUSTOM_FORMAT_NAME), global_of(b))
	}
	return obj
}

////////////////////////////////
// API

// Makes the window a drop target (or no longer one). False when the system refused: OLE could not start on this thread
// (it is in a multithreaded apartment), or the process runs elevated and the drags of a normal desktop cannot reach it.
drop_target_enable :: proc(w: ^Window, on: bool) -> bool {
	d := dnd_state(w)
	if on == d.registered { return true }
	if !on {
		RevokeDragDrop(w.hwnd)
		d.registered = false
		if d.helper != nil { d.helper.vt.Release(d.helper); d.helper = nil }
		return true
	}
	hr := OleInitialize(nil)
	if hr < 0 { return false }   // (S_FALSE: already initialized on this thread, fine)
	if RegisterDragDrop(w.hwnd, &d.target) < 0 { return false }
	d.registered = true
	if d.helper == nil { _ = win.CoCreateInstance(&CLSID_DragDropHelper, nil, win.CLSCTX_INPROC_SERVER, &IID_IDropTargetHelper, cast(^rawptr)&d.helper) }
	return true
}

drop_target_enabled :: proc(w: ^Window) -> bool { return w.dnd != nil && w.dnd.registered }

// Prepares the calling thread (the interface's) for drag and drop. On Windows: OLE in a single-threaded apartment,
// which must come before any library puts the thread in the multithreaded one (a decoder's CoInitializeEx), or no drop
// target can be registered and no drag started. Call it first thing; false when it is too late.
dragdrop_thread_init :: proc() -> bool { return OleInitialize(nil) >= 0 }

// What the drag over the window carries (from Drop_Enter; the last one dropped stays until the next enters), nil
// when no drag came yet.
drop_data :: proc(w: ^Window) -> ^Drag_Data {
	if w.dnd == nil { return nil }
	return &w.dnd.data
}

// Whether a drag of the system is over the window now (between Drop_Enter and Drop_Leave / Drop).
drop_active :: proc(w: ^Window) -> bool { return w.dnd != nil && w.dnd.over }

// The effect a drop at the pointer would have, as the app decided it (nil: refused). The system is told at its next
// question (the pointer moves, a modifier changes, the button is released).
drop_set_effect :: proc(w: ^Window, effect: Maybe(Drop_Effect)) { dnd_state(w).effect = effect }

// Frees what drop_data holds (after the app handled a Drop or a Drop_Leave).
drop_data_release :: proc(w: ^Window) {
	if w.dnd == nil || w.dnd.over { return }
	context.allocator = w.dnd.allocator
	drag_data_destroy(&w.dnd.data)
}

// Queues a Drop_* event as if a drag of the system came (tests, remote control): Drop_Enter takes a copy of `data`;
// the other kinds keep the data of the last Drop_Enter. Through the same path as a real drag (inject_event).
drop_inject :: proc(w: ^Window, kind: Event_Kind, pos: [2]f32, data: ^Drag_Data = nil, allowed: Drop_Effects = {.Copy, .Move, .Link}, mods: Modifiers = {}) -> bool {
	#partial switch kind {
	case .Drop_Enter, .Drop_Over, .Drop_Leave, .Drop:
	case: return false
	}
	d := dnd_state(w)
	if kind == .Drop_Enter {
		context.allocator = d.allocator
		drag_data_destroy(&d.data)
		if data != nil { d.data = drag_data_clone(data^) }
		d.effect = nil
	}
	d.allowed = allowed
	d.over = kind == .Drop_Enter || kind == .Drop_Over
	inject_event(w, Event{kind = kind, pos = pos, mods = mods, drop_allowed = allowed})
	return true
}

// Runs a drag of the system from the window with `data` until it is dropped (the effect the target chose) or given up
// (nil). Blocks while the user drags. ok = false when the system could not start it (no OLE on this thread, no data).
// `image` follows the pointer, over every application, with its hot spot under the pointer (none: the system's
// default picture of the data).
drag_start :: proc(w: ^Window, data: Drag_Data, allowed: Drop_Effects, image: Maybe(Drag_Image) = nil) -> (effect: Maybe(Drop_Effect), ok: bool) {
	if drag_data_empty(data) || allowed == {} { return nil, false }
	if OleInitialize(nil) < 0 { return nil, false }
	obj := make_data_object(data)
	if obj == nil { return nil, false }
	defer obj.vt.Release(obj)
	d := dnd_state(w)
	d.image_held, d.image_size, d.image_offset = false, {}, {}
	if img, has := image.?; has && set_drag_image(obj, img) { read_drag_image(d, obj) }
	d.sending = true
	defer d.sending = false
	if len(d.script) > 0 {
		steps := d.script
		d.script = {}
		defer delete(steps)
		return run_script(w, obj, steps[:], allowed), true
	}
	// the system's loop pumps the thread's messages: a repaint meanwhile is asked for (take_paint_request), never run
	// as a frame inside the app's own frame that called drag_start
	pumping += 1
	defer pumping -= 1
	// the capture of the press would keep the mouse's messages here: the system's loop takes them
	if win.GetCapture() == w.hwnd { win.ReleaseCapture() }
	w.buttons_down = {}
	out: u32
	hr := SHDoDragDrop(w.hwnd, obj, nil, effects_to_win(allowed), &out)
	if hr != DRAGDROP_S_DROP { return nil, true }
	eff := effects_from_win(out)
	for e in Drop_Effect { if e in eff { return e, true } }
	return nil, true
}

// The shell's drag image from straight RGBA pixels (a premultiplied BGRA bitmap the helper takes over). False when the
// helper refused it.
@(private)
set_drag_image :: proc(obj: ^IDataObject, img: Drag_Image) -> bool {
	if !drag_image_valid(img) { return false }
	helper: ^IDragSourceHelper
	if win.CoCreateInstance(&CLSID_DragDropHelper, nil, win.CLSCTX_INPROC_SERVER, &IID_IDragSourceHelper, cast(^rawptr)&helper) < 0 || helper == nil { return false }
	defer helper.vt.Release(helper)
	bi := win.BITMAPINFO{bmiHeader = {biSize = size_of(win.BITMAPINFOHEADER), biWidth = i32(img.size.x), biHeight = -i32(img.size.y), biPlanes = 1, biBitCount = 32, biCompression = win.BI_RGB}}
	bits: rawptr
	bmp := win.CreateDIBSection(nil, &bi, win.DIB_RGB_COLORS, &bits, nil, 0)
	if bmp == nil || bits == nil { return false }
	dst := ([^]u8)(bits)
	for i in 0 ..< img.size.x * img.size.y {
		r, g, b, a := u32(img.rgba[i * 4]), u32(img.rgba[i * 4 + 1]), u32(img.rgba[i * 4 + 2]), u32(img.rgba[i * 4 + 3])
		dst[i * 4], dst[i * 4 + 1], dst[i * 4 + 2], dst[i * 4 + 3] = u8(b * a / 255), u8(g * a / 255), u8(r * a / 255), u8(a)
	}
	sdi := SHDRAGIMAGE{sizeDragImage = {i32(img.size.x), i32(img.size.y)}, ptOffset = {i32(img.offset.x), i32(img.offset.y)}, hbmpDragImage = bmp, crColorKey = 0xFFFF_FFFF}
	if helper.vt.InitializeFromBitmap(helper, &sdi, obj) < 0 { win.DeleteObject(win.HGDIOBJ(bmp)); return false }   // on success the helper owns it
	return true
}

// What the helper stored in the data object ("DragImageBits": the picture's size and hot spot, then its bits), which
// is what the shell draws during the drag, over this window and others.
@(private)
read_drag_image :: proc(d: ^Dnd_State, obj: ^IDataObject) {
	b := get_bytes(obj, registered_format("DragImageBits"), context.temp_allocator)
	if len(b) < 16 { return }
	i32_at :: proc(b: []u8, at: int) -> int { return int(cast(i32)(u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24)) }
	d.image_size = {i32_at(b, 0), i32_at(b, 4)}
	d.image_offset = {i32_at(b, 8), i32_at(b, 12)}
	d.image_held = true
}

// The scripted drag (drag_script): the window's own drop target is called along the steps as the system would, with
// the data object drag_start made; the effect of the drop (nil when released outside the window or refused).
@(private)
run_script :: proc(w: ^Window, obj: ^IDataObject, steps: []Drag_Step, allowed: Drop_Effects) -> Maybe(Drop_Effect) {
	d := dnd_state(w)
	inside := false
	result: Maybe(Drop_Effect)
	// the system's loop pumps the thread's messages between the steps, and the drag picture moving over the window repaints
	// it: so does the script, with the same rule (a repaint asked for, never a frame inside the app's own: frame_gate.odin)
	pumping += 1
	defer pumping -= 1
	for s, i in steps {
		if i > 0 { drag_script_pump(w) }
		now := s.pos.x >= 0 && s.pos.y >= 0 && s.pos.x < f32(w.size.x) && s.pos.y < f32(w.size.y)
		sp := win.POINT{i32(s.pos.x), i32(s.pos.y)}
		win.ClientToScreen(w.hwnd, &sp)
		pt := POINTL{sp.x, sp.y}
		keys := keys_from_mods(s.mods) | MK_LBUTTON
		first, second := drag_script_calls(inside, now, i == len(steps) - 1)
		for call in ([]Drag_Script_Call{first, second}) {
			e := effects_to_win(allowed)
			switch call {
			case .None, .Cancel:
			case .Enter: d.target.vt.DragEnter(&d.target, obj, keys, pt, &e)
			case .Over: d.target.vt.DragOver(&d.target, keys, pt, &e)
			case .Leave: d.target.vt.DragLeave(&d.target)
			case .Drop:
				d.target.vt.Drop(&d.target, obj, keys &~ MK_LBUTTON, pt, &e)
				for v in Drop_Effect { if effects_to_win({v}) & e != 0 { result = v; break } }
			}
		}
		inside = now
	}
	return result
}

// One turn of the system's drag loop between two steps: the window is invalidated and the messages that wait are dispatched.
@(private)
drag_script_pump :: proc(w: ^Window) {
	win.InvalidateRect(w.hwnd, nil, false)
	msg: win.MSG
	for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
		if msg.message == win.WM_QUIT { win.PostQuitMessage(i32(msg.wParam)); break }
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
}

@(private)
keys_from_mods :: proc(m: Modifiers) -> (keys: u32) {
	if .Ctrl in m { keys |= MK_CONTROL }
	if .Shift in m { keys |= MK_SHIFT }
	if .Alt in m { keys |= MK_ALT }
	return
}

// Asks the window's app at once, while drag_start runs from it, what a drop would do (Drop_Sync); nil: the events are
// queued as for any drag (the app then sees its own drag only after drag_start returns).
drop_sync_set :: proc(w: ^Window, handler: Drop_Sync, user: rawptr) {
	d := dnd_state(w)
	d.sync, d.sync_user = handler, user
}

// Tests and remote control: the next drag_start from the window does not follow the mouse but `steps` (copied), with
// the same data object, drag image and drop target calls as a drag of the system that comes back over the window. True
// when this system can do it.
drag_script :: proc(w: ^Window, steps: []Drag_Step) -> bool {
	d := dnd_state(w)
	context.allocator = d.allocator
	clear(&d.script)
	append(&d.script, ..steps)
	return true
}

// The picture the system holds for the last drag_start from the window (read back from the system after the app gave
// it): its size and hot spot; ok = false when there was none or the system refused it.
drag_image_held :: proc(w: ^Window) -> (size, offset: [2]int, ok: bool) {
	if w.dnd == nil || !w.dnd.image_held { return }
	return w.dnd.image_size, w.dnd.image_offset, true
}

// How far the pointer moves with a button held before a press becomes a drag (the system's setting), in pixels.
drag_threshold :: proc(w: ^Window) -> [2]f32 {
	return {f32(max(win.GetSystemMetrics(win.SM_CXDRAG), 1)), f32(max(win.GetSystemMetrics(win.SM_CYDRAG), 1))}
}

// Whether drag_start is running from this window (its own drop target then sees a drag that came from the app).
drag_sending :: proc(w: ^Window) -> bool { return w.dnd != nil && w.dnd.sending }

@(private)
dnd_destroy :: proc(w: ^Window) {
	d := w.dnd
	if d == nil { return }
	if d.registered && w.hwnd != nil { RevokeDragDrop(w.hwnd) }
	if d.helper != nil { d.helper.vt.Release(d.helper) }
	context.allocator = d.allocator
	drag_data_destroy(&d.data)
	delete(d.script)
	free(d)
	w.dnd = nil
}

// Test support: the drag-and-drop round trip without a mouse. The data object drag_start would hand to the system is
// given straight to the window's own IDropTarget (enter, over at `pos`, drop), so both halves of the conversion and the
// events are exercised. False when the data object could not be made.
drop_self_test :: proc(w: ^Window, data: Drag_Data, pos: [2]f32, allowed: Drop_Effects) -> bool {
	obj := make_data_object(data)
	if obj == nil { return false }
	defer obj.vt.Release(obj)
	d := dnd_state(w)
	sp := win.POINT{i32(pos.x), i32(pos.y)}
	win.ClientToScreen(w.hwnd, &sp)
	pt := POINTL{sp.x, sp.y}
	e := effects_to_win(allowed)
	d.target.vt.DragEnter(&d.target, obj, 0, pt, &e)
	e = effects_to_win(allowed)
	d.target.vt.DragOver(&d.target, 0, pt, &e)
	e = effects_to_win(allowed)
	d.target.vt.Drop(&d.target, obj, 0, pt, &e)
	return true
}
