package font

import "base:runtime"
import "core:slice"
import "core:strings"

// Families as a person chooses them: the system's list (system_families), and the family a face is (family_of). The
// font picker (ui.font_picker, src/md/features/font-picker.md) reads both.

// One installed family: its name, as the system's font service names it ("DejaVu Sans Mono"), and whether its faces say
// they are monospace (fontconfig's spacing; DirectWrite's IsMonospacedFont; false where the service does not say).
Family :: struct {
	name:      string,
	monospace: bool,
}

// The family `id` is (a cascade's: its first live face's), as a person reads it: the family it was loaded as
// (load_system), else the one its `name` table gives (its typographic family, else its family): the embedded Roboto is
// "Roboto", a file opened by its path is what it says it is. "" for an id that is no live font, or a face that names no
// family. The string is the font's: valid while it is loaded (clone it to keep it).
family_of :: proc(s: ^State, id: Font_Id) -> string {
	if s == nil { return "" }
	f := face_ptr(s, primary_face(s, id))
	if f == nil { return "" }
	return f.name
}

// Sorts `out` by name and keeps each family once (a font set can list one twice; a family is monospace when one of its
// entries is), its names in `allocator`.
@(private)
families_sorted :: proc(out: ^[dynamic]Family, allocator: runtime.Allocator) -> []Family {
	slice.sort_by(out[:], proc(a, b: Family) -> bool { return strings.compare(a.name, b.name) < 0 })
	k := 0
	for i in 0 ..< len(out) {
		if k > 0 && out[k - 1].name == out[i].name {
			out[k - 1].monospace ||= out[i].monospace
			delete(out[i].name, allocator)
			continue
		}
		out[k] = out[i]
		k += 1
	}
	resize(out, k)
	return out[:]
}

////////////////////////////////
// The `name` table

// The OpenType name ids of a family: the typographic one (a family of more than four styles: "Inter", where name 1 says
// "Inter Medium"), then the legacy one.
@(private = "file") NAME_TYPOGRAPHIC_FAMILY :: 16
@(private = "file") NAME_FAMILY :: 1
@(private = "file") NAME_HEADER_BYTES :: 6
@(private = "file") NAME_RECORD_BYTES :: 12
// The platforms of a name record: Unicode, Macintosh, Windows; and the languages preferred in each.
@(private = "file") NAME_PLATFORM_UNICODE :: 0
@(private = "file") NAME_PLATFORM_MAC :: 1
@(private = "file") NAME_PLATFORM_WINDOWS :: 3
@(private = "file") NAME_MAC_ROMAN :: 0
@(private = "file") NAME_MAC_ENGLISH :: 0
@(private = "file") NAME_WINDOWS_SYMBOL :: 0
@(private = "file") NAME_WINDOWS_EN_US :: 0x409

// The family a face's own `name` table gives (heap; "" when it has none, or the backend reads no table).
@(private)
face_name_family :: proc(f: ^Font) -> string {
	data, ctx := face_table_read(f, "name")
	defer face_table_release(f, ctx)
	return name_table_family(data, runtime.heap_allocator())
}

// The family a `name` table gives, in `allocator`: name 16 before name 1; among the records of one name, Windows'
// American English, then any Windows one, then Unicode's, then Macintosh's English in Mac Roman (its ASCII alone).
@(private)
name_table_family :: proc(data: []u8, allocator := context.allocator) -> string {
	be16 :: proc(d: []u8, at: int) -> int { return int(d[at]) << 8 | int(d[at + 1]) }
	if len(data) < NAME_HEADER_BYTES { return "" }
	count, storage := be16(data, 2), be16(data, 4)
	best, best_rank := -1, 0
	for i in 0 ..< count {
		at := NAME_HEADER_BYTES + i * NAME_RECORD_BYTES
		if at + NAME_RECORD_BYTES > len(data) { break }
		platform, encoding, language, name := be16(data, at), be16(data, at + 2), be16(data, at + 4), be16(data, at + 6)
		length, offset := be16(data, at + 8), be16(data, at + 10)
		if storage + offset + length > len(data) || length == 0 { continue }
		rank := 0
		switch name {
		case NAME_TYPOGRAPHIC_FAMILY: rank = 10
		case NAME_FAMILY:             rank = 0
		case:                         continue
		}
		switch {
		case platform == NAME_PLATFORM_WINDOWS && encoding != NAME_WINDOWS_SYMBOL && language == NAME_WINDOWS_EN_US: rank += 5
		case platform == NAME_PLATFORM_WINDOWS && encoding != NAME_WINDOWS_SYMBOL: rank += 4
		case platform == NAME_PLATFORM_UNICODE: rank += 3
		case platform == NAME_PLATFORM_MAC && encoding == NAME_MAC_ROMAN && language == NAME_MAC_ENGLISH: rank += 2
		case: continue
		}
		if rank > best_rank || best < 0 { best, best_rank = i, rank }
	}
	if best < 0 { return "" }
	at := NAME_HEADER_BYTES + best * NAME_RECORD_BYTES
	platform := be16(data, at)
	length, offset := be16(data, at + 8), be16(data, at + 10)
	raw := data[storage + offset:][:length]
	sb := strings.builder_make(allocator)
	if platform == NAME_PLATFORM_MAC {
		for c in raw { if c >= ' ' && c < 0x7f { strings.write_byte(&sb, c) } }
	} else {
		// UTF-16, big-endian
		for i := 0; i + 1 < len(raw); i += 2 {
			u := rune(be16(raw, i))
			if u >= 0xd800 && u < 0xdc00 && i + 3 < len(raw) {
				lo := rune(be16(raw, i + 2))
				if lo >= 0xdc00 && lo < 0xe000 { u = 0x10000 + (u - 0xd800) << 10 + (lo - 0xdc00); i += 2 }
			}
			if u >= 0xd800 && u < 0xe000 { continue }   // (a lone surrogate)
			strings.write_rune(&sb, u)
		}
	}
	out := strings.to_string(sb)
	if trimmed := strings.trim_space(out); len(trimmed) != len(out) {
		// (the caller frees what it is given: a trimmed slice of the builder is not that)
		kept := strings.clone(trimmed, allocator)
		strings.builder_destroy(&sb)
		return kept
	}
	return out
}
