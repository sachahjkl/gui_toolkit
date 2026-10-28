package tk_testkit

import win "core:sys/windows"

foreign import kernel32_tk "system:Kernel32.lib"
foreign import user32_tk "system:User32.lib"

@(private = "file")
Heap_Summary :: struct {
	cb:                                           u32,
	allocated, committed, reserved, max_reserved: uint,
}

@(private = "file")
Basic_Info :: struct {
	base, alloc_base:     uintptr,
	alloc_protect:        u32,
	region_size:          uint,
	state, protect, kind: u32,
}

@(default_calling_convention = "system", private)
foreign kernel32_tk {
	tk_GetProcessHandleCount :: proc(process: win.HANDLE, count: ^u32) -> win.BOOL ---
	tk_GetProcessHeaps       :: proc(n: u32, heaps: [^]win.HANDLE) -> u32 ---
	tk_HeapSummary           :: proc(heap: win.HANDLE, flags: u32, s: ^Heap_Summary) -> win.BOOL ---
	tk_VirtualQuery          :: proc(address: uintptr, info: ^Basic_Info, length: uint) -> uint ---
}

@(default_calling_convention = "system", private)
foreign user32_tk {
	tk_GetGuiResources :: proc(process: win.HANDLE, flags: u32) -> u32 ---
}

@(private = "file") MEM_COMMIT  :: 0x1000
@(private = "file") MEM_PRIVATE :: 0x20000

@(private)
native_process_state :: proc() -> (s: Process_State) {
	h := win.GetCurrentProcess()
	pmc: win.PROCESS_MEMORY_COUNTERS_EX
	pmc.cb = size_of(pmc)
	if win.GetProcessMemoryInfo(h, (^win.PROCESS_MEMORY_COUNTERS)(&pmc), size_of(pmc)) {
		s.resident, s.private = i64(pmc.WorkingSetSize), i64(pmc.PrivateUsage)
	}
	n: u32
	if tk_GetProcessHandleCount(h, &n) { s.handles = i64(n) }
	s.gdi_objects = i64(tk_GetGuiResources(h, 0))    // GR_GDIOBJECTS
	s.user_objects = i64(tk_GetGuiResources(h, 1))   // GR_USEROBJECTS
	return
}

@(private)
native_memory_split :: proc() -> (m: Memory_Split) {
	heaps: [64]win.HANDLE
	n := min(int(tk_GetProcessHeaps(len(heaps), &heaps[0])), len(heaps))
	for i in 0 ..< n {
		s := Heap_Summary{cb = size_of(Heap_Summary)}
		if tk_HeapSummary(heaps[i], 0, &s) { m.heap_allocated += i64(s.allocated); m.heap_committed += i64(s.committed) }
	}
	mbi: Basic_Info
	addr: uintptr
	for tk_VirtualQuery(addr, &mbi, size_of(mbi)) != 0 {
		if mbi.state == MEM_COMMIT && mbi.kind == MEM_PRIVATE {
			if mbi.protect & 0xF0 != 0 { m.vm_exec += i64(mbi.region_size) } else { m.vm_rw += i64(mbi.region_size) }
		}
		next := mbi.base + uintptr(mbi.region_size)
		if next <= addr { break }
		addr = next
	}
	return
}
