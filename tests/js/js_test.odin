// gt:js embedded as a program embeds it (docs/js.md): a runtime, a module that awaits, regular expressions, Atomics on a
// SharedArrayBuffer, a native function, a call from the host, a collection, the runtime freed with nothing left.
// Two runtimes one after the other by default. The two-thread variant (-define:JS_TWO_THREADS=true) is the test that
// breaks the engine's package globals (src/md/js/README.md): it stays off until they move into Runtime (ROADMAP.md).
package js_test

import "core:mem"
import vmem "core:mem/virtual"
import "core:testing"
import "core:thread"
import "core:time"
import js "gt:js"

JS_TWO_THREADS :: #config(JS_TWO_THREADS, false)

// The rounds of the script's loops: a few awaits, matches and atomic adds, under a second for both runtimes.
ROUNDS :: 50
// What the script says with ROUNDS 50: the matches' numbers summed (4i + 4 for each round), twice the atomic count, and
// the host's argument to finish.
EXPECTED :: "5100:100:7"
HOST_ARGUMENT :: 7
// The addresses a runtime may use (reserved, committed as it grows: a small script commits a few MiB).
BLOCK_RESERVE :: 1 << 30
// The bound of the two-thread variant's wait, and how often it looks.
THREADS_LIMIT :: 30 * time.Second
THREADS_POLL :: 5 * time.Millisecond
RESULT_CAP :: 128

SCRIPT :: `
const re = /(\d+)-(\d+)/g;
try {
	let sum = 0;
	for (let i = 0; i < ROUNDS; i++) {
		await null;
		for (const m of ` + "`${i}-${i + 1} x ${i * 2}-3`" + `.matchAll(re)) sum += Number(m[1]) + Number(m[2]);
	}
	const counts = new Int32Array(new SharedArrayBuffer(8));
	for (let i = 0; i < ROUNDS; i++) Atomics.add(counts, 0, 1);
	globalThis.finish = (k) => ` + "`${sum}:${twice(Atomics.load(counts, 0))}:${k}`" + `;
} catch (e) {
	globalThis.failure = String(e);
}
`

Outcome :: struct {
	result:     [RESULT_CAP]u8,
	result_len: int,
	failure:    string,   // a literal: the step that went wrong; "" when the runtime ran to its end
	leaked:     int,      // the engine's allocations left after engine_free
	bad_frees:  int,
}

outcome_text :: proc(o: ^Outcome) -> string { return string(o.result[:o.result_len]) }

// The runtime's memory: one reserved block. A runtime's chunk table spans the addresses from its lowest chunk to its
// highest, which a native heap makes too wide (src/md/features/plugins.md, Measures); in one block it is small. The
// arena frees nothing one by one, so a free is accepted here and counted by the tracker above it. A free of everything
// is refused as a no-op: the engine's allocator is a heap, and the block goes whole at the end.
block_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	if mode == .Free || mode == .Free_All { return nil, nil }
	return vmem.arena_allocator_proc(data, mode, size, alignment, old_memory, old_size, loc)
}

twice :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	n, ok := js.to_number(ctx, js.arg(args, 0))
	if !ok { return js.EXCEPTION }
	return js.new_number(2 * n)
}

// One runtime from engine_new to engine_free. It calls no testing procedure: a thread of the two-thread variant runs it.
run_runtime :: proc(o: ^Outcome) {
	block: vmem.Arena
	if vmem.arena_init_static(&block, BLOCK_RESERVE) != nil { o.failure = "the block is not reserved"; return }
	defer vmem.arena_destroy(&block)
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, mem.Allocator{block_proc, &block})
	defer mem.tracking_allocator_destroy(&tracker)
	// (counted, not a panic: a thread of the two-thread variant reports through its Outcome; and a free of
	// everything does not hide a leak)
	tracker.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	tracker.clear_on_free_all = false

	rt := js.engine_new(mem.tracking_allocator(&tracker))
	ctx := js.context_new(rt)
	js.set_global(ctx, "twice", js.new_function(ctx, twice, "twice", 1))
	js.set_global(ctx, "ROUNDS", js.new_number(ROUNDS))
	o.failure = evaluate(ctx, o)
	js.collect(rt)
	js.engine_free(rt)
	o.leaked = len(tracker.allocation_map)
	o.bad_frees = len(tracker.bad_free_array)
}

@(private = "file")
evaluate :: proc(ctx: ^js.Context, o: ^Outcome) -> string {
	rt := ctx.rt
	if js.is_exception(js.eval_source(ctx, SCRIPT, "day_one.mjs", .module)) {
		keep_text(ctx, o, js.pending_exception(ctx))
		return "the module does not compile or its first step threw"
	}
	if !js.run_jobs(rt) {
		keep_text(ctx, o, js.pending_exception(ctx))
		return "a job threw"
	}
	global := js.global_object(ctx)
	if failure := js.get_property_str(ctx, global, "failure"); !js.is_undefined(failure) {
		keep_text(ctx, o, failure)
		return "the module caught an error"
	}
	finish := js.get_property_str(ctx, global, "finish")
	if js.is_undefined(finish) { return "the module did not reach its end" }
	r := js.call_function(ctx, finish, js.UNDEFINED, {js.new_number(HOST_ARGUMENT)})
	if js.is_exception(r) {
		keep_text(ctx, o, js.pending_exception(ctx))
		return "finish threw"
	}
	keep_text(ctx, o, r)
	return ""
}

@(private = "file")
keep_text :: proc(ctx: ^js.Context, o: ^Outcome, v: js.Value) {
	s, _ := js.to_utf8(ctx, v, context.allocator)
	defer delete(s)
	o.result_len = copy(o.result[:], s)
}

expect_outcome :: proc(t: ^testing.T, o: ^Outcome, which: string, loc := #caller_location) {
	testing.expectf(t, o.failure == "", "%s: %s (%s)", which, o.failure, outcome_text(o), loc = loc)
	testing.expectf(t, o.failure != "" || outcome_text(o) == EXPECTED, "%s: '%s', not '%s'", which, outcome_text(o), EXPECTED, loc = loc)
	testing.expectf(t, o.leaked == 0, "%s: %d allocations of the engine left after engine_free", which, o.leaked, loc = loc)
	testing.expectf(t, o.bad_frees == 0, "%s: %d frees of memory the engine did not allocate", which, o.bad_frees, loc = loc)
}

@(test)
two_runtimes_one_after_the_other :: proc(t: ^testing.T) {
	first, second: Outcome
	run_runtime(&first)
	expect_outcome(t, &first, "the first runtime")
	run_runtime(&second)
	expect_outcome(t, &second, "the second runtime")
}

// Each runtime on a thread of its own, at the same time. With the engine's per-runtime state in package globals (poll
// word, hooks, JIT state, module counter), two runtimes share it and this fails.
run_two_threads :: proc(t: ^testing.T) {
	outcomes: [2]Outcome
	workers: [2]^thread.Thread
	for &w, i in workers {
		w = thread.create_and_start_with_poly_data(&outcomes[i], run_runtime, context)
	}
	began := time.tick_now()
	for !(thread.is_done(workers[0]) && thread.is_done(workers[1])) && time.tick_since(began) < THREADS_LIMIT {
		time.sleep(THREADS_POLL)
	}
	if !testing.expectf(t, thread.is_done(workers[0]) && thread.is_done(workers[1]), "the two runtimes did not end within %v", THREADS_LIMIT) {
		return   // (a thread that hangs is not joined: the run's limit ends the process)
	}
	for w in workers { thread.join(w); thread.destroy(w) }
	expect_outcome(t, &outcomes[0], "the runtime of thread 1")
	expect_outcome(t, &outcomes[1], "the runtime of thread 2")
}

when JS_TWO_THREADS {
	@(test)
	two_runtimes_on_two_threads :: proc(t: ^testing.T) { run_two_threads(t) }
}
