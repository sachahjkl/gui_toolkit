# gt:js: a JavaScript engine

`gt:js` runs ECMAScript in a program. It is Wren's engine, in Odin: a front-end that compiles source text to
QuickJS-ng bytecode, an interpreter with a garbage collector, modules, Promises and async functions, regular
expressions, BigInt, typed arrays, SharedArrayBuffer and Atomics, and Date without Intl. It makes no system call: a
script reaches only what the program gives it.

```odin
import js "gt:js"
```

The package is `src/js` (package `jsrt`). Its sub-packages are libraries of their own: `gt:js/frontend` (the
compiler), `gt:js/regexp`, `gt:js/bigint`, `gt:js/numconv` (number to text and back), `gt:js/datetime` (package
`jsdate`) and `gt:js/unicode` (package `ucd`, the character database). The intent is in
[src/md/js/README.md](../src/md/js/README.md).

## A runtime

```odin
rt := js.engine_new(allocator)            // a Runtime; js.DEFAULT_CONFIG, or a Host_Config of your own
defer js.engine_free(rt)                  // frees every context, value and job of the runtime
ctx := js.context_new(rt)                 // a realm: its global object and its built-ins

js.set_global(ctx, "twice", js.new_function(ctx, twice, "twice", 1))
v := js.eval_source(ctx, source, "main.mjs", .module)   // a script: its completion value; a module: its promise
if js.is_exception(v) { e := js.pending_exception(ctx); ... }
if !js.run_jobs(rt) { e := js.pending_exception(ctx); ... }   // the Promise jobs, until none is left
```

A native function is a `js.Native_Proc`:

```odin
twice :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	n, ok := js.to_number(ctx, js.arg(args, 0))
	if !ok { return js.EXCEPTION }   // the exception is pending
	return js.new_number(2 * n)
}
```

The calls of `src/js/embed.odin`:

| Call | What it does |
|---|---|
| `engine_new(allocator, config)`, `engine_free(rt)` | A runtime and its end. |
| `context_new(rt)`, `context_free(ctx)` | A realm. `engine_free` frees the realms left. |
| `eval_source(ctx, source, filename, kind)` | Compiles and runs source text. `kind` is `.script` or `.module`. |
| `eval_bytecode(ctx, bytes)` | Runs serialized bytecode (`gt:js/frontend` makes it). |
| `run_jobs(rt)` | Runs the pending jobs. False: a job threw; `pending_exception` gives the error. |
| `call_function(ctx, f, this, args)` | Calls a JavaScript function. |
| `get_property_str`, `set_property_str`, `set_global`, `global_object` | Properties by name. |
| `new_number`, `new_bool`, `new_object`, `new_array`, `new_function` | Values made by the host. |
| `to_utf8(ctx, v, allocator)` | `ToString` of a value, as UTF-8 in the allocator given. |
| `retain(rt, v)`, `release(rt, v)` | Keeps a value past the next call into the engine. |
| `collect(rt)`, `heap_stats(rt)` | A collection now (between two calls only), and the heap's numbers. |

A value that the engine gives stays alive until the next call into the engine. To keep it longer, call `retain`, and
call `release` when it is no longer needed.

`Host_Config` holds the limits and the hooks of a runtime: `malloc_limit` (the heap's budget, an uncatchable "out of
memory" past it), `max_stack_depth`, `max_stack_bytes` (it must fit the stack of the thread that calls the engine),
`interrupt` (polled while a script runs: true stops it), `load_module` (the modules that a module imports),
`rejection`, `import_meta`, `dynamic_import`, `atomics_wait` and `atomics_notify` (agents on other threads).
`compile` is nil for the engine's own front-end.

The clock and the time zone are the program's: set `js.date_now_hook` (milliseconds since the epoch, for `Date`),
`js.clock_hook` (a monotonic clock for the collector's numbers) and `jsdate.timezone_offset_proc` from `gt:js/datetime`.
Without them, `Date.now()` is 0 and local time is UTC.

## Memory

`gt:js` chooses no allocator. The program gives one to `engine_new`, and every allocation of the runtime goes through
it, so a program's tracking allocator sees them all. `gt:js` never calls `runtime.heap_allocator()`.

Today, give a runtime one reserved block of addresses, for example a static `core:mem/virtual` arena. The
collector's table of chunks covers the addresses from its lowest chunk to its highest. On a native heap, the chunks are
far apart and the table does not fit. `tests/js` shows a block with a tracker above it. The ROADMAP puts this block in
`gt:js` itself, with a failed allocation as the engine's error.

## Threads

One runtime per process, for now. Some of the engine's state is in package globals: the interrupt word and its hook,
the hooks above, the JIT's state and the order of async modules. Two runtimes on two threads share them. Two runtimes
one after the other are correct. The ROADMAP moves this state into `Runtime`.

A runtime is used by one thread at a time.

## Wren

Wren builds the same packages for `freestanding_wasm32` and runs the engine in Wasmtime, with its web glue and its
Web IDL bindings. Wasmtime, the QuickJS C API (`jscapi`) and the engine's image stay in Wren. A program of the
toolkit runs `gt:js` natively.

## Tools and tests

- `tools/js_judge`: runs a script (`eval`), one test262 test (`test`) or the test262 suite (`test262`), natively.
  Link it with a 64 MiB main stack.
- `tools/js_parse_judge`: the front-end's judge.
- `tools/js_unicode_gen`: makes `src/js/unicode/tables_generated.odin` from the pinned Unicode Character Database.
- `odin run tools/run_tests -- js js_pkg js_regexp`: two runtimes embedded as a program embeds one, and the
  engine's unit tests.
