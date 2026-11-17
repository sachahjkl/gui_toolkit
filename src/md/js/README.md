# gt:js: intent

`gt:js` (`src/js`, package `jsrt`, and its sub-packages) is Wren's JavaScript engine, moved into the toolkit
unchanged except for its import paths. The documentation for a program's author is [docs/js.md](../../../docs/js.md).

## Why it is here

[plugins.md](../features/plugins.md), decision 1: plugins in JavaScript run Wren's Odin engine natively, from one
copy. The toolkit keeps the engine so that Wren and a plugin host compile the same source, Wren to `freestanding_wasm32`,
a program to its own system. An engine change for Wren is from now on a toolkit version.

The package clauses stay (`jsrt`, `frontend`, `regexp`, `bigint`, `numconv`, `jsdate`, `ucd`). No core package has
these names, and every importer already uses an alias. `gt:js` is the runtime itself, not `gt:js/rt`: `embed.odin`
is its public face, and the leaf libraries are its sub-packages, so a program imports one path.

## The boundary with Wren

What stays in Wren, and why:

- **Wasmtime.** A web page is hostile code that runs without consent: Wren needs the memory sandbox. The toolkit
  refuses 12 MB and a Rust library in every program (plugins.md).
- **`jscapi`**, the QuickJS C API over the engine. Only Wren's web glue is written against it.
- **The image**: the glue, its build to wasm32, the snapshot and the precompiled machine code. The glue is Wren's.
- **The Web IDL bindings** and their generators: they describe the web platform, not the engine.
- **The Wasm test262 runner**: it tests the shipped image. The native judge (`tools/js_judge`) tests `gt:js`.

What moved: the engine and its six libraries, the judges (`tools/js_judge`, `tools/js_parse_judge`) and the generator
of the Unicode tables (`tools/js_unicode_gen`), with their automation (`tk gen_js_unicode`, `tk js_test262`,
`toolbox.test262_fetch`: one pin of test262 for Wren's runner and the toolkit's).

## The parts

- [runtime.md](runtime.md): the runtime, `src/js`: values, objects, the collector, the bytecode reader, the interpreter.
- [frontend.md](frontend.md): the compiler to QuickJS-ng bytecode.
- [jit.md](jit.md): the JIT to WebAssembly, which runs only in Wren's Wasm host.
- [regexp.md](regexp.md), [unicode.md](unicode.md), [bigint.md](bigint.md), [numconv.md](numconv.md),
  [datetime.md](datetime.md): the leaf libraries.

## Memory: the embedder passes the allocator

`gt:js` chooses no allocator. `engine_new(allocator, config)` takes one, and every allocation of a runtime goes
through it. Wren's glue gives the guest heap; a test gives a tracker; a plugin host gives a reserved block.

- Refused: `base.process_allocator()`. It is a program's policy (Wren's tracker), and the engine also runs in a Wasm
  instance built with `-default-to-nil-allocator`, where no process allocator exists. A library takes its allocator
  from its caller, as `core:` packages do.
- Refused: `runtime.heap_allocator()` in the engine. The program's tracker then sees every allocation.
- A contextless entry point (`shape_realize` in `object.odin`, which hot lookups reach through `shape_find`) runs
  under the context that `engine_new` saved in `Runtime.caller_context`: its caller's, with the runtime's allocator
  (`runtime_context`). An allocation there that names no allocator goes through the embedder's, which its tracker
  sees. Refused: `runtime.default_context()`, the process heap, which escaped the embedder (in Wasm it was the
  guest's, so Wren saw no difference). The saved context's temp allocator, when it is Odin's default (a thread-local
  arena), is bound again to the thread that enters, as `core:thread` does: a runtime may run on another thread than
  engine_new's.
- Natively, the cells' chunks live in one block of addresses the runtime reserves itself (`chunk_block.odin`): the
  collector's table of chunks spans the lowest chunk to the highest (plugins.md, Measures), which a process heap makes
  too wide. The embedder's allocator still gives everything else, so its tracker sees those allocations. The block's
  last eighth is a spare that turns a failed allocation into the uncatchable "out of memory" at the next poll
  (plugins.md, decision 1, "As built"). Refused: the embedder reserving the block (tests/js did it by hand): every
  embedder had to know of the chunk table.

## State: a runtime's is in its Runtime

In Wasm, each instance has its own memory, so a package global was one runtime's for free. Natively, every runtime of
the process shares it. So no package global of `gt:js` is one runtime's state. Each moved from Wren's engine to where
the code reaches it through the runtime it already holds (`ctx.rt`, `rt`, `f.ctx.rt`, the JIT's `c.rt`):

- **The embedder's hooks are `Host_Config` fields**: `date_now_hook`, `timezone_offset_proc`, `clock_hook`,
  `span_hook`, `stack_move_hook`, `native_stack_low_hook`, `poll_hook`, `auto_init_getter`. The embedder chooses them
  like the other hooks of the config, at `engine_new` or later in `rt.config`; the engine only reads them. The names
  stayed, so that Wren's glue changes `js.x = ...` into `rt.config.x = ...` and nothing else.
- **The runtime's own state is a `Runtime` field**: `poll_word` (a timer writes it), `module_async_counter`, the
  JIT's `jit_cfg` (`jit_configure(rt, ...)`), `jit_stepping` and `jit_stats` (`jit_stat(rt, which)`), and `trace`
  (`JSRT_TRACE_LAST_OP`).
- **The leaf package `jsdate` takes the time zone as a parameter** of each procedure that reads local time. It has no
  runtime to reach, and a global there would be every runtime's again.

The cost on the hot paths is one load through a pointer the code already holds. The interpreter reads `rt.jit_cfg`
and `&rt.jit_stepping` through its local `rt`; a call reads `rt.poll_word` where it read the global. Compiled code
loads the poll word from its address, a constant of the code as the global's was: the code is one runtime's, and the
runtime keeps the word for its life.

Refused:

- **Thread-locals.** A runtime is used by one thread at a time, not always the same one: a plugin host may hand a
  runtime to another worker. And two runtimes on one thread would share them.
- **A global table keyed by the runtime.** A lookup, and a lock, on the hot path (every call reads the poll word), for
  state the code can reach in one load.
- **Setters such as `set_poll_hook(rt, p)`.** A config field is the pattern the other hooks already follow, and it can
  be set before the runtime exists.

Two globals are no runtime's state, so they stay globals:

- `atomics_lock` is a spin lock around Atomics on a SharedArrayBuffer. Agents on several threads share one buffer, so
  the lock is the process's.
- `frontend`'s `A_*` atoms are the numbers of predefined atoms, found once at start (`@(init)`) in a constant table.
  Every runtime has the same numbers.

## The test that breaks it

`tests/js`: two runtimes, each `engine_new` with its own block and tracker and its own hooks, each evaluates a module
that awaits in a loop, matches regular expressions, adds with Atomics on its own SharedArrayBuffer, spins past the
interrupt checks, reads a lazy object, calls a native function, then a host call of a function it left. Each checks
its own result, collects, frees, and leaves no allocation.

- Each script sees its own runtime's `Date.now()` and time zone. Only the first runtime's poll word is raised: its
  hook runs, the second's never does. Each runtime's async module order ends at 1. The lazy object's members are made
  under the runtime's allocator, and its tracker sees what they allocate.
- One test runs the two runtimes one after the other; the other at the same time on two threads (a barrier starts
  them together), with a bounded wait. The second fails as soon as one runtime's state is shared.
