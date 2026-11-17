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
- One known exception: `shape_realize` (`object.odin`) is contextless and makes `runtime.default_context()`. Its
  context's allocator is the heap's: an allocation under it that does not name the runtime's allocator escapes the
  embedder's. In Wasm the heap is the guest's, so Wren sees no difference. The ROADMAP entry
  "gt:js keeps its caller's context" replaces it with the context saved in `Runtime` at `engine_new`.
- Natively, a runtime needs one reserved block of addresses today: the collector's table of chunks spans the lowest
  chunk to the highest (plugins.md, Measures). The reserved block in `gt:js` itself is part of the ROADMAP entry
  "Plugins in JavaScript" (plugins.md, slice 1).

## The risk: package globals that are one runtime's state

In Wasm, each instance has its own memory, so a package global was one runtime's for free. Natively, every runtime of
the process shares it. These globals are one runtime's state: `poll_word`, `poll_hook`, `module_async_counter`, the
`trace_*` of `JSRT_TRACE_LAST_OP`, `jit_cfg`, `jit_stepping`, `jit_stats`, and the embedder's hooks
(`date_now_hook`, `clock_hook`, `span_hook`, `stack_move_hook`, `native_stack_low_hook`, `auto_init_getter`,
`jsdate.timezone_offset_proc`).

`tools/globals_allowed.txt` classes them `process`, with the note "one runtime per process today". That is true of
Wren, which has one runtime per Wasm instance. It is not true of a plugin host. The ROADMAP entry "gt:js runtimes of
their own" moves them into `Runtime`.

Two globals of that list are no runtime's state, so they stay globals:

- `atomics_lock` is a spin lock around Atomics on a SharedArrayBuffer. Agents on several threads share one buffer, so
  the lock is the process's.
- `frontend`'s `A_*` atoms are the numbers of predefined atoms, found once at start (`@(init)`) in a constant table.
  Every runtime has the same numbers.

## The test that breaks it

`tests/js`: two runtimes, each `engine_new` with its own block, each evaluates a module that awaits in a loop, matches
regular expressions and adds with Atomics on a SharedArrayBuffer, calls a native function, then a host call of a
function it left. Each checks its own result, collects, frees, and leaves no allocation.

- By default the two runtimes run one after the other. That passes: it proves the embedding and the teardown.
- With `-define:JS_TWO_THREADS=true`, they run at the same time on two threads, with a bounded wait. It fails as soon
  as one global of the list above is a runtime's state. It turns on when the globals move into `Runtime`.
