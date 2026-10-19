#+build windows
package font

// COM objects DirectWrite calls back into: a font file loader for fonts held in memory (web fonts, fonts compiled into
// the exe), and the text analysis source / sink of one analysis call.

import "base:runtime"
import "core:sync"

////////////////////////////////
// Fonts in memory

// The bytes of a font held in memory. Shared by the state (until the face is unloaded) and by every stream DirectWrite
// opened on it, so the bytes stay valid as long as DirectWrite may read them, whatever the order of the releases.
@(private)
Memory_Font :: struct {
	refs:  i32,
	data:  []byte,
	owned: bool,   // false: data compiled into the exe, never freed
}

@(private)
memory_font_release :: proc "contextless" (m: ^Memory_Font) {
	if sync.atomic_sub(&m.refs, 1) != 1 { return }
	context = runtime.default_context()
	if m.owned { delete(m.data) }
	free(m)
}

@(private)
Memory_Stream :: struct {
	using iface: IDWriteFontFileStream,
	refs: i32,
	font: ^Memory_Font,
}

@(private)
memory_stream_vtable := IDWriteFontFileStream_VTable{
	QueryInterface = proc "system" (this: ^IDWriteFontFileStream, riid: ^IID, out: ^rawptr) -> HRESULT {
		if riid^ == IID_IUnknown || riid^ == IID_IDWriteFontFileStream {
			out^ = this
			this.vtable.AddRef(this)
			return S_OK
		}
		out^ = nil
		return E_NOINTERFACE
	},
	AddRef = proc "system" (this: ^IDWriteFontFileStream) -> u32 {
		return u32(sync.atomic_add(&(^Memory_Stream)(this).refs, 1) + 1)
	},
	Release = proc "system" (this: ^IDWriteFontFileStream) -> u32 {
		s := (^Memory_Stream)(this)
		n := sync.atomic_sub(&s.refs, 1) - 1
		if n == 0 {
			memory_font_release(s.font)
			context = runtime.default_context()
			free(s)
		}
		return u32(n)
	},
	ReadFileFragment = proc "system" (this: ^IDWriteFontFileStream, start: ^rawptr, offset, size: u64, ctx: ^rawptr) -> HRESULT {
		s := (^Memory_Stream)(this)
		n := u64(len(s.font.data))
		ctx^ = nil
		if offset > n || size > n - offset { start^ = nil; return E_FAIL }
		start^ = rawptr(uintptr(raw_data(s.font.data)) + uintptr(offset))
		return S_OK
	},
	ReleaseFileFragment = proc "system" (this: ^IDWriteFontFileStream, ctx: rawptr) {},
	GetFileSize = proc "system" (this: ^IDWriteFontFileStream, size: ^u64) -> HRESULT {
		size^ = u64(len((^Memory_Stream)(this).font.data))
		return S_OK
	},
	GetLastWriteTime = proc "system" (this: ^IDWriteFontFileStream, time: ^u64) -> HRESULT {
		time^ = 0
		return E_FAIL   // documented answer for streams that have no file time
	},
}

// One loader per process: the key of a file is the address of its Memory_Font.
@(private)
Memory_Loader :: struct {
	using iface: IDWriteFontFileLoader,
}

@(private)
memory_loader_vtable := IDWriteFontFileLoader_VTable{
	QueryInterface = proc "system" (this: ^IDWriteFontFileLoader, riid: ^IID, out: ^rawptr) -> HRESULT {
		if riid^ == IID_IUnknown || riid^ == IID_IDWriteFontFileLoader {
			out^ = this
			return S_OK
		}
		out^ = nil
		return E_NOINTERFACE
	},
	AddRef = proc "system" (this: ^IDWriteFontFileLoader) -> u32 { return 1 },    // static object
	Release = proc "system" (this: ^IDWriteFontFileLoader) -> u32 { return 1 },
	CreateStreamFromKey = proc "system" (this: ^IDWriteFontFileLoader, key: rawptr, key_size: u32, stream: ^^IDWriteFontFileStream) -> HRESULT {
		if key == nil || key_size != size_of(^Memory_Font) { stream^ = nil; return E_INVALIDARG }
		m := (^^Memory_Font)(key)^
		context = runtime.default_context()
		s := new(Memory_Stream)
		s.vtable = &memory_stream_vtable
		s.refs = 1
		sync.atomic_add(&m.refs, 1)
		s.font = m
		stream^ = &s.iface
		return S_OK
	},
}

@(private)
memory_loader := Memory_Loader{iface = {vtable = &memory_loader_vtable}}

////////////////////////////////
// Text analysis (script, bidi, line breaks, font fallback)

@(private)
Script_Run :: struct {
	start, end: u32,   // UTF-16 units
	sa:         DWRITE_SCRIPT_ANALYSIS,
}

// One analysis of a UTF-16 string, on the stack of the caller: DirectWrite only calls it during the call it is given to.
@(private)
Analysis :: struct {
	source:  IDWriteTextAnalysisSource,
	sink:    IDWriteTextAnalysisSink,
	text:    []u16,
	locale:  [^]u16,
	rtl:     bool,              // paragraph reading direction
	ctx:     runtime.Context,
	scripts: ^[dynamic]Script_Run,
	levels:  []u8,              // per UTF-16 unit (AnalyzeBidi)
	breaks:  []DWRITE_LINE_BREAKPOINT,   // per UTF-16 unit (AnalyzeLineBreakpoints)
}

@(private)
EMPTY_LOCALE := [1]u16{0}

@(private)
analysis_of_source :: #force_inline proc "contextless" (this: ^IDWriteTextAnalysisSource) -> ^Analysis {
	return (^Analysis)(uintptr(this) - offset_of(Analysis, source))
}

@(private)
analysis_of_sink :: #force_inline proc "contextless" (this: ^IDWriteTextAnalysisSink) -> ^Analysis {
	return (^Analysis)(uintptr(this) - offset_of(Analysis, sink))
}

@(private)
source_vtable := IDWriteTextAnalysisSource_VTable{
	QueryInterface = proc "system" (this: ^IDWriteTextAnalysisSource, riid: ^IID, out: ^rawptr) -> HRESULT {
		if riid^ == IID_IUnknown || riid^ == IID_IDWriteTextAnalysisSource { out^ = this; return S_OK }
		out^ = nil
		return E_NOINTERFACE
	},
	AddRef = proc "system" (this: ^IDWriteTextAnalysisSource) -> u32 { return 1 },
	Release = proc "system" (this: ^IDWriteTextAnalysisSource) -> u32 { return 1 },
	GetTextAtPosition = proc "system" (this: ^IDWriteTextAnalysisSource, position: u32, text: ^[^]u16, length: ^u32) -> HRESULT {
		a := analysis_of_source(this)
		if int(position) >= len(a.text) { text^ = nil; length^ = 0; return S_OK }
		text^ = raw_data(a.text[position:])
		length^ = u32(len(a.text)) - position
		return S_OK
	},
	GetTextBeforePosition = proc "system" (this: ^IDWriteTextAnalysisSource, position: u32, text: ^[^]u16, length: ^u32) -> HRESULT {
		a := analysis_of_source(this)
		if position == 0 || int(position) > len(a.text) { text^ = nil; length^ = 0; return S_OK }
		text^ = raw_data(a.text)
		length^ = position
		return S_OK
	},
	GetParagraphReadingDirection = proc "system" (this: ^IDWriteTextAnalysisSource) -> DWRITE_READING_DIRECTION {
		return analysis_of_source(this).rtl ? .RIGHT_TO_LEFT : .LEFT_TO_RIGHT
	},
	GetLocaleName = proc "system" (this: ^IDWriteTextAnalysisSource, position: u32, length: ^u32, locale: ^[^]u16) -> HRESULT {
		a := analysis_of_source(this)
		locale^ = a.locale != nil ? a.locale : raw_data(EMPTY_LOCALE[:])
		length^ = u32(len(a.text)) - min(position, u32(len(a.text)))
		return S_OK
	},
	GetNumberSubstitution = proc "system" (this: ^IDWriteTextAnalysisSource, position: u32, length: ^u32, substitution: ^rawptr) -> HRESULT {
		a := analysis_of_source(this)
		substitution^ = nil
		length^ = u32(len(a.text)) - min(position, u32(len(a.text)))
		return S_OK
	},
}

@(private)
sink_vtable := IDWriteTextAnalysisSink_VTable{
	QueryInterface = proc "system" (this: ^IDWriteTextAnalysisSink, riid: ^IID, out: ^rawptr) -> HRESULT {
		if riid^ == IID_IUnknown || riid^ == IID_IDWriteTextAnalysisSink { out^ = this; return S_OK }
		out^ = nil
		return E_NOINTERFACE
	},
	AddRef = proc "system" (this: ^IDWriteTextAnalysisSink) -> u32 { return 1 },
	Release = proc "system" (this: ^IDWriteTextAnalysisSink) -> u32 { return 1 },
	SetScriptAnalysis = proc "system" (this: ^IDWriteTextAnalysisSink, position, length: u32, sa: ^DWRITE_SCRIPT_ANALYSIS) -> HRESULT {
		a := analysis_of_sink(this)
		if a.scripts == nil { return S_OK }
		context = a.ctx
		append(a.scripts, Script_Run{position, position + length, sa^})
		return S_OK
	},
	SetLineBreakpoints = proc "system" (this: ^IDWriteTextAnalysisSink, position, length: u32, bp: [^]DWRITE_LINE_BREAKPOINT) -> HRESULT {
		a := analysis_of_sink(this)
		for i in 0 ..< length {
			if int(position + i) < len(a.breaks) { a.breaks[position + i] = bp[i] }
		}
		return S_OK
	},
	SetBidiLevel = proc "system" (this: ^IDWriteTextAnalysisSink, position, length: u32, explicit_level, resolved_level: u8) -> HRESULT {
		a := analysis_of_sink(this)
		for i in 0 ..< length {
			if int(position + i) < len(a.levels) { a.levels[position + i] = resolved_level }
		}
		return S_OK
	},
	SetNumberSubstitution = proc "system" (this: ^IDWriteTextAnalysisSink, position, length: u32, substitution: rawptr) -> HRESULT {
		return S_OK
	},
}

@(private)
analysis_init :: proc(a: ^Analysis, text: []u16, rtl: bool) {
	a.source.vtable = &source_vtable
	a.sink.vtable = &sink_vtable
	a.text = text
	a.rtl = rtl
	a.ctx = context
}
