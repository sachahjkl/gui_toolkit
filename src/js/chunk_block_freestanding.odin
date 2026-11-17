#+build freestanding
package jsrt

// In Wasm the linear memory already is one block, so the chunk table is small with no reserve, and a failed allocation
// is a trap that loses the instance: no block, no spare (chunk_block.odin is the native side).

DEFAULT_RESERVE_BYTES :: 0

cell_block_open :: proc(rt: ^Runtime) {}

cell_block_close :: proc(rt: ^Runtime) {}

cell_block_take :: proc(rt: ^Runtime, size: int) -> rawptr {return nil}

cell_block_spare :: proc(rt: ^Runtime, size: int) -> rawptr {return nil}
