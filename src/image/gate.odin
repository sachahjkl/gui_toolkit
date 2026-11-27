package tk_image

// A byte budget that large decodes share: each acquires the bytes it will hold before it decodes, and gives them back
// after. A program with N decode threads (a cache's decoders, a viewer's, the chores) then never holds N large pictures
// at once: a 200-megapixel photo is 0.8 GB of RGBA, and four of them at once ended the process. A decode under
// GATE_FROM_BYTES passes freely: a thumbnail never waits behind a giant. One decode larger than the whole budget is
// admitted alone, when nothing else is held: it is not refused for ever (Decode_Options.max_bytes refuses it).
// src/md/features/image-decode.md, "The gate".

import "core:sync"

// The process's budget when nothing sets it: 1 GiB.
GATE_BUDGET_DEFAULT :: 1 << 30
// A decode that holds fewer bytes does not wait (4 MiB of RGBA and more: 1024 x 1024 and up).
GATE_FROM_BYTES :: 4 << 20

Decode_Gate :: struct {
	lock:    sync.Mutex,
	freed:   sync.Cond,
	budget:  int,   // 0: GATE_BUDGET_DEFAULT
	held:    int,   // the bytes acquired and not yet released
	waiting: int,   // decodes waiting for their bytes (a test sees them)
}

// (the process's: one budget whatever the number of caches and threads that decode; locked inside)
@(private = "file") gate_process: Decode_Gate

// The process's gate, which decode uses when its options name none.
decode_gate :: proc() -> ^Decode_Gate { return &gate_process }

// Sets a gate's budget in bytes (0: GATE_BUDGET_DEFAULT). Decodes that wait are looked at again.
gate_set_budget :: proc(g: ^Decode_Gate, bytes: int) {
	sync.lock(&g.lock)
	g.budget = max(bytes, 0)
	sync.cond_broadcast(&g.freed)
	sync.unlock(&g.lock)
}

// Waits until `bytes` fit in the gate's budget, then holds them. Under GATE_FROM_BYTES: at once, nothing held. A
// worker's call: it blocks.
gate_acquire :: proc(g: ^Decode_Gate, bytes: int) {
	if bytes < GATE_FROM_BYTES { return }
	sync.lock(&g.lock)
	defer sync.unlock(&g.lock)
	budget := g.budget > 0 ? g.budget : GATE_BUDGET_DEFAULT
	g.waiting += 1
	for g.held > 0 && g.held + bytes > budget {
		sync.cond_wait(&g.freed, &g.lock)
		budget = g.budget > 0 ? g.budget : GATE_BUDGET_DEFAULT
	}
	g.waiting -= 1
	g.held += bytes
}

// Gives back what gate_acquire held (the same `bytes`).
gate_release :: proc(g: ^Decode_Gate, bytes: int) {
	if bytes < GATE_FROM_BYTES { return }
	sync.lock(&g.lock)
	g.held -= bytes
	sync.cond_broadcast(&g.freed)
	sync.unlock(&g.lock)
}

// The bytes held and the decodes waiting (a test, a diagnostics page).
gate_counts :: proc(g: ^Decode_Gate) -> (held, waiting: int) {
	sync.lock(&g.lock)
	defer sync.unlock(&g.lock)
	return g.held, g.waiting
}
