package tk_toolbox

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import crash "../crash"

@(private = "file") FAKE_BUILD :: "5F00000012345"
@(private = "file") FAKE_BASE :: u64(0x7FF600000000)
@(private = "file") FAKE_MAP :: ` x

 Timestamp is 5f000000 (Thu Jul 02 2020)

 Preferred load address is 0000000140000000

  Address         Publics by Value              Rva+Base               Lib:Object

 0000:00000000       __guard_flags              0000000000000100     <absolute>
 0001:00000000       runtime::bounds_trap       0000000140001000 f   a.obj
 0001:00000100       page::[dom.odin]::walk     0000000140001100 f   a.obj
`

@(private = "file")
crash_folder :: proc(t: ^testing.T, name: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, fmt.tprintf("tk_toolbox_crash_%s_%d", name, os.get_pid())}, context.temp_allocator)
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil, dir)
	return dir
}

// The headers a PE file starts with: its link stamp 0x5F000000 and its image size 0x12345.
@(private = "file")
fake_pe :: proc() -> []u8 {
	b := make([]u8, 0x100, context.temp_allocator)
	b[0], b[1] = 'M', 'Z'
	endian.put_u32(b[0x3C:], .Little, 0x40)
	copy(b[0x40:], "PE\x00\x00")
	endian.put_u32(b[0x48:], .Little, 0x5F000000)
	endian.put_u32(b[0x40 + 80:], .Little, 0x12345)
	return b
}

// A 64-bit ELF file with a load segment at 0 and a GNU build id note "deadbeef".
@(private = "file")
fake_elf :: proc() -> []u8 {
	b := make([]u8, 0xC4, context.temp_allocator)
	copy(b, "\x7fELF")
	b[4], b[5] = 2, 1
	endian.put_u64(b[0x20:], .Little, 0x40)
	endian.put_u16(b[0x36:], .Little, 56)
	endian.put_u16(b[0x38:], .Little, 2)
	endian.put_u32(b[0x40:], .Little, 1)          // PT_LOAD, vaddr 0
	endian.put_u32(b[0x78:], .Little, 4)          // PT_NOTE
	endian.put_u64(b[0x78 + 8:], .Little, 0xB0)
	endian.put_u64(b[0x78 + 32:], .Little, 20)
	endian.put_u32(b[0xB0:], .Little, 4)
	endian.put_u32(b[0xB4:], .Little, 4)
	endian.put_u32(b[0xB8:], .Little, 3)          // NT_GNU_BUILD_ID
	copy(b[0xBC:], "GNU\x00\xde\xad\xbe\xef")
	return b
}

@(test)
a_build_is_named_by_its_file :: proc(t: ^testing.T) {
	dir := crash_folder(t, "build_id")
	defer os.remove_all(dir)
	pe, elf, other := fmt.tprintf("%s/x.exe", dir), fmt.tprintf("%s/x", dir), fmt.tprintf("%s/x.txt", dir)
	_ = os.write_entire_file(pe, fake_pe())
	_ = os.write_entire_file(elf, fake_elf())
	_ = os.write_entire_file(other, "not a program")
	id, ok := crash_build_id(pe)
	testing.expect(t, ok)
	testing.expect_value(t, id, FAKE_BUILD)
	id, ok = crash_build_id(elf)
	testing.expect(t, ok)
	testing.expect_value(t, id, "deadbeef")
	_, ok = crash_build_id(other)
	testing.expect(t, !ok)
}

// A Windows release's report, named from its map after the link renamed it by the build: the program's frames (a return address
// one byte back), not the system's.
@(test)
a_report_is_named_from_the_map :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := crash_folder(t, "symbolize")
	defer os.remove_all(dir)
	exe := fmt.tprintf("%s/x.exe", dir)
	_ = os.write_entire_file(exe, fake_pe())
	_ = os.write_entire_file(fmt.tprintf("%s/x.map", dir), FAKE_MAP)
	_ = os.write_entire_file(fmt.tprintf("%s/x-0000000012.map", dir), "an older link's")
	named, why := crash_publish_symbols(exe)
	testing.expect_value(t, why, "")
	testing.expect_value(t, filepath.base(named), "x-" + FAKE_BUILD + ".map")
	testing.expect(t, !os.exists(fmt.tprintf("%s/x.map", dir)) && !os.exists(fmt.tprintf("%s/x-0000000012.map", dir)), "the map renamed, the older one gone")

	r := crash.Report{program = "x", build = FAKE_BUILD, kind = crash.KIND_EXCEPTION, complete = true}
	frames := make([dynamic]crash.Frame)
	append(&frames, crash.Frame{FAKE_BASE + 0x1010, "x.exe", 0x1010, ""}, crash.Frame{FAKE_BASE + 0x1104, "x.exe", 0x1104, ""}, crash.Frame{0x7FFA00000010, "kernel32.dll", 0x10, ""})
	append(&r.threads, crash.Thread{id = 1, crashed = true, frames = frames})
	append(&r.modules, crash.Module{FAKE_BASE, 0x12345, "x.exe", `C:\x\x.exe`}, crash.Module{0x7FFA00000000, 0x1000, "kernel32.dll", `C:\Windows\System32\kernel32.dll`})
	report := fmt.tprintf("%s/crash-20261113-170300-1.txt", dir)
	_ = os.write_entire_file(report, crash.report_text(r))

	for symbols in ([2]string{named, dir}) {
		text, swhy := crash_symbolize(report, symbols)
		testing.expect_value(t, swhy, "")
		got, ok := crash.report_parse(text)
		testing.expect(t, ok, text)
		if !testing.expect(t, len(got.threads) == 1 && len(got.threads[0].frames) == 3, text) { continue }
		testing.expect_value(t, got.threads[0].frames[0].symbol, "runtime.bounds_trap+0x10")
		testing.expect_value(t, got.threads[0].frames[1].symbol, "page.walk+0x3 (dom.odin)")
		testing.expect_value(t, got.threads[0].frames[2].symbol, "")
		testing.expect(t, len(got.extra) >= 1 && got.extra[0].key == "symbols", "it says from what")
	}

	_, why = crash_symbolize(report, fmt.tprintf("%s/none", dir))
	testing.expect(t, why != "", "no symbols: why")
	elf := fmt.tprintf("%s/x-elf", dir)
	_ = os.write_entire_file(elf, fake_elf())
	_, why = crash_symbolize(report, elf)
	testing.expect(t, why != "", "an executable of another build is refused")
}
