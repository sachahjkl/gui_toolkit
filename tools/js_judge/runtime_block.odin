package jsrt_judge

import "core:mem"
import vmem "core:mem/virtual"
import "core:sync"
import js "../../src/js"

// Each runtime of the judge in a reserved block of its own. A runtime's chunk table spans the addresses from its lowest
// chunk to its highest; on the process heap the chunks can be far apart (it depends on the C library and the address
// layout: the suite failed whole in one shell and passed in another), and the table then does not fit
// (src/md/features/plugins.md, Measures). In one block the span is the block's. The block frees nothing one by one; it
// goes whole with the runtime (judge_engine_free). ROADMAP: the engine reserves its own block, and this goes.

@(private = "file") BLOCK_RESERVE :: 4 << 30

@(private = "file") blocks_lock: sync.Mutex
@(private = "file") blocks: map[^js.Runtime]^vmem.Arena   // (agents make runtimes on threads of their own)

@(private = "file")
block_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	if mode == .Free || mode == .Free_All { return nil, nil }
	return vmem.arena_allocator_proc(data, mode, size, alignment, old_memory, old_size, loc)
}

judge_engine_new :: proc(cfg: js.Host_Config) -> ^js.Runtime {
	block := new(vmem.Arena)
	if vmem.arena_init_static(block, BLOCK_RESERVE) != nil { panic("judge: a runtime's block cannot be reserved") }
	rt := js.engine_new(mem.Allocator{block_proc, block}, cfg)
	sync.mutex_guard(&blocks_lock)
	blocks[rt] = block
	return rt
}

judge_engine_free :: proc(rt: ^js.Runtime) {
	js.engine_free(rt)
	block: ^vmem.Arena
	{
		sync.mutex_guard(&blocks_lock)
		block = blocks[rt]
		delete_key(&blocks, rt)
	}
	if block != nil {
		vmem.arena_destroy(block)
		free(block)
	}
}
