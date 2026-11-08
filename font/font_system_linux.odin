#+build linux
package font

import "base:runtime"
import "core:c"
import "core:slice"
import "core:strings"
import "core:sync"
import "../ascii"

// The system's fonts on Linux: fontconfig (libfontconfig.so.1, present wherever there is a desktop). A family / weight /
// style is matched with FcFontMatch after the configuration's substitutions. A family that is not installed stands for
// the installed one the configuration binds to its name (an alias: Liberation Mono for "Courier New"), and a generic
// family (monospace) for the font fontconfig picks: fc_resolve_family. The fallback of a character is the best match
// whose charset has it; the families are FcFontList's. Written against fontconfig's documented C API (2.11+:
// FcWeightFromOpenType); tested on Linux by tests/color_native/system_fonts_test_linux.odin.

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
// What FcWeightFromOpenType takes at most.
@(private) FC_OPENTYPE_WEIGHT_MAX :: 1000

@(default_calling_convention = "c", private)
foreign fontconfig {
	FcInit                :: proc() -> c.int ---
	FcPatternCreate       :: proc() -> ^Fc_Pattern ---
	FcPatternDestroy      :: proc(p: ^Fc_Pattern) ---
	FcPatternAddString    :: proc(p: ^Fc_Pattern, object: cstring, s: cstring) -> c.int ---
	FcPatternAddInteger   :: proc(p: ^Fc_Pattern, object: cstring, i: c.int) -> c.int ---
	FcPatternAddCharSet   :: proc(p: ^Fc_Pattern, object: cstring, cs: ^Fc_Char_Set) -> c.int ---
	FcPatternAddBool      :: proc(p: ^Fc_Pattern, object: cstring, b: c.int) -> c.int ---
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
	FcPatternAddInteger(p, "weight", FcWeightFromOpenType(c.int(clamp(weight, 1, FC_OPENTYPE_WEIGHT_MAX))))
	slant := FC_SLANT_ROMAN
	switch style {
	case .Normal:  slant = FC_SLANT_ROMAN
	case .Italic:  slant = FC_SLANT_ITALIC
	case .Oblique: slant = FC_SLANT_OBLIQUE
	}
	FcPatternAddInteger(p, "slant", slant)
	// CSS stretch 1..9 to fontconfig's width (50 ultra-condensed .. 200 ultra-expanded)
	widths := [FONT_STRETCH_MAX]c.int{50, 63, 75, 87, 100, 113, 125, 150, 200}
	FcPatternAddInteger(p, "width", widths[clamp(stretch, 1, FONT_STRETCH_MAX) - 1])
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

// fontconfig's generic families: the configuration picks their font, whatever its name (fc-match monospace).
@(private) FC_GENERICS :: [?]string{"serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui", "emoji", "math"}

// Put after the family asked for: what fontconfig's substitution puts before it binds to that name.
@(private) FC_SENTINEL :: "gui-toolkit-sentinel"

@(private)
fc_is_generic :: proc(family: string) -> bool {
	for g in FC_GENERICS { if ascii.equal_fold(g, family) { return true } }
	return false
}

// The installed family that stands for `family` (temp memory): the family itself when it is installed, else the first
// installed family the configuration binds to that name, such as Liberation Mono for "Courier New" (30-metric-aliases.conf).
// fontconfig always answers with some font, so not every answer counts: a sentinel family is added after `family`, and
// the substitution puts the aliases of `family` before it and the defaults (the generic families, sans-serif) after it.
// Firefox reads fontconfig's aliases the same way. A generic family stands for itself: fontconfig resolves it.
@(private)
fc_resolve_family :: proc(family: string) -> (resolved: string, ok: bool) {
	if family == "" || !fc_init() { return }
	if fc_is_generic(family) || fc_installed(family) { return family, true }
	p := FcPatternCreate()
	if p == nil { return }
	defer FcPatternDestroy(p)
	FcPatternAddString(p, "family", strings.clone_to_cstring(family, context.temp_allocator))
	FcPatternAddString(p, "family", FC_SENTINEL)
	FcConfigSubstitute(nil, p, FC_MATCH_PATTERN)
	for i := c.int(0); ; i += 1 {
		name: cstring
		if FcPatternGetString(p, "family", i, &name) != .Match || name == nil { break }
		n := string(name)
		if n == FC_SENTINEL { break }
		if ascii.equal_fold(n, family) { continue }
		if fc_installed(n) { return strings.clone(n, context.temp_allocator), true }
	}
	return
}

@(private)
fc_installed :: proc(family: string) -> bool {
	for f in fc_list_families(family, context.temp_allocator) { if ascii.equal_fold(f, family) { return true } }
	return false
}

@(private)
sys_find :: proc(family: string, weight: int, style: Font_Style, stretch: int) -> (path: string, index: int, ok: bool) {
	target := fc_resolve_family(family) or_return
	p := fc_pattern(target, weight, style, stretch)
	if p == nil { return }
	defer FcPatternDestroy(p)
	FcConfigSubstitute(nil, p, FC_MATCH_PATTERN)
	FcDefaultSubstitute(p)
	res: Fc_Result
	m := FcFontMatch(nil, p, &res)
	if m == nil { return }
	defer FcPatternDestroy(m)
	// fontconfig always answers (its default font): the family must be the one resolved, unless it is a generic one
	got: cstring
	if FcPatternGetString(m, "family", 0, &got) != .Match { return }
	if !fc_is_generic(target) && !ascii.equal_fold(string(got), target) { return }
	return fc_file(m)
}

@(private)
sys_find_for_char :: proc(family: string, weight: int, style: Font_Style, r: rune, emoji := false) -> (path: string, index: int, ok: bool) {
	if !fc_init() { return }
	// an emoji: a color font, before any other that has the character (DejaVu Sans has its own plain 😀)
	p := fc_pattern(emoji ? "emoji" : family, weight, style, FONT_STRETCH_NORMAL)
	if p == nil { return }
	defer FcPatternDestroy(p)
	if emoji { FcPatternAddBool(p, "color", 1) }
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
	_, ok := fc_resolve_family(family)
	return ok
}

@(private)
sys_families :: proc(allocator: runtime.Allocator) -> []string { return fc_list_families("", allocator) }
