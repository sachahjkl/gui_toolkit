#+build darwin
package font

import "base:runtime"
import "core:slice"
import "core:strings"

// The system's fonts on macOS: CoreText. A family is opened by name (CTFontCreateWithName), bold / italic by its
// symbolic traits; the fallback of a character is CTFontCreateForString's (the system's cascade list); the families are
// CTFontManagerCopyAvailableFontFamilyNames. The font's file comes from kCTFontURLAttribute; in a collection (.ttc,
// common on macOS) the face is the one with the same PostScript name, read by the native backend. Written against
// Apple's documented C API; checked by `odin check -target:darwin_arm64`, not yet run on a Mac.

foreign import core_foundation "system:CoreFoundation.framework"
foreign import core_text "system:CoreText.framework"

@(private) SYSTEM_FONT_SERVICE :: "coretext"

@(private) CF_Type :: rawptr
@(private) CF_Range :: struct { location, length: int }
@(private) CF_STRING_ENCODING_UTF8 :: u32(0x08000100)
@(private) CT_FONT_ITALIC_TRAIT :: u32(1 << 0)
@(private) CT_FONT_BOLD_TRAIT :: u32(1 << 1)

@(default_calling_convention = "c", private)
foreign core_foundation {
	CFRelease                         :: proc(cf: CF_Type) ---
	CFStringCreateWithBytes           :: proc(alloc: CF_Type, bytes: [^]u8, n: int, encoding: u32, external: b8) -> CF_Type ---
	CFStringGetLength                 :: proc(s: CF_Type) -> int ---
	CFStringGetMaximumSizeForEncoding :: proc(length: int, encoding: u32) -> int ---
	CFStringGetCString                :: proc(s: CF_Type, buf: [^]u8, size: int, encoding: u32) -> b8 ---
	CFArrayGetCount                   :: proc(a: CF_Type) -> int ---
	CFArrayGetValueAtIndex            :: proc(a: CF_Type, i: int) -> CF_Type ---
	CFURLGetFileSystemRepresentation  :: proc(url: CF_Type, resolve: b8, buf: [^]u8, size: int) -> b8 ---
}

@(default_calling_convention = "c", private)
foreign core_text {
	kCTFontURLAttribute: CF_Type
	CTFontCreateWithName                     :: proc(name: CF_Type, size: f64, mtx: rawptr) -> CF_Type ---
	CTFontCreateCopyWithSymbolicTraits       :: proc(font: CF_Type, size: f64, mtx: rawptr, value, mask: u32) -> CF_Type ---
	CTFontCopyFamilyName                     :: proc(font: CF_Type) -> CF_Type ---
	CTFontCopyPostScriptName                 :: proc(font: CF_Type) -> CF_Type ---
	CTFontCopyAttribute                      :: proc(font: CF_Type, attribute: CF_Type) -> CF_Type ---
	CTFontCreateForString                    :: proc(current: CF_Type, s: CF_Type, r: CF_Range) -> CF_Type ---
	CTFontManagerCopyAvailableFontFamilyNames :: proc() -> CF_Type ---
}

@(private)
cf_string :: proc(s: string) -> CF_Type {
	return CFStringCreateWithBytes(nil, raw_data(s), len(s), CF_STRING_ENCODING_UTF8, false)
}

// A CFString as an Odin string (`allocator`).
@(private)
cf_to_string :: proc(s: CF_Type, allocator: runtime.Allocator) -> string {
	if s == nil { return "" }
	n := CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), CF_STRING_ENCODING_UTF8) + 1
	buf := make([]u8, n, context.temp_allocator)
	if !CFStringGetCString(s, raw_data(buf), n, CF_STRING_ENCODING_UTF8) { return "" }
	return strings.clone(string(cstring(raw_data(buf))), allocator)
}

// The file and face of a CTFont (temp memory).
@(private)
ct_font_file :: proc(font: CF_Type) -> (path: string, index: int, ok: bool) {
	url := CTFontCopyAttribute(font, kCTFontURLAttribute)
	if url == nil { return }
	defer CFRelease(url)
	buf: [4096]u8
	if !CFURLGetFileSystemRepresentation(url, true, &buf[0], len(buf)) { return }
	path = strings.clone(string(cstring(&buf[0])), context.temp_allocator)
	ps := CTFontCopyPostScriptName(font)
	defer if ps != nil { CFRelease(ps) }
	return path, ct_face_index(path, cf_to_string(ps, context.temp_allocator)), true
}

// The face of a collection with this PostScript name (0 when the file holds one face, or without the native backend).
@(private)
ct_face_index :: proc(path, ps_name: string) -> int {
	when NATIVE_TEXT {
		n := gt_file_face_count(raw_data(path), uint(len(path)))
		if n <= 1 || ps_name == "" { return 0 }
		for i in 0 ..< n {
			face := gt_face_open_file(raw_data(path), uint(len(path)), i, nil, 0)
			if face == nil { continue }
			buf: [256]u8
			l := gt_face_postscript_name(face, &buf[0], len(buf))
			gt_face_close(face)
			if l <= len(buf) && string(buf[:l]) == ps_name { return int(i) }
		}
	}
	return 0
}

@(private)
ct_font :: proc(family: string, weight: int, style: Font_Style) -> CF_Type {
	name := cf_string(family)
	if name == nil { return nil }
	defer CFRelease(name)
	font := CTFontCreateWithName(name, 12, nil)
	if font == nil { return nil }
	// CoreText answers a missing family with a default font: the family must be the one asked for
	fam := CTFontCopyFamilyName(font)
	same := strings.equal_fold(cf_to_string(fam, context.temp_allocator), family)
	if fam != nil { CFRelease(fam) }
	if !same { CFRelease(font); return nil }
	traits: u32
	if weight >= 600 { traits |= CT_FONT_BOLD_TRAIT }
	if style != .Normal { traits |= CT_FONT_ITALIC_TRAIT }
	if traits != 0 {
		if styled := CTFontCreateCopyWithSymbolicTraits(font, 12, nil, traits, traits); styled != nil {
			CFRelease(font)
			font = styled
		}
	}
	return font
}

@(private)
sys_find :: proc(family: string, weight: int, style: Font_Style, stretch: int) -> (path: string, index: int, ok: bool) {
	if family == "" { return }
	font := ct_font(family, weight, style)
	if font == nil { return }
	defer CFRelease(font)
	return ct_font_file(font)
}

@(private)
sys_find_for_char :: proc(family: string, weight: int, style: Font_Style, r: rune) -> (path: string, index: int, ok: bool) {
	base := ct_font(family != "" ? family : "Helvetica", weight, style)
	if base == nil { base = ct_font("Helvetica", weight, style) }
	if base == nil { return }
	defer CFRelease(base)
	buf: [4]u8
	n := encode_utf8(buf[:], r)
	s := cf_string(string(buf[:n]))
	if s == nil { return }
	defer CFRelease(s)
	font := CTFontCreateForString(base, s, {0, CFStringGetLength(s)})
	if font == nil { return }
	defer CFRelease(font)
	return ct_font_file(font)
}

@(private)
sys_families :: proc(allocator: runtime.Allocator) -> []string {
	arr := CTFontManagerCopyAvailableFontFamilyNames()
	if arr == nil { return nil }
	defer CFRelease(arr)
	n := CFArrayGetCount(arr)
	out := make([dynamic]string, 0, n, allocator)
	for i in 0 ..< n {
		if name := cf_to_string(CFArrayGetValueAtIndex(arr, i), allocator); name != "" { append(&out, name) }
	}
	slice.sort_by(out[:], proc(a, b: string) -> bool { return strings.compare(a, b) < 0 })
	return out[:]
}

@(private)
sys_has_family :: proc(family: string) -> bool {
	font := ct_font(family, 400, .Normal)
	if font == nil { return false }
	CFRelease(font)
	return true
}
