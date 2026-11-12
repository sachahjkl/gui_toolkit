#+build windows
package tk_ocr

// Windows.Media.Ocr through the Windows Runtime (../winrt). The interface IDs and the order of the methods are those of
// the SDK's windows.media.ocr.h, windows.graphics.imaging.h, windows.globalization.h, windows.storage.streams.h and
// robuffer.h (checked against windows-rs, which is generated from the same metadata).
//
// The picture reaches the engine as a SoftwareBitmap made by SoftwareBitmap.CreateCopyFromBuffer from a
// Windows.Storage.Streams.Buffer filled through IBufferByteAccess. The other route (a SoftwareBitmap, LockBuffer,
// IMemoryBufferReference, IMemoryBufferByteAccess, then the plane's stride) takes four more objects for the same one
// copy: the prepared picture has no padding, which is the layout CreateCopyFromBuffer reads.

import "core:strings"
import winrt "../winrt"

@(private = "file") GUID :: winrt.GUID
@(private = "file") HRESULT :: winrt.HRESULT
@(private = "file") HSTRING :: winrt.HSTRING

@(private = "file") IID_IOcrEngineStatics      :: GUID{0x5bffa85a, 0x3384, 0x3540, {0x99, 0x40, 0x69, 0x91, 0x20, 0xd4, 0x28, 0xa8}}
@(private = "file") IID_IOcrResult             :: GUID{0x9bd235b2, 0x175b, 0x3d6a, {0x92, 0xe2, 0x38, 0x8c, 0x20, 0x6e, 0x2f, 0x63}}
@(private = "file") IID_ILanguageFactory       :: GUID{0x9b0252ac, 0x0c27, 0x44f8, {0xb7, 0x92, 0x97, 0x93, 0xfb, 0x66, 0xc6, 0x3e}}
@(private = "file") IID_ISoftwareBitmapStatics :: GUID{0xdf0385db, 0x672f, 0x4a9d, {0x80, 0x6e, 0xc2, 0x44, 0x2f, 0x34, 0x3e, 0x86}}
@(private = "file") IID_IBufferFactory         :: GUID{0x71af914d, 0xc10f, 0x484b, {0xbc, 0x50, 0x14, 0xbc, 0x62, 0x3b, 0x3a, 0x27}}
@(private = "file") IID_IBufferByteAccess      :: GUID{0x905a0fef, 0xbc53, 0x11df, {0x8c, 0x49, 0x00, 0x1e, 0x4f, 0xc6, 0x86, 0xda}}

// BitmapPixelFormat.Bgra8.
@(private = "file") BGRA8 :: 87
// How long a recognition may take: a large picture takes a few seconds.
@(private = "file") RECOGNIZE_MS :: 60_000

@(private = "file")
IOcrEngineStatics_Vtbl :: struct {
	using base:                        winrt.IInspectable_Vtbl,
	get_MaxImageDimension:             proc "system" (this: rawptr, value: ^u32) -> HRESULT,
	get_AvailableRecognizerLanguages:  proc "system" (this: rawptr, vector: ^rawptr) -> HRESULT,
	IsLanguageSupported:               proc "system" (this: rawptr, language: rawptr, supported: ^bool) -> HRESULT,
	TryCreateFromLanguage:             proc "system" (this: rawptr, language: rawptr, engine: ^rawptr) -> HRESULT,
	TryCreateFromUserProfileLanguages: proc "system" (this: rawptr, engine: ^rawptr) -> HRESULT,
}

@(private = "file")
IOcrEngine_Vtbl :: struct {
	using base:             winrt.IInspectable_Vtbl,
	RecognizeAsync:         proc "system" (this: rawptr, bitmap: rawptr, operation: ^rawptr) -> HRESULT,
	get_RecognizerLanguage: proc "system" (this: rawptr, language: ^rawptr) -> HRESULT,
}

@(private = "file")
IOcrResult_Vtbl :: struct {
	using base:    winrt.IInspectable_Vtbl,
	get_Lines:     proc "system" (this: rawptr, vector: ^rawptr) -> HRESULT,
	get_TextAngle: rawptr,
	get_Text:      proc "system" (this: rawptr, text: ^HSTRING) -> HRESULT,
}

@(private = "file")
IOcrLine_Vtbl :: struct {
	using base: winrt.IInspectable_Vtbl,
	get_Words:  proc "system" (this: rawptr, vector: ^rawptr) -> HRESULT,
	get_Text:   proc "system" (this: rawptr, text: ^HSTRING) -> HRESULT,
}

// Windows.Foundation.Rect.
@(private = "file")
Foundation_Rect :: struct { x, y, width, height: f32 }

@(private = "file")
IOcrWord_Vtbl :: struct {
	using base:       winrt.IInspectable_Vtbl,
	get_BoundingRect: proc "system" (this: rawptr, rect: ^Foundation_Rect) -> HRESULT,
	get_Text:         proc "system" (this: rawptr, text: ^HSTRING) -> HRESULT,
}

@(private = "file")
ILanguage_Vtbl :: struct {
	using base:      winrt.IInspectable_Vtbl,
	get_LanguageTag: proc "system" (this: rawptr, tag: ^HSTRING) -> HRESULT,
	get_DisplayName: rawptr,
	get_NativeName:  rawptr,
	get_Script:      rawptr,
}

@(private = "file")
ILanguageFactory_Vtbl :: struct {
	using base:     winrt.IInspectable_Vtbl,
	CreateLanguage: proc "system" (this: rawptr, tag: HSTRING, language: ^rawptr) -> HRESULT,
}

@(private = "file")
ISoftwareBitmapStatics_Vtbl :: struct {
	using base:                    winrt.IInspectable_Vtbl,
	Copy:                          rawptr,
	Convert:                       rawptr,
	ConvertWithAlpha:              rawptr,
	CreateCopyFromBuffer:          proc "system" (this: rawptr, source: rawptr, format: i32, width, height: i32, bitmap: ^rawptr) -> HRESULT,
	CreateCopyWithAlphaFromBuffer: rawptr,
}

@(private = "file")
IBufferFactory_Vtbl :: struct {
	using base: winrt.IInspectable_Vtbl,
	Create:     proc "system" (this: rawptr, capacity: u32, buffer: ^rawptr) -> HRESULT,
}

@(private = "file")
IBuffer_Vtbl :: struct {
	using base:   winrt.IInspectable_Vtbl,
	get_Capacity: proc "system" (this: rawptr, value: ^u32) -> HRESULT,
	get_Length:   proc "system" (this: rawptr, value: ^u32) -> HRESULT,
	put_Length:   proc "system" (this: rawptr, value: u32) -> HRESULT,
}

// robuffer.h: a COM interface, not a runtime one (IUnknown's three methods, then Buffer).
@(private = "file")
IBufferByteAccess_Vtbl :: struct {
	QueryInterface: rawptr,
	AddRef:         rawptr,
	Release:        rawptr,
	Buffer:         proc "system" (this: rawptr, bytes: ^[^]u8) -> HRESULT,
}

// Joins the thread to the runtime for one call. A thread already in a single-threaded apartment stays there (await
// takes the calls made to it meanwhile); `leave` says whether this call must uninit.
@(private = "file")
enter :: proc() -> (leave: bool, ok: bool) {
	hr := winrt.init()
	if hr == winrt.RPC_E_CHANGED_MODE { return false, true }
	return winrt.ok(hr), winrt.ok(hr)
}

@(private = "file")
engine_statics :: proc() -> rawptr {
	statics, hr := winrt.factory("Windows.Media.Ocr.OcrEngine", IID_IOcrEngineStatics)
	if !winrt.ok(hr) { return nil }
	return statics
}

@(private = "file")
language_tag :: proc(language: rawptr, allocator := context.allocator) -> string {
	if language == nil { return "" }
	tag: HSTRING
	if !winrt.ok(winrt.vtable(language, ILanguage_Vtbl).get_LanguageTag(language, &tag)) { return "" }
	defer winrt.string_delete(tag)
	return winrt.string_read(tag, allocator)
}

@(private)
system_available :: proc() -> (engine: Engine, ok: bool) {
	leave, entered := enter()
	if !entered { return .None, false }
	defer if leave { winrt.uninit() }
	statics := engine_statics()
	if statics == nil { return .None, false }
	defer winrt.release(statics)
	vector: rawptr
	if !winrt.ok(winrt.vtable(statics, IOcrEngineStatics_Vtbl).get_AvailableRecognizerLanguages(statics, &vector)) {
		return .Windows, false
	}
	defer winrt.release(vector)
	return .Windows, winrt.vector_size(vector) > 0
}

@(private)
system_max_side :: proc() -> int {
	leave, entered := enter()
	if !entered { return 0 }
	defer if leave { winrt.uninit() }
	statics := engine_statics()
	if statics == nil { return 0 }
	defer winrt.release(statics)
	side: u32
	if !winrt.ok(winrt.vtable(statics, IOcrEngineStatics_Vtbl).get_MaxImageDimension(statics, &side)) { return 0 }
	return int(side)
}

@(private)
system_languages :: proc(allocator := context.allocator) -> []string {
	leave, entered := enter()
	if !entered { return nil }
	defer if leave { winrt.uninit() }
	statics := engine_statics()
	if statics == nil { return nil }
	defer winrt.release(statics)
	vector: rawptr
	if !winrt.ok(winrt.vtable(statics, IOcrEngineStatics_Vtbl).get_AvailableRecognizerLanguages(statics, &vector)) { return nil }
	defer winrt.release(vector)
	out := make([dynamic]string, allocator)
	for i in 0 ..< winrt.vector_size(vector) {
		language: rawptr
		if !winrt.ok(winrt.vector_at(vector, i, &language)) { continue }
		if tag := language_tag(language, allocator); tag != "" { append(&out, tag) }
		winrt.release(language)
	}
	return out[:]
}

// The engine of the first language asked that is installed; with none asked, the one of the user's profile languages.
@(private = "file")
engine_for :: proc(statics: rawptr, asked: []string) -> rawptr {
	s := winrt.vtable(statics, IOcrEngineStatics_Vtbl)
	engine: rawptr
	if len(asked) == 0 {
		if !winrt.ok(s.TryCreateFromUserProfileLanguages(statics, &engine)) { return nil }
		return engine
	}
	languages, hr := winrt.factory("Windows.Globalization.Language", IID_ILanguageFactory)
	if !winrt.ok(hr) { return nil }
	defer winrt.release(languages)
	for tag in asked {
		h := winrt.string_make(tag)
		language: rawptr
		created := winrt.ok(winrt.vtable(languages, ILanguageFactory_Vtbl).CreateLanguage(languages, h, &language))
		winrt.string_delete(h)
		if !created { continue }   // (not a BCP-47 tag)
		supported: bool
		if winrt.ok(s.IsLanguageSupported(statics, language, &supported)) && supported {
			s.TryCreateFromLanguage(statics, language, &engine)
		}
		winrt.release(language)
		if engine != nil { return engine }
	}
	return nil
}

// The prepared picture as a SoftwareBitmap in Bgra8 (owned), nil on a failure.
@(private = "file")
bitmap_of :: proc(p: Prepared) -> rawptr {
	size := p.width * p.height * 4
	buffers, hr := winrt.factory("Windows.Storage.Streams.Buffer", IID_IBufferFactory)
	if !winrt.ok(hr) { return nil }
	defer winrt.release(buffers)
	buffer: rawptr
	if !winrt.ok(winrt.vtable(buffers, IBufferFactory_Vtbl).Create(buffers, u32(size), &buffer)) { return nil }
	defer winrt.release(buffer)
	access := winrt.query(buffer, IID_IBufferByteAccess)
	if access == nil { return nil }
	bytes: [^]u8
	got := winrt.ok(winrt.vtable(access, IBufferByteAccess_Vtbl).Buffer(access, &bytes))
	winrt.release(access)
	if !got || bytes == nil { return nil }
	for v, i in p.gray { bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2], bytes[i * 4 + 3] = v, v, v, 255 }
	if !winrt.ok(winrt.vtable(buffer, IBuffer_Vtbl).put_Length(buffer, u32(size))) { return nil }
	bitmaps: rawptr
	bitmaps, hr = winrt.factory("Windows.Graphics.Imaging.SoftwareBitmap", IID_ISoftwareBitmapStatics)
	if !winrt.ok(hr) { return nil }
	defer winrt.release(bitmaps)
	bitmap: rawptr
	if !winrt.ok(winrt.vtable(bitmaps, ISoftwareBitmapStatics_Vtbl).CreateCopyFromBuffer(bitmaps, buffer, BGRA8, i32(p.width), i32(p.height), &bitmap)) {
		return nil
	}
	return bitmap
}

@(private)
system_recognize :: proc(p: Prepared, options: Options, lines: ^[dynamic]Line, allocator := context.allocator) -> (engine: Engine, language: string, err: Error) {
	leave, entered := enter()
	if !entered { return .None, "", .No_Engine }
	defer if leave { winrt.uninit() }
	statics := engine_statics()
	if statics == nil { return .None, "", .No_Engine }
	defer winrt.release(statics)

	ocr := engine_for(statics, options.languages)
	if ocr == nil { return .Windows, "", .No_Language }
	defer winrt.release(ocr)
	e := winrt.vtable(ocr, IOcrEngine_Vtbl)
	recognizer: rawptr
	if winrt.ok(e.get_RecognizerLanguage(ocr, &recognizer)) {
		language = language_tag(recognizer, allocator)
		winrt.release(recognizer)
	}

	bitmap := bitmap_of(p)
	if bitmap == nil { return .Windows, language, .Failed }
	defer winrt.release(bitmap)
	operation: rawptr
	if !winrt.ok(e.RecognizeAsync(ocr, bitmap, &operation)) { return .Windows, language, .Failed }
	_, handler := winrt.async_iids(winrt.sig_class("Windows.Media.Ocr.OcrResult", IID_IOcrResult))
	result: rawptr
	if !winrt.ok(winrt.await(operation, handler, &result, RECOGNIZE_MS)) || result == nil { return .Windows, language, .Failed }
	defer winrt.release(result)

	vector: rawptr
	if !winrt.ok(winrt.vtable(result, IOcrResult_Vtbl).get_Lines(result, &vector)) { return .Windows, language, .Failed }
	defer winrt.release(vector)
	for i in 0 ..< winrt.vector_size(vector) {
		line: rawptr
		if !winrt.ok(winrt.vector_at(vector, i, &line)) { continue }
		if l, ok := read_line(line, allocator); ok { append(lines, l) }
		winrt.release(line)
	}
	return .Windows, language, .None
}

// An OcrLine: its text, its words, and the rectangle around them (an OcrLine has none of its own).
@(private = "file")
read_line :: proc(line: rawptr, allocator := context.allocator) -> (l: Line, ok: bool) {
	v := winrt.vtable(line, IOcrLine_Vtbl)
	text: HSTRING
	if winrt.ok(v.get_Text(line, &text)) {
		l.text = strings.trim_space(winrt.string_read(text, context.temp_allocator))
		l.text = strings.clone(l.text, allocator)
		winrt.string_delete(text)
	}
	words := make([dynamic]Word, allocator)
	vector: rawptr
	if winrt.ok(v.get_Words(line, &vector)) {
		for i in 0 ..< winrt.vector_size(vector) {
			word: rawptr
			if !winrt.ok(winrt.vector_at(vector, i, &word)) { continue }
			wv := winrt.vtable(word, IOcrWord_Vtbl)
			w: Word
			box: Foundation_Rect
			if winrt.ok(wv.get_BoundingRect(word, &box)) {
				w.rect = {int(box.x), int(box.y), int(box.width + 0.999), int(box.height + 0.999)}
			}
			wt: HSTRING
			if winrt.ok(wv.get_Text(word, &wt)) {
				w.text = winrt.string_read(wt, allocator)
				winrt.string_delete(wt)
			}
			winrt.release(word)
			if w.text == "" { continue }
			append(&words, w)
		}
		winrt.release(vector)
	}
	if l.text == "" && len(words) == 0 {
		delete(l.text, allocator)
		delete(words)
		return {}, false
	}
	l.words = words[:]
	if len(words) > 0 {
		x0, y0 := words[0].rect.x, words[0].rect.y
		x1, y1 := x0 + words[0].rect.width, y0 + words[0].rect.height
		for w in words[1:] {
			x0, y0 = min(x0, w.rect.x), min(y0, w.rect.y)
			x1, y1 = max(x1, w.rect.x + w.rect.width), max(y1, w.rect.y + w.rect.height)
		}
		l.rect = {x0, y0, x1 - x0, y1 - y0}
	}
	return l, true
}
