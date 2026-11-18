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

The clock and the time zone are the program's, one runtime's each. Set them in the `Host_Config` given to
`engine_new`, or later in `rt.config`:

| Field | What it is | Without it |
|---|---|---|
| `date_now_hook` | Milliseconds since the epoch, for `Date`. | `Date.now()` is 0. |
| `timezone_offset_proc` | The minutes of local time west of UTC at an instant (`getTimezoneOffset`). | Local time is UTC. |
| `clock_hook` | A monotonic clock in nanoseconds, for the collector's numbers. | They are 0. |
| `poll_hook` | Called at a safe point while `rt.poll_word` is not 0: a timer of the program raises the word, the hook takes the thread. | The word is not looked at. |
| `span_hook` | The engine's stages (compile, collection, bytecode read, JIT), for the program's measures. | Nothing is said. |
| `stack_move_hook`, `native_stack_low_hook` | The stack moved to a block of the heap, and the machine's stack nearly out (Wren's Wasm host). Set both or neither. | A recursion ends at `max_stack_bytes`. |
| `auto_init_getter` | The C API's properties made at their first read (Wren's `jscapi`). | None. |

The loop JIT runs only in Wren's Wasm host: `jit_configure(rt, ...)` turns it on, `rt.jit_cfg` holds its other
settings, `jit_stat(rt, which)` reads its counters.

A contextless entry point of the engine (the members of a lazy object, `shape_realize`) runs under the context of
`engine_new`'s caller, with the runtime's allocator: what it allocates goes through that allocator too.

## Memory

`gt:js` chooses no allocator. The program gives one to `engine_new`, and every allocation of the runtime goes through
it, so a program's tracking allocator sees them all. `gt:js` never calls `runtime.heap_allocator()`.

Natively, a runtime reserves one block of addresses for its cells at `engine_new` (`Host_Config.reserve_bytes`; 0:
`DEFAULT_RESERVE_BYTES`, 8 GiB) and commits it as it grows. The collector's table of chunks covers the addresses from
the lowest chunk to the highest, so the chunks must be near each other: in the block they are, whatever allocator the
program gives. A block larger than 512 bytes (the values of an array, a long string) still comes from the allocator.
`engine_free` releases the block in one call. In Wasm no block is reserved: the linear memory is one already. A
`reserve_bytes` below 0 reserves no block natively either: the chunks then come from the allocator, for a program whose
allocator must keep every cell in a range of its own (a value that holds a 32-bit pointer).

The heap's budget is `malloc_limit`. Past it, the script gets the uncatchable "out of memory" error at its next safe
point. The last eighth of the block is a spare: when the allocator refuses a block, or a chunk goes past the block's
soft end, the allocation is served from the spare and the next poll raises the same error. The process ends only when
the spare is spent too.

## Threads

Several runtimes run at once, each on its own thread. A runtime's state is in its `Runtime`: the poll word, the hooks
above, the JIT's state, the order of async modules. The engine's package globals are constant tables, and the lock of
`Atomics` on a `SharedArrayBuffer`, which agents on several threads share.

A runtime is used by one thread at a time. It can move to another thread between two calls.

## The libraries

Each sub-package works alone. Each makes no system call and builds for `freestanding_wasm32` too.

```odin
import rx "gt:js/regexp"
re, err := rx.compile(pattern, rx.parse_flags("giu"), allocator)   // err.message, err.pos
defer rx.destroy(&re)
caps: rx.Captures
st := rx.exec_search(&re, rx.input_utf8_string(text), 0, &caps, limits, allocator)   // .Match, .No_Match, .Out_Of_Steps, .Stack_Overflow
```

- `gt:js/regexp`: ECMAScript regular expressions, flags `d g i m s u v y`. Input is UTF-16 (`input_utf16`, offsets in
  UTF-16 units) or UTF-8 (`input_utf8`, `input_utf8_string`, offsets in bytes). `exec` tries one start, `exec_search`
  scans from `start` (the `y` flag forbids it to advance). `named_group_index` finds a named group. `Exec_Limits` bounds a
  run; `limits_from_prefs` reads the preferences `regexp.exec.max_steps` and `regexp.exec.max_stack`.
- `gt:js/unicode` (package `ucd`): `Char_Range` interval sets (`cr_init`, `general_category`, `cr_op_inplace`,
  `cr_invert`, `cr_contains`), `simple_case`, `full_case`, `canonicalize`, the identifier and white space predicates,
  and `normalize` (NFC, NFD, NFKC, NFKD).
- `gt:js/bigint`: `from_i64`, `from_u64`, `from_f64`, `from_string` (bases 2–36) and back; `add`, `sub`, `mul`, `div`,
  `rem`, `divmod`, `pow`, `shl`, `shr`, the bitwise operations, `as_intn`, `as_uintn`, `cmp`. Each result is allocated in
  `context.allocator`: free it with `destroy`. Division by zero returns zero: check it first.
- `gt:js/numconv`: `f64_to_shortest`, `f64_to_radix`, `f64_to_fixed`, `f64_to_exponential`, `f64_to_precision` into a
  buffer of `MAX_STR_LEN` bytes; `parse_number`, `parse_float`, `parse_int`. The bytes are QuickJS's.
- `gt:js/datetime` (package `jsdate`): `get_date_fields`, `set_date_fields`, `format_date` (`.ISO`, `.UTC`, `.ToString`,
  `.Locale`) and `parse`, on `f64` milliseconds since the epoch. The procedures that read local time take the time
  zone, a `Timezone_Offset`, as their last argument; nil is UTC.

## Wren

Wren builds the same packages for `freestanding_wasm32` and runs the engine in Wasmtime, with its web glue and its
Web IDL bindings. Wasmtime, the QuickJS C API (`jscapi`) and the engine's image stay in Wren. A program of the
toolkit runs `gt:js` natively.

## Tools and tests

- `tools/js_judge`: runs a script (`eval`), one test262 test (`test`) or the test262 suite (`test262`), natively.
  Link it with a 64 MiB main stack.
- `odin run tools/tk -- js_test262 [-filter:text] [-stride:k] [-jobs:n]`: fetches the pinned suite and QuickJS-ng's
  `test262.conf` into `build/test262/run`, builds the judge with its stack, and runs the suite in worker processes (a
  crash or a hang costs one test). The failures are in `build/test262/jsrt_errors.txt`, the table by directory in
  `jsrt_table.md`. Every directory passes all that QuickJS-ng passes; the tests that fail are the ones QuickJS-ng fails too.
- `tools/js_parse_judge`: the front-end's judge. `emit` and `emit-module` write the serialized bytecode of a file;
  `batch` and `diff-batch` compare a folder with a reference compiler's output; `decode` disassembles; `speed` and
  `prof` measure; `fuzz` mutates sources.
- `odin run tools/tk -- gen_js_unicode [-force]`: makes `src/js/unicode/tables_generated.odin` from the pinned Unicode
  Character Database (`tools/js_unicode_gen`). The tables are committed: a build needs no network.
- The judge also profiles on Windows (`JSRT_PROF=1 js_judge eval f.js`, built with `-debug`), counts the heap by kind of cell
  (`JSRT_MEMPROF=1`), and fuzzes (`js_judge fuzz <dir>` mutates serialized bytecode; `fuzzsrc <dir>` mutates source
  text; `JSRT_FUZZ_RUN=1` also runs the mutants that load).
- `odin run tools/run_tests -- js js_pkg js_regexp`: two runtimes embedded as a program embeds one, one after the
  other and at once on two threads, and the engine's unit tests.
