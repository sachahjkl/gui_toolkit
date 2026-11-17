#+build !freestanding
package jsrt

// The runtime's block of cells, natively (src/md/js/README.md, Memory). The pool's chunks are taken one after the
// other from addresses reserved at engine_new and committed as they are reached: the chunk table then spans one
// block, whatever heap the embedder gives, and engine_free gives the block back in one call.
//
// The last CELL_BLOCK_SPARE_PART of the block is the spare. A chunk taken past the soft end before it, or a block the
// allocator refused, is served from the spare and raises the uncatchable "out of memory" at the next poll: the
// allocation itself cannot fail, since its caller writes the memory at once.

import vmem "core:mem/virtual"

// The addresses a runtime reserves when Host_Config.reserve_bytes is 0. Addresses cost nothing until committed; the
// heap's budget is malloc_limit, not this.
DEFAULT_RESERVE_BYTES :: 8 << 30 when size_of(uintptr) == 8 else 512 << 20
// The spare is this part of the block (an eighth).
CELL_BLOCK_SPARE_PART :: 8
// What one commit adds at least: a commit is a system call.
CELL_BLOCK_COMMIT_STEP :: 4 << 20

cell_block_open :: proc(rt: ^Runtime) {
	size := rt.config.reserve_bytes > 0 ? rt.config.reserve_bytes : DEFAULT_RESERVE_BYTES
	size = (size + CHUNK_UNIT - 1) &~ (CHUNK_UNIT - 1)
	data, err := vmem.reserve(uint(size))
	if err != nil || data == nil {return} // (the chunks then come from the allocator, as in Wasm)
	rt.block = {base = uintptr(raw_data(data)), reserved = size}
}

cell_block_close :: proc(rt: ^Runtime) {
	if rt.block.reserved > 0 {vmem.release(rawptr(rt.block.base), uint(rt.block.reserved))}
	rt.block = {}
}

// A pool chunk of `size` bytes (a multiple of CHUNK_UNIT), zeroed: nil when the whole block is spent.
cell_block_take :: proc(rt: ^Runtime, size: int) -> rawptr {
	b := &rt.block
	if b.used + size > b.reserved - b.reserved / CELL_BLOCK_SPARE_PART {memory_fail(rt)}
	return cell_block_bump(rt, size)
}

// A block from the spare for an allocation the allocator refused: the runtime is out of memory from now on.
cell_block_spare :: proc(rt: ^Runtime, size: int) -> rawptr {
	if rt.block.reserved == 0 {return nil}
	memory_fail(rt)
	return cell_block_bump(rt, (size + CHUNK_UNIT - 1) &~ (CHUNK_UNIT - 1))
}

@(private = "file")
cell_block_bump :: proc(rt: ^Runtime, size: int) -> rawptr {
	b := &rt.block
	if b.used + size > b.reserved {return nil}
	if b.used + size > b.committed {
		grow := max(b.used + size - b.committed, CELL_BLOCK_COMMIT_STEP)
		grow = min((grow + CHUNK_UNIT - 1) &~ (CHUNK_UNIT - 1), b.reserved - b.committed)
		if vmem.commit(rawptr(b.base + uintptr(b.committed)), uint(grow)) != nil {return nil}
		b.committed += grow
	}
	p := rawptr(b.base + uintptr(b.used)) // (fresh pages are zero, and a chunk of the block is never used twice)
	b.used += size
	return p
}

// The next poll raises the uncatchable "out of memory" (poll_interrupt): it comes at the next back edge or call.
@(private = "file")
memory_fail :: proc "contextless" (rt: ^Runtime) {
	rt.memory_failed = true
	rt.interrupt_counter = INTERRUPT_POLL_EVERY
}
