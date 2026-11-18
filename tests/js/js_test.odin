// gt:js embedded as a program embeds it (docs/js.md): a runtime, a module that awaits, regular expressions, Atomics on a
// SharedArrayBuffer, a native function, a call from the host, a collection, the runtime freed with nothing left.
// Two runtimes one after the other, and two at once on two threads: the test that breaks the engine as soon as one
// runtime's state is a package global (src/md/js/README.md). Each runtime has its own allocator, clock, time zone and
// poll hook, and checks that its script sees its own.
package js_test

import "base:intrinsics"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import js "gt:js"

// The rounds of the script's loops: a few awaits, matches and atomic adds, under a second for both runtimes.
ROUNDS :: 50
// The back edges of the script's last loop: past INTERRUPT_POLL_EVERY (10 000), so that the interrupt checks look at
// the runtime's poll word a few times.
SPIN :: 50_000
// What the script says with ROUNDS 50: the matches' numbers summed (4i + 4 for each round), twice the atomic count, the
// host's argument to finish, then the runtime's own Date.now(), getTimezoneOffset() and getHours() of the epoch.
EXPECTED :: [2]string{"5100:100:7:1000000:60:23", "5100:100:7:2000000:-120:2"}
HOST_ARGUMENT :: 7
// The two runtimes' clocks and time zones (minutes west of UTC: the epoch is 23 h on the first, 2 h on the second).
FIRST_NOW :: 1_000_000
SECOND_NOW :: 2_000_000
FIRST_TZ :: 60
SECOND_TZ :: -120
// What the lazy object's members define.
LAZY_VALUE :: 11
// The addresses a runtime may use (reserved, committed as it grows: a small script commits a few MiB).
BLOCK_RESERVE :: 1 << 30
// The bound of the two-thread wait, and how often it looks.
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
	let spin = 0;
	for (let i = 0; i < SPIN; i++) spin += i & 1;
	if (spin !== SPIN / 2) throw new Error("spin " + spin);
	if (lazy.made !== LAZY_VALUE) throw new Error("lazy.made " + lazy.made);
	const epoch = new Date(0);
	globalThis.finish = (k) => ` + "`${sum}:${twice(Atomics.load(counts, 0))}:${k}:${Date.now()}:${epoch.getTimezoneOffset()}:${epoch.getHours()}`" + `;
} catch (e) {
	globalThis.failure = String(e);
}
`

// How often each runtime's poll hook ran. Only the first runtime's word is raised: the second's hook never runs unless
// the two runtimes share a word or a hook.
@(private = "file")
polls: [2]int

Outcome :: struct {
	which:      int,             // 0: the first runtime's hooks, 1: the second's
	start:      ^sync.Barrier,   // the two-thread variant: both runtimes begin at once
	result:     [RESULT_CAP]u8,
	result_len: int,
	failure:    string,   // a literal: the step that went wrong; "" when the runtime ran to its end
	leaked:     int,      // the engine's allocations left after engine_free
	bad_frees:  int,
	async_order: i64,     // the runtime's module_async_counter at its end: one module with await
	// shape_realize, a contextless entry point, ran the lazy members under the runtime's allocator, and the tracker
	// saw what they allocated
	tracker:         ^mem.Tracking_Allocator,
	lazy_ran:        bool,
	lazy_context_ok: bool,
	lazy_allocated:  bool,
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

// The members of the global `lazy`, made at the script's first read (shape_realize, contextless). The context there
// must be the one engine_new saved, with the runtime's allocator: not the process's default, nor the test's.
lazy_members :: proc(ctx: ^js.Context, obj: ^js.Object, p: rawptr, user: i32) {
	o := cast(^Outcome)p
	o.lazy_ran = true
	a := context.allocator
	o.lazy_context_ok = a.procedure == mem.tracking_allocator_proc && a.data == o.tracker
	before := o.tracker.total_allocation_count
	scratch := make([]u8, 64)
	o.lazy_allocated = o.tracker.total_allocation_count > before
	delete(scratch)
	js.set_property_str(ctx, js.mk_obj(obj), "made", js.new_number(LAZY_VALUE))
}

// Each runtime's own hooks: two procedures each, since a hook has no user data.
config_of :: proc(which: int) -> js.Host_Config {
	cfg := js.DEFAULT_CONFIG
	if which == 0 {
		cfg.date_now_hook = proc() -> f64 { return FIRST_NOW }
		cfg.timezone_offset_proc = proc "contextless" (t: i64) -> int { return FIRST_TZ }
		cfg.poll_hook = proc "contextless" () { intrinsics.atomic_add(&polls[0], 1) }
	} else {
		cfg.date_now_hook = proc() -> f64 { return SECOND_NOW }
		cfg.timezone_offset_proc = proc "contextless" (t: i64) -> int { return SECOND_TZ }
		cfg.poll_hook = proc "contextless" () { intrinsics.atomic_add(&polls[1], 1) }
	}
	return cfg
}

// One runtime from engine_new to engine_free. It calls no testing procedure: a thread of the two-thread variant runs it.
run_runtime :: proc(o: ^Outcome) {
	// (first, before anything can fail: a thread that left early would leave the other waiting)
	if o.start != nil { sync.barrier_wait(o.start) }
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
	o.tracker = &tracker

	rt := js.engine_new(mem.tracking_allocator(&tracker), config_of(o.which))
	// (raised for the whole run and never lowered: the hook runs at each of the runtime's polls)
	if o.which == 0 { rt.poll_word = 1 }
	ctx := js.context_new(rt)
	js.set_global(ctx, "twice", js.new_function(ctx, twice, "twice", 1))
	js.set_global(ctx, "ROUNDS", js.new_number(ROUNDS))
	js.set_global(ctx, "SPIN", js.new_number(SPIN))
	js.set_global(ctx, "LAZY_VALUE", js.new_number(LAZY_VALUE))
	lazy := js.new_object(ctx)
	js.object_set_lazy(ctx, js.as_obj(lazy), lazy_members, o, 0)
	js.set_global(ctx, "lazy", lazy)
	o.failure = evaluate(ctx, o)
	o.async_order = rt.module_async_counter
	js.collect(rt)
	js.engine_free(rt)
	o.tracker = nil
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
	expected := EXPECTED
	testing.expectf(t, o.failure == "", "%s: %s (%s)", which, o.failure, outcome_text(o), loc = loc)
	testing.expectf(t, o.failure != "" || outcome_text(o) == expected[o.which], "%s: '%s', not '%s'", which, outcome_text(o), expected[o.which], loc = loc)
	testing.expectf(t, o.leaked == 0, "%s: %d allocations of the engine left after engine_free", which, o.leaked, loc = loc)
	testing.expectf(t, o.bad_frees == 0, "%s: %d frees of memory the engine did not allocate", which, o.bad_frees, loc = loc)
	testing.expectf(t, o.async_order == 1, "%s: its async modules' order is %d, not 1: another runtime's evaluation moved it", which, o.async_order, loc = loc)
	testing.expectf(t, o.lazy_ran, "%s: the lazy members were not made", which, loc = loc)
	testing.expectf(t, o.lazy_context_ok, "%s: shape_realize ran the lazy members under another allocator than the runtime's", which, loc = loc)
	testing.expectf(t, o.lazy_allocated, "%s: the runtime's tracker did not see the lazy members' allocation", which, loc = loc)
}

// Only the first runtime's word is raised, so its hook ran and the second's never did.
expect_polls :: proc(t: ^testing.T, loc := #caller_location) {
	testing.expectf(t, intrinsics.atomic_load(&polls[0]) > 0, "the first runtime's poll hook never ran: its poll word was not looked at", loc = loc)
	testing.expectf(t, intrinsics.atomic_load(&polls[1]) == 0, "the second runtime's poll hook ran %d times: its word or its hook is the other's", intrinsics.atomic_load(&polls[1]), loc = loc)
}

@(test)
two_runtimes_one_after_the_other :: proc(t: ^testing.T) {
	first, second: Outcome
	first.which, second.which = 0, 1
	run_runtime(&first)
	expect_outcome(t, &first, "the first runtime")
	run_runtime(&second)
	expect_outcome(t, &second, "the second runtime")
	expect_polls(t)
}

// A script that grows forever: the heap's budget (malloc_limit) or the end of the block's reserve stops it with an
// "out of memory" error, and the process goes on. On the process heap first (the chunk table aborted there before the
// block), then on a static arena, then with no budget at all, where only the reserve's soft end stops it: a chunk from
// the spare and the uncatchable error, not a panic. Under a budget the error may be the catchable RangeError of a large
// block refused before it is allocated (mem_may_grow), so the script there has no try; with no budget it has one, which
// must not see the error.
GROW_SCRIPT :: `
const a = [];
for (;;) a.push({ n: a.length });
`
GROW_SCRIPT_CAUGHT :: `
const a = [];
try { for (;;) a.push({ n: a.length }); } catch (e) { globalThis.caught = String(e); }
`
GROW_LIMIT :: 16 << 20
GROW_RESERVE :: 64 << 20

@(test)
past_the_memory_limit :: proc(t: ^testing.T) {
	Case :: struct {name: string, arena: bool, limit: i64}
	cases := [?]Case{{"the process heap", false, GROW_LIMIT}, {"a static arena", true, GROW_LIMIT}, {"no budget", false, -1}}
	for c in cases {
		block: vmem.Arena
		allocator := context.allocator
		if c.arena {
			if !testing.expectf(t, vmem.arena_init_static(&block, BLOCK_RESERVE) == nil, "%s: the arena is not reserved", c.name) { continue }
			allocator = mem.Allocator{block_proc, &block}
		}
		cfg := js.DEFAULT_CONFIG
		cfg.malloc_limit = c.limit
		cfg.reserve_bytes = GROW_RESERVE
		rt := js.engine_new(allocator, cfg)
		ctx := js.context_new(rt)
		r := js.eval_source(ctx, c.limit < 0 ? GROW_SCRIPT_CAUGHT : GROW_SCRIPT, "grow.js")
		testing.expectf(t, js.is_exception(r), "%s: the script ended without an error", c.name)
		text, _ := js.to_utf8(ctx, js.pending_exception(ctx), context.allocator)
		testing.expectf(t, strings.has_suffix(text, "out of memory"), "%s: the error is '%s', not out of memory", c.name, text)
		delete(text)
		caught := js.get_property_str(ctx, js.global_object(ctx), "caught")
		testing.expectf(t, js.is_undefined(caught), "%s: the script caught the out of memory error", c.name)
		js.engine_free(rt)
		if c.arena { vmem.arena_destroy(&block) }
	}
}

// reserve_bytes below 0: no block of the runtime's own, the cells' chunks come from the program's allocator (an
// embedder whose values hold 32-bit pointers keeps every cell in its own low range). With a block, the arena would
// see none of them.
@(test)
no_block_takes_the_chunks_from_the_allocator :: proc(t: ^testing.T) {
	block: vmem.Arena
	if !testing.expect(t, vmem.arena_init_static(&block, BLOCK_RESERVE) == nil, "the arena is not reserved") { return }
	defer vmem.arena_destroy(&block)
	cfg := js.DEFAULT_CONFIG
	cfg.reserve_bytes = -1
	rt := js.engine_new(mem.Allocator{block_proc, &block}, cfg)
	ctx := js.context_new(rt)
	before := block.total_used
	// (a chain of small objects: cells alone, no block above 512 bytes that the allocator would get anyway)
	r := js.eval_source(ctx, "var head = null; for (let i = 0; i < 20000; i++) head = {next: head}; 1", "cells.js")
	testing.expect(t, !js.is_exception(r), "the script ran")
	testing.expect_value(t, rt.block.reserved, 0)
	testing.expectf(t, block.total_used - before >= NO_BLOCK_CELLS_BYTES, "the cells' chunks are not the allocator's (%d bytes)", block.total_used - before)
	js.engine_free(rt)
}

// 20000 objects of one property each take more than this in cells (about 3 MiB; with a block, the allocator gets
// about 300 KiB, its big blocks alone).
@(private = "file") NO_BLOCK_CELLS_BYTES :: 1 << 20

// Each runtime on a thread of its own, at the same time (a barrier starts them together), each with its own allocator
// and hooks.
@(test)
two_runtimes_on_two_threads :: proc(t: ^testing.T) {
	start: sync.Barrier
	sync.barrier_init(&start, 2)
	outcomes: [2]Outcome
	workers: [2]^thread.Thread
	for &w, i in workers {
		outcomes[i].which = i
		outcomes[i].start = &start
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
	expect_polls(t)
}
