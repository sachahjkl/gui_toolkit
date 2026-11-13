package tk_toolbox

// The symbols of a program's crash reports (gt:crash). A release has no PDB and no debug information worth shipping: its report names
// the build (crash.build_id) and gives each frame as a module and an offset; these turn the offsets of the program's own module into
// functions, offline, with what the build left:
//
//	Windows  the linker's map (link with CRASH_LINKER_FLAGS: /MAP), renamed <exe stem>-<build>.map by crash_publish_symbols after
//	         each link, kept with the release. Read here in pure Odin: a Windows report is named on any system.
//	Linux    the executable itself, linked with --build-id (CRASH_LINKER_FLAGS); its debug information names the offsets through
//	         addr2line (binutils). The build id in the report must be the executable's.
//
//	crash_build_id          the build a file is (a PE executable's "%08X%X", an ELF executable's GNU build id)
//	crash_publish_symbols   after a link: Windows renames the map by the build; Linux checks that the executable has a build id
//	crash_symbolize         a report's text with the program's frames named

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../ascii"
import crash "../crash"

// What a program's -extra-linker-flags must hold for its reports to be named: the map (Windows), the build id (Linux).
CRASH_LINKER_FLAGS :: "/MAP" when ODIN_OS == .Windows else "-Wl,--build-id"

@(private = "file") HEADER_READ_BYTES :: 64 * 1024
@(private = "file") PE_NT_OFFSET :: 0x3C
@(private = "file") PE_STAMP_OFFSET :: 8
@(private = "file") PE_SIZE_OF_IMAGE_OFFSET :: 24 + 56
@(private = "file") PE_SIGNATURE :: 0x00004550
@(private = "file") PE_DEFAULT_BASE :: u64(0x140000000)
// A map older than its executable by more than this is not this link's.
@(private = "file") MAP_OLDER_SECONDS :: 300
@(private = "file") ELF_PHOFF_AT :: 0x20
@(private = "file") ELF_PHENTSIZE_AT :: 0x36
@(private = "file") ELF_PHNUM_AT :: 0x38
@(private = "file") ELF_PT_LOAD :: 1
@(private = "file") ELF_PT_NOTE :: 4
@(private = "file") ELF_NT_GNU_BUILD_ID :: 3

// The build `path` is, as a crash report names it: a PE file's link time stamp and image size ("%08X%X"), an ELF file's GNU build id
// (hex). ok is false for another file, or an ELF file linked without --build-id. Any system reads either.
crash_build_id :: proc(path: string, allocator := context.temp_allocator) -> (id: string, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return "", false }
	if pe, good := pe_build_id(data, allocator); good { return pe, true }
	e, good := elf_read(data)
	if !good || e.build_id == "" { return "", false }
	return strings.clone(e.build_id, allocator), true
}

// After a link. Windows: <dir>/<stem>.map (the linker's, /MAP) becomes <dir>/<stem>-<build>.map, and the older maps of that stem
// go; `named` is the map's new path. Linux: the executable must carry a build id (--build-id); `named` is the executable. why != "":
// what is wrong.
crash_publish_symbols :: proc(exe: string, allocator := context.temp_allocator) -> (named: string, why: string) {
	id, ok := crash_build_id(exe)
	if !ok { return "", fmt.tprintf("%s has no build id (link it with -extra-linker-flags:%s)", exe, CRASH_LINKER_FLAGS) }
	if !strings.has_suffix(ascii.lower(exe), ".exe") { return strings.clone(exe, allocator), "" }
	dir, stem := filepath.dir(exe), filepath.stem(exe)
	map_file := fmt.tprintf("%s/%s.map", dir, stem)
	map_info, merr := os.stat(map_file, context.temp_allocator)
	if merr != nil { return "", fmt.tprintf("%s is not there (link with -extra-linker-flags:%s)", map_file, CRASH_LINKER_FLAGS) }
	exe_info, eerr := os.stat(exe, context.temp_allocator)
	if eerr == nil && exe_info.modification_time._nsec - map_info.modification_time._nsec > MAP_OLDER_SECONDS * 1_000_000_000 {
		return "", fmt.tprintf("%s is older than %s: not this link's", map_file, exe)
	}
	named = fmt.aprintf("%s/%s-%s.map", dir, stem, id, allocator = allocator)
	_ = os.remove(named)
	if os.rename(map_file, named) != nil { return "", fmt.tprintf("%s cannot be renamed", map_file) }
	entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	keep := filepath.base(named)
	for e in entries { if e.name != keep && is_map_of(e.name, stem) { _ = os.remove(e.fullpath) } }
	return named, ""
}

// The report at `report_path` with the frames of the program's module named from `symbols`: a map (.map), a folder holding
// "<stem>-<build>.map", or (Linux reports) the executable that crashed. The text is a report again (crash.report_parse reads it), with
// a "symbols" line saying from what. why != "": nothing could be named, and why.
crash_symbolize :: proc(report_path, symbols: string, allocator := context.allocator) -> (text: string, why: string) {
	data, err := os.read_entire_file(report_path, context.temp_allocator)
	if err != nil { return "", fmt.tprintf("%s cannot be read", report_path) }
	r, ok := crash.report_parse(string(data), context.temp_allocator)
	if !ok { return "", fmt.tprintf("%s is not a crash report", report_path) }
	module, has_module := program_module(r)
	if !has_module { return "", "the report lists no module of the program" }

	names: Name_Source
	names, why = open_names(symbols, r.build)
	if why != "" { return "", why }
	named := 0
	for &t in r.threads {
		for &f, i in t.frames {
			if f.module != module.name || f.symbol != "" { continue }
			// a frame past the first is a return address: the call is the byte before it
			at := f.offset - (i > 0 && f.offset > 0 ? 1 : 0)
			if name := name_of(&names, at); name != "" {
				f.symbol = name
				named += 1
			}
		}
	}
	append(&r.extra, crash.Field{"symbols", fmt.tprintf("%s (%d frames named)", names.from, named)})
	if names.warning != "" { append(&r.extra, crash.Field{"symbols-warning", names.warning}) }
	return crash.report_text(r, allocator), ""
}

////////////////////////////////
// Inside

// <stem>-<hex>.map
@(private = "file")
is_map_of :: proc(name, stem: string) -> bool {
	prefix := fmt.tprintf("%s-", stem)
	if !strings.has_prefix(name, prefix) || !strings.has_suffix(name, ".map") { return false }
	return is_hex(name[len(prefix):len(name) - len(".map")])
}

@(private = "file")
is_hex :: proc(s: string) -> bool {
	if s == "" { return false }
	for c in transmute([]u8)s {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) { return false }
	}
	return true
}

@(private = "file")
u16_at :: proc(b: []u8, at: int) -> u16 { return u16(b[at]) | u16(b[at + 1]) << 8 }
@(private = "file")
u32_at :: proc(b: []u8, at: int) -> u32 { return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24 }
@(private = "file")
u64_at :: proc(b: []u8, at: int) -> u64 { return u64(u32_at(b, at)) | u64(u32_at(b, at + 4)) << 32 }

@(private = "file")
pe_build_id :: proc(b: []u8, allocator := context.temp_allocator) -> (id: string, ok: bool) {
	if len(b) < PE_NT_OFFSET + 4 || b[0] != 'M' || b[1] != 'Z' { return }
	nt := int(u32_at(b, PE_NT_OFFSET))
	if nt < 0 || nt + PE_SIZE_OF_IMAGE_OFFSET + 4 > len(b) || u32_at(b, nt) != PE_SIGNATURE { return }
	return fmt.aprintf("%08X%X", u32_at(b, nt + PE_STAMP_OFFSET), u32_at(b, nt + PE_SIZE_OF_IMAGE_OFFSET), allocator = allocator), true
}

@(private = "file")
Elf :: struct {
	build_id:   string,   // (temporary memory)
	load_vaddr: u64,      // the lowest PT_LOAD's address: 0 for a position-independent executable
}

// A 64-bit little-endian ELF file's build id and load address, from its program headers.
@(private = "file")
elf_read :: proc(b: []u8) -> (e: Elf, ok: bool) {
	if len(b) < 0x40 || string(b[:4]) != "\x7fELF" || b[4] != 2 || b[5] != 1 { return }
	phoff := int(u64_at(b, ELF_PHOFF_AT))
	phsize := int(u16_at(b, ELF_PHENTSIZE_AT))
	phnum := int(u16_at(b, ELF_PHNUM_AT))
	if phoff <= 0 || phsize < 56 || phoff + phsize * phnum > len(b) { return }
	e.load_vaddr = max(u64)
	for i in 0 ..< phnum {
		p := phoff + i * phsize
		kind := u32_at(b, p)
		offset, vaddr, filesz := int(u64_at(b, p + 8)), u64_at(b, p + 16), int(u64_at(b, p + 32))
		if kind == ELF_PT_LOAD && vaddr < e.load_vaddr { e.load_vaddr = vaddr }
		if kind != ELF_PT_NOTE || offset < 0 || offset + filesz > len(b) { continue }
		at, end := offset, offset + filesz
		for at + 12 <= end {
			namesz, descsz, note := int(u32_at(b, at)), int(u32_at(b, at + 4)), u32_at(b, at + 8)
			name := at + 12
			desc := name + (namesz + 3) &~ 3
			if desc + descsz > end { break }
			if note == ELF_NT_GNU_BUILD_ID && namesz == 4 && string(b[name:name + 3]) == "GNU" {
				out := strings.builder_make(context.temp_allocator)
				for k in 0 ..< descsz { fmt.sbprintf(&out, "%02x", b[desc + k]) }
				e.build_id = strings.to_string(out)
			}
			at = desc + (descsz + 3) &~ 3
		}
	}
	if e.load_vaddr == max(u64) { e.load_vaddr = 0 }
	return e, true
}

// The module of the program: the one named as the program (with ".exe" on Windows), else the first listed (the executable, on both
// systems).
@(private = "file")
program_module :: proc(r: crash.Report) -> (m: crash.Module, ok: bool) {
	if len(r.modules) == 0 { return }
	for mod in r.modules {
		if mod.name == r.program || strings.trim_suffix(mod.name, ".exe") == r.program { return mod, true }
	}
	return r.modules[0], true
}

@(private = "file")
Map_Symbol :: struct { rva: u64, name: string }

// Where names come from: a map's symbols, or an executable for addr2line.
@(private = "file")
Name_Source :: struct {
	from:       string,
	warning:    string,
	symbols:    []Map_Symbol,   // a map's, by address
	exe:        string,         // an ELF executable's path (addr2line)
	load_vaddr: u64,
}

@(private = "file")
open_names :: proc(symbols, build: string) -> (n: Name_Source, why: string) {
	path := symbols
	if os.is_dir(symbols) {
		path = ""
		entries, _ := os.read_all_directory_by_path(symbols, context.temp_allocator)
		suffix := fmt.tprintf("-%s.map", build)
		for e in entries { if strings.has_suffix(e.name, suffix) { path = e.fullpath; break } }
		if path == "" { return n, fmt.tprintf("no map of build %s in %s (a file '*%s')", build, symbols, suffix) }
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return n, fmt.tprintf("%s cannot be read", path) }
	n.from = path
	if e, is_elf := elf_read(data); is_elf {
		if build != "" && e.build_id != build { return n, fmt.tprintf("the report is of build %s, %s is %s: give the executable that crashed", build, path, e.build_id != "" ? e.build_id : "without a build id") }
		n.exe, n.load_vaddr = path, e.load_vaddr
		return n, ""
	}
	stamp: string
	n.symbols, stamp = read_linker_map(string(data))
	if len(n.symbols) == 0 { return n, fmt.tprintf("%s is neither a linker map nor an ELF executable", path) }
	if stamp != "" && len(build) >= 8 && stamp != build[:8] {
		n.warning = fmt.tprintf("this map is of the link %s, the report's build is %s: right only if both links came from the same sources and flags", stamp, build)
	}
	return n, ""
}

// "  0001:00000000       pkg::proc       0000000140001000 f   obj": the functions by their offset in the image, and the link's time stamp.
@(private = "file")
read_linker_map :: proc(text: string) -> (symbols: []Map_Symbol, stamp: string) {
	load_base := PE_DEFAULT_BASE
	out := make([dynamic]Map_Symbol, context.temp_allocator)
	PREFERRED :: "Preferred load address is "
	STAMP :: "Timestamp is "
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(raw)
		if i := strings.index(l, PREFERRED); i >= 0 {
			if v, good := strconv.parse_u64(l[i + len(PREFERRED):], 16); good { load_base = v }
			continue
		}
		if strings.has_prefix(l, STAMP) {
			words := strings.fields(l[len(STAMP):], context.temp_allocator)
			if len(words) > 0 {
				w := ascii.upper(words[0])
				for len(w) < 8 { w = fmt.tprintf("0%s", w) }
				stamp = w
			}
			continue
		}
		parts := strings.fields(l, context.temp_allocator)
		if len(parts) < 3 || len(parts[0]) != 13 || parts[0][4] != ':' || parts[0][:4] == "0000" || !is_hex(parts[0][:4]) { continue }
		name, address := parts[1], parts[2]
		if len(address) != 16 || !is_hex(address) {
			// (a name with spaces: the address is the first 16-digit word after it)
			at := -1
			for p, i in parts[2:] { if len(p) == 16 && is_hex(p) { at = i + 2; break } }
			if at < 0 { continue }
			name = strings.join(parts[1:at], " ", context.temp_allocator)
			address = parts[at]
		}
		va, good := strconv.parse_u64(address, 16)
		if !good || va < load_base { continue }
		append(&out, Map_Symbol{va - load_base, name})
	}
	slice.sort_by(out[:], proc(a, b: Map_Symbol) -> bool { return a.rva < b.rva })
	return out[:], stamp
}

// "pkg::[file.odin]::proc" -> "pkg.proc" and its file; "pkg::proc" -> "pkg.proc".
@(private = "file")
odin_symbol :: proc(s: string) -> (name, file: string) {
	i := strings.index(s, "::")
	if i <= 0 { return s, "" }
	rest := s[i + 2:]
	if strings.has_prefix(rest, "[") {
		if j := strings.index(rest, "]::"); j > 0 { return fmt.tprintf("%s.%s", s[:i], rest[j + 3:]), rest[1:j] }
	}
	return fmt.tprintf("%s.%s", s[:i], rest), ""
}

// The function that holds the offset `at` of the program's module ("": none known).
@(private = "file")
name_of :: proc(n: ^Name_Source, at: u64) -> string {
	if n.exe != "" { return addr2line(n.exe, n.load_vaddr + at) }
	lo, hi := 0, len(n.symbols)
	for lo < hi {
		mid := (lo + hi) / 2
		if n.symbols[mid].rva <= at { lo = mid + 1 } else { hi = mid }
	}
	if lo == 0 { return "" }
	s := n.symbols[lo - 1]
	name, file := odin_symbol(s.name)
	if file != "" { return fmt.tprintf("%s+0x%X (%s)", name, at - s.rva, file) }
	return fmt.tprintf("%s+0x%X", name, at - s.rva)
}

// "function (file:line)" from the executable's debug information, the innermost of what was inlined there.
@(private = "file")
addr2line :: proc(exe: string, address: u64) -> string {
	out, code := capture({system_program("addr2line"), "-f", "-C", "-e", exe, fmt.tprintf("0x%X", address)})
	if code != 0 { return "" }
	lines := strings.split_lines(strings.trim_space(out), context.temp_allocator)
	if len(lines) == 0 || lines[0] == "??" { return "" }
	if len(lines) >= 2 && !strings.has_prefix(lines[1], "??") { return fmt.tprintf("%s (%s)", lines[0], filepath.base(lines[1])) }
	return lines[0]
}
