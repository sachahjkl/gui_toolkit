#+build linux
package font

import "base:runtime"
import "core:c"
import "core:slice"
import "core:strings"
import "core:sync"

// The system's fonts on Linux: fontconfig (libfontconfig.so.1, present wherever there is a desktop). A family / weight /
// style is matched with FcFontMatch after the configuration's substitutions; the fallback of a character is the best
// match whose charset has it; the families are FcFontList's. Written against fontconfig's documented C API (2.11+:
// FcWeightFromOpenType); checked by `odin check -target:linux_amd64`, not yet run on a Linux machine.

foreign import fontconfig "system:fontconfig"

@(private) SYSTEM_FONT_SERVICE :: "fontconfig"

@(private) Fc_Pattern :: struct {}
@(private) Fc_Config :: struct {}
@(private) Fc_Char_Set :: struct {}
@(private) Fc_Object_Set :: struct {}
@(private) Fc_Font_Set :: struct { nfont, sfont: c.int, fonts: [^]^Fc_Pattern }
@(private) Fc_Result :: enum c.int { Match, No_Match, Type_Mismatch, No_Id, Out_Of_Memory }
@(private) FC_MATCH_PATTERN :: c.int(0)
@(private) FC_SLANT_ROMAN :: c.int(0)
@(private) FC_SLANT_ITALIC :: c.int(100)
@(private) FC_SLANT_OBLIQUE :: c.int(110)

@(default_calling_convention = "c", private)
foreign fontconfig {
	FcInit                :: proc() -> c.int ---
	FcPatternCreate       :: proc() -> ^Fc_Pattern ---
	FcPatternDestroy      :: proc(p: ^Fc_Pattern) ---
	FcPatternAddString    :: proc(p: ^Fc_Pattern, object: cstring, s: cstring) -> c.int ---
	FcPatternAddInteger   :: proc(p: ^Fc_Pattern, object: cstring, i: c.int) -> c.int ---
	FcPatternAddCharSet   :: proc(p: ^Fc_Pattern, object: cstring, cs: ^Fc_Char_Set) -> c.int ---
	FcPatternGetString    :: proc(p: ^Fc_Pattern, object: cstring, n: c.int, s: ^cstring) -> Fc_Result ---
	FcPatternGetInteger   :: proc(p: ^Fc_Pattern, object: cstring, n: c.int, i: ^c.int) -> Fc_Result ---
	FcPatternGetCharSet   :: proc(p: ^Fc_Pattern, object: cstring, n: c.int, cs: ^^Fc_Char_Set) -> Fc_Result ---
	FcConfigSubstitute    :: proc(config: ^Fc_Config, p: ^Fc_Pattern, kind: c.int) -> c.int ---
	FcDefaultSubstitute   :: proc(p: ^Fc_Pattern) ---
	FcFontMatch           :: proc(config: ^Fc_Config, p: ^Fc_Pattern, result: ^Fc_Result) -> ^Fc_Pattern ---
	FcFontList            :: proc(config: ^Fc_Config, p: ^Fc_Pattern, os: ^Fc_Object_Set) -> ^Fc_Font_Set ---
	FcFontSetDestroy      :: proc(fs: ^Fc_Font_Set) ---
	FcObjectSetCreate     :: proc() -> ^Fc_Object_Set ---
	FcObjectSetAdd        :: proc(os: ^Fc_Object_Set, object: cstring) -> c.int ---
	FcObjectSetDestroy    :: proc(os: ^Fc_Object_Set) ---
	FcCharSetCreate       :: proc() -> ^Fc_Char_Set ---
	FcCharSetAddChar      :: proc(cs: ^Fc_Char_Set, ucs4: u32) -> c.int ---
	FcCharSetHasChar      :: proc(cs: ^Fc_Char_Set, ucs4: u32) -> c.int ---
	FcCharSetDestroy      :: proc(cs: ^Fc_Char_Set) ---
	FcWeightFromOpenType  :: proc(ot_weight: c.int) -> c.int ---
}

@(private) fc_once: sync.Once
@(private) fc_ok: bool

@(private)
fc_init :: proc() -> bool {
	sync.once_do(&fc_once, proc() { fc_ok = FcInit() != 0 })
	return fc_ok
}

// A pattern for a family (may be "") at weight / style, with the configuration's substitutions applied.
@(private)
fc_pattern :: proc(family: string, weight: int, style: Font_Style, stretch: int) -> ^Fc_Pattern {
	p := FcPatternCreate()
	if p == nil { return nil }
	if family != "" { FcPatternAddString(p, "family", strings.clone_to_cstring(family, context.temp_allocator)) }
	FcPatternAddInteger(p, "weight", FcWeightFromOpenType(c.int(clamp(weight, 1, 1000))))
	slant := FC_SLANT_ROMAN
	switch style {
	case .Normal:  slant = FC_SLANT_ROMAN
	case .Italic:  slant = FC_SLANT_ITALIC
	case .Oblique: slant = FC_SLANT_OBLIQUE
	}
	FcPatternAddInteger(p, "slant", slant)
	// CSS stretch 1..9 to fontconfig's width (50 ultra-condensed .. 200 ultra-expanded)
	widths := [9]c.int{50, 63, 75, 87, 100, 113, 125, 150, 200}
	FcPatternAddInteger(p, "width", widths[clamp(stretch, 1, 9) - 1])
	return p
}

// The file and face index of a matched pattern (temp memory).
@(private)
fc_file :: proc(m: ^Fc_Pattern) -> (path: string, index: int, ok: bool) {
	file: cstring
	if FcPatternGetString(m, "file", 0, &file) != .Match || file == nil { return }
	idx: c.int
	if FcPatternGetInteger(m, "index", 0, &idx) != .Match { idx = 0 }
	return strings.clone(string(file), context.temp_allocator), int(idx & 0xFFFF), true   // high bits: a named instance
}

@(private)
sys_find :: proc(family: string, weight: int, style: Font_Style, stretch: int) -> (path: string, index: int, ok: bool) {
	if !fc_init() || family == "" { return }
	p := fc_pattern(family, weight, style, stretch)
	if p == nil { return }
	defer FcPatternDestroy(p)
	FcConfigSubstitute(nil, p, FC_MATCH_PATTERN)
	FcDefaultSubstitute(p)
	res: Fc_Result
	m := FcFontMatch(nil, p, &res)
	if m == nil { return }
	defer FcPatternDestroy(m)
	// fontconfig always answers (its default font): the family must be the one asked for
	got: cstring
	if FcPatternGetString(m, "family", 0, &got) != .Match || !strings.equal_fold(string(got), family) { return }
	return fc_file(m)
}

@(private)
sys_find_for_char :: proc(family: string, weight: int, style: Font_Style, r: rune) -> (path: string, index: int, ok: bool) {
	if !fc_init() { return }
	p := fc_pattern(family, weight, style, 5)
	if p == nil { return }
	defer FcPatternDestroy(p)
	cs := FcCharSetCreate()
	if cs == nil { return }
	FcCharSetAddChar(cs, u32(r))
	FcPatternAddCharSet(p, "charset", cs)
	FcCharSetDestroy(cs)
	FcConfigSubstitute(nil, p, FC_MATCH_PATTERN)
	FcDefaultSubstitute(p)
	res: Fc_Result
	m := FcFontMatch(nil, p, &res)
	if m == nil { return }
	defer FcPatternDestroy(m)
	has: ^Fc_Char_Set
	if FcPatternGetCharSet(m, "charset", 0, &has) != .Match || has == nil || FcCharSetHasChar(has, u32(r)) == 0 { return }
	return fc_file(m)
}

@(private)
fc_list_families :: proc(family: string, allocator: runtime.Allocator) -> []string {
	if !fc_init() { return nil }
	p := FcPatternCreate()
	if p == nil { return nil }
	defer FcPatternDestroy(p)
	if family != "" { FcPatternAddString(p, "family", strings.clone_to_cstring(family, context.temp_allocator)) }
	os := FcObjectSetCreate()
	if os == nil { return nil }
	defer FcObjectSetDestroy(os)
	FcObjectSetAdd(os, "family")
	fs := FcFontList(nil, p, os)
	if fs == nil { return nil }
	defer FcFontSetDestroy(fs)
	out := make([dynamic]string, 0, int(fs.nfont), allocator)
	for i in 0 ..< int(fs.nfont) {
		name: cstring
		if FcPatternGetString(fs.fonts[i], "family", 0, &name) == .Match && name != nil { append(&out, strings.clone(string(name), allocator)) }
	}
	slice.sort_by(out[:], proc(a, b: string) -> bool { return strings.compare(a, b) < 0 })
	k := 0
	for i in 0 ..< len(out) {
		if k > 0 && out[k - 1] == out[i] { delete(out[i], allocator); continue }
		out[k] = out[i]
		k += 1
	}
	resize(&out, k)
	return out[:]
}

@(private)
sys_has_family :: proc(family: string) -> bool {
	l := fc_list_families(family, context.temp_allocator)
	for f in l { if strings.equal_fold(f, family) { return true } }
	return false
}

@(private)
sys_families :: proc(allocator: runtime.Allocator) -> []string { return fc_list_families("", allocator) }
