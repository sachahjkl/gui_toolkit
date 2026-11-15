package tk_store

// Kept values: a number per id, beside a program's preferences (a session's zoom, a shell's, a pane's width per
// document). A value at its rest is not kept: forgotten, it follows that rest when the rest changes. They are read once
// from their Store into memory as numbers, so a frame that shows them reads no text. The Store is the program's: it
// opens and closes it; Kept only reads it at kept_load and writes through it.

import "core:fmt"
import "core:strconv"
import "core:strings"

Kept :: struct {
	file:   ^Store,
	values: map[string]f64,   // (keys owned)
	least:  f64,
	most:   f64,
}

// The numbers of `file`, each clamped to least..most (a line that is not a number is left out). `least` = `most` = 0:
// no clamp.
kept_load :: proc(k: ^Kept, file: ^Store, least: f64 = 0, most: f64 = 0) {
	kept_destroy(k)
	k.file, k.least, k.most = file, least, most
	for e in list(file) {
		v, ok := strconv.parse_f64(e.value)
		if !ok { continue }
		k.values[strings.clone(e.key)] = kept_clamp(k, v)
	}
}

// `id`'s value; `rest` when none is kept.
kept_of :: proc(k: ^Kept, id: string, rest: f64) -> f64 { return k.values[id] or_else rest }

// `id`'s value from now on: `rest` forgets it (it follows the rest again); another is kept and written.
kept_set :: proc(k: ^Kept, id: string, value, rest: f64) {
	if id == "" { return }
	v := kept_clamp(k, value)
	if v == rest {
		kept_forget(k, id)
		return
	}
	if id in k.values { k.values[id] = v } else { k.values[strings.clone(id)] = v }
	if k.file != nil { set(k.file, id, fmt.tprintf("%v", v)) }   // (%v: read back, the same number)
}

// `id` kept no longer (its subject is gone: a session deleted, a shell closed).
kept_forget :: proc(k: ^Kept, id: string) {
	if id not_in k.values { return }
	key, _ := delete_key(&k.values, id)
	delete(key)
	if k.file != nil { remove(k.file, id) }
}

// The memory of `k` (its Store is the program's to close).
kept_destroy :: proc(k: ^Kept) {
	for key in k.values { delete(key) }
	delete(k.values)
	k.values = nil
}

@(private = "file")
kept_clamp :: proc(k: ^Kept, v: f64) -> f64 {
	if k.least == 0 && k.most == 0 { return v }
	return clamp(v, k.least, k.most)
}
