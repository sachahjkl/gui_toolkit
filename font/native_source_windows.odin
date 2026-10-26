#+build windows
package font

// Where the native backend reads a face that DirectWrite opened: its bytes in memory (web fonts, fonts compiled into
// the exe) or its file on disk (system fonts, font files), its index in a collection and its variation axis values.

@(private)
Native_Source :: struct {
	path:  string,           // UTF-8, temp memory; empty for a memory font
	data:  []byte,           // a memory font's bytes (alive as long as the face)
	index: u32,
	axes:  []DWRITE_FONT_AXIS_VALUE,   // user-space values of a variable instance (temp memory)
	simulated: bool,         // DirectWrite simulates bold or oblique on this face (the native backend cannot)
}

@(private)
native_source :: proc(f: ^Font) -> (src: Native_Source, ok: bool) {
	if f == nil || f.dw == nil { return }
	src.index = f.dw->GetIndex()
	src.simulated = f.dw->GetSimulations() != 0
	if f.dw5 != nil && bool(f.dw5->HasVariations()) {
		if n := f.dw5->GetFontAxisValueCount(); n > 0 && n <= 64 {
			src.axes = make([]DWRITE_FONT_AXIS_VALUE, n, context.temp_allocator)
			if f.dw5->GetFontAxisValues(raw_data(src.axes), n) < 0 { src.axes = nil }
		}
	}
	if f.memory != nil {
		src.data = f.memory.data
		return src, len(src.data) > 0
	}
	n: u32
	if f.dw->GetFiles(&n, nil) < 0 || n != 1 { return }
	files: [1]^IDWriteFontFile
	if f.dw->GetFiles(&n, &files[0]) < 0 || files[0] == nil { return }
	defer com_release(files[0])
	key: rawptr
	key_size: u32
	if files[0]->GetReferenceKey(&key, &key_size) < 0 { return }
	loader: ^IDWriteFontFileLoader
	if files[0]->GetLoader(&loader) < 0 || loader == nil { return }
	defer com_release(loader)
	local := com_query(loader, &IID_IDWriteLocalFontFileLoader, IDWriteLocalFontFileLoader)
	if local == nil { return }   // a loader of another kind (none this package makes besides the memory one)
	defer com_release(local)
	length: u32
	if local->GetFilePathLengthFromKey(key, key_size, &length) < 0 || length == 0 { return }
	w := make([]u16, length + 1, context.temp_allocator)
	if local->GetFilePathFromKey(key, key_size, raw_data(w), length + 1) < 0 { return }
	src.path = from_wide(w, context.temp_allocator)
	return src, src.path != ""
}
