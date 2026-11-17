# The ECMAScript runtime (`src/js`)

The runtime is the second half of the engine: it executes QuickJS-ng 0.17 bytecode. It is Odin, builds for
`windows_amd64`, `linux_amd64` and `freestanding_wasm32` with an injected allocator and no system call. In Wren it runs
inside the Wasm sandbox exactly as QuickJS-in-Wasm did; the sandbox is kept on purpose there: it protects the host from
memory bugs of the engine. A program of the toolkit runs it natively ([README.md](README.md)).

The two halves meet at the **QuickJS-ng 0.17 bytecode**: the Odin front-end ([frontend.md](frontend.md)) and the reference
QuickJS C compiler emit the same serialized form, and this runtime reads and runs it. `compile_frontend.odin` calls the
front-end in process (a scratch arena per compile), so `eval`, `Function(...)`, modules and `$262.evalScript` need no
other compiler.

This is **not** a mechanical port of QuickJS. Where the C uses `#define` tags, manual reference counts and hand-rolled
dispatch, the Odin version uses tagged unions with exhaustive `switch`, `defer`, arenas where they help, generated
opcode and atom tables, and layouts friendly to `#soa`. The divergences are deliberate and listed at the end.

## Conformance (test262)

`tk js_test262` runs the suite pinned by `toolbox.test262_fetch` in worker processes (a crash or a hang costs one test),
with the rules of QuickJS-ng's `test262.conf`. The harness files and each test's `includes` and `flags` are honoured
(`onlyStrict`, `raw`, `async`, `module`, `CanBlockIsFalse`). `$262` provides `createRealm`, `evalScript`,
`detachArrayBuffer`, `gc`, `IsHTMLDDA` and real `agent`s: threads with their own runtime, sharing `SharedArrayBuffer`
memory; `Atomics.wait` and `notify` go through a process-wide waiter list.

At the move: 43 233 of 43 267 pass (99.92 %), 100 % of what QuickJS-ng passes in every directory; 5 453 skipped by the
configuration (features QuickJS-ng does not enable). The 34 failures are the tests QuickJS-ng fails too: evaluation order
of destructuring targets (7), a `callexpression` as an assignment target (7, Annex B), `AsyncFromSyncIterator` close on
poisoned wrappers (6), ambiguous `export *` namespaces (4), top-level-await ordering (2), `using` in imported modules (3),
a field named `get`/`set` followed by a generator (2), `with` over a proxy environment (2), and single cases. The
reference is QuickJS-ng's behaviour, not the specification: a test both fail is not a regression.

## Value model (`value.odin`)

A `Value` is a 16-byte tagged union: an 8-bit `Tag` and an 8-byte payload (`int32`, `float64`, bool, or a pointer to a
GC cell). A tagged union and not NaN-boxing, on purpose:

- It is the same on 64-bit native and on wasm32. Every `switch v.tag` is checked for exhaustiveness by the compiler.
- Small integers stay unboxed (`int32`, as QuickJS). `-0`, non-integral and out-of-range numbers use the `float64` lane.

Heap values (string, symbol, object, bigint, raw function bytecode, module) hold a `^Cell`. The representation is
isolated behind constructors and accessors. Wren's C API layer (`jscapi`, which stays in Wren:
[jscapi.md](https://github.com/sachahjkl/wren/blob/master/docs/js/jscapi.md)) encodes a `Value` in the 64-bit NaN-boxed
word QuickJS uses on wasm32, because Wren's glue is written against that.

## Strings, atoms, shapes, objects

- **Strings** (`string.odin`): UTF-16 code units stored compactly, Latin-1 (one byte per unit) or UTF-16, with **ropes**
  for concatenation (`a + b + c…` in a loop is linear; flattened on the first index, hash or compare). Source text given
  to the compiler keeps lone surrogates (WTF-8). `Function.prototype.toString` returns the real source text: the
  front-end keeps each function's text with `Compile_Options.keep_source`; `Host_Config.strip_source` drops it.
- **Atoms** (`atom.odin`, `atoms_table.odin`): 32-bit interned property keys. Array indices set bit 31 and never
  allocate. The predefined atoms are generated from `quickjs-atom.h`, so serialized bytecode refers to the same
  indices. The predefined atoms and symbols are permanent. An atom made at run time (a key a script reads or writes, a
  JSON key) is freed by a collection when no live shape, bytecode atom table, module, for-in iterator or string that
  caches it refers to it, and outside a native call; its slot is reused (`atom_free`).
- **Shapes** (`object.odin`): hidden classes with transitions and an open-addressed hash. An object stores a flat
  `[]Prop_Slot`. A delete, or growth past 48 properties, switches the object to a private dictionary shape. A chain of
  shared shapes keeps its keys and its hash in one `Props_Block`: a transition from the last shape of the chain writes
  into the block, so n keys added one by one store about 2n entries, not n²/2.
- **Objects**: a GC cell with a shape, inline slots, and an `Object_Data` tagged union for the internal slots of exotic
  kinds (Array, Function, Native, Bound, wrappers, ArrayBuffer/TypedArray/DataView, Map/Set, Proxy, Date, RegExp, Promise,
  Generator, Module namespace, Host…). Arrays keep a dense `[]Value` fast path (`fast_array`). A delete inside an Array,
  or a write at most 1024 past its end, keeps the storage and marks the hole with the `uninitialized` tag: the array
  leaves the fast path for the generic property code, which reads a hole as a missing property. A write further out
  makes a dictionary.
- **The layout on wasm32**, what Wren ships (`#assert`ed in `object.odin`): a `Cell` header is 8 bytes (`size`; the kind
  in a nibble with `pinned`, `in_ext` and two bits of the kind's own in a byte; `mark` a byte; the host's count of
  references in 16 bits, which sticks at its top and makes the cell a root for good). An `Object` is 40 bytes (a native
  function's `magic` is in it, so that `Object_Data` is 16, the size of its largest variant); a string header 28; a
  closure cell (`Var_Ref`) 32 (detached when `pvalue` points at its own `value`). An object's slots follow it in its cell
  when it is made with them (`object_new_shape`: an empty plain object has room for 4, one of a known shape exactly its
  keys), and so does what was out of line and lives as long as the object: a closure's cells (`object_tail`), an
  iterator's state, the values of an array, of an arguments object or of a match made with their room
  (`array_like_new`, up to a block of the pool). Slots that grow past it take a block of their own; what was in the cell
  stays there, unused. A plain object is 104 bytes, a closure 72 with its two cells, `[a, b]` 88, each in one block.
- **A function's `prototype`** is made when something first reads, defines or describes it (`Prop_Kind.lazy_prototype`,
  `function_prototype_make`): the slot is empty and the property's kind says so, every path that looks at a property's
  value goes by its kind, and the object then takes the shape the same keys have as data properties. An assignment
  (`F.prototype = {...}`) makes no object first (`function_prototype_settle`).

## Memory management (`gc.odin`)

A **precise, non-moving, stop-the-world mark-and-sweep** collector. Copying a `Value` is a plain copy: the interpreter
has no `dup`/`free` pairs, and cycles need no special pass. Refused: QuickJS's reference counts with a cycle collector.

- **Where the cells are, and their marks.** A cell of the pool (at most 512 bytes) is known by two bits of its chunk
  (`Chunk_Bits`, one pair of words per 32 grains of 8 bytes, after the chunk's header): one says a cell starts there, the
  other that it is marked. A cell finds its chunk by `Runtime.chunk_table`, the chunk of each 4 KiB of the addresses
  (chunks start on 4 KiB and are made of them: aligned on their own 256 KiB, the Wasm allocator lost up to that much in
  front of each). A cell is made marked, and a marking starts by clearing every mark: outside a marking, a cell that
  lives is marked (`cell_marked`). A cell over 512 bytes has its mark in its header and is listed (`Runtime.big_cells`).
  The bits cost 1/32 of a chunk; the list of every cell they replace cost 4 bytes a cell.
- **The table spans the lowest chunk to the highest.** In Wasm the addresses are dense. On a native heap, chunks are far
  apart and the table does not fit: natively, a runtime needs one reserved block of addresses today
  ([README.md](README.md), Memory).
- **The sweep reads the bits, not the cells**: a group of 32 grains whose cells all live is one load, and a cell that
  lives is never touched. A dead cell is finalized if it owns anything (`cell_alone`: a plain object with its slots
  inline, a closure, a flat string and a closure cell do not) and freed at once. It goes chunk by chunk, in the order of
  the addresses, in steps after the marking (`gc_sweep_step`: 1 MiB of chunks for each 128 KiB allocated since the last
  step), the big cells last. So no finalizer reads another cell: a function's closure cells are always in its own cell
  (`function_refs`), and a Map or Set iterator that dies unfinished gives its map back the right to compact at the
  marking (`gc_release_map_iters`), not in its finalizer.
- **Roots**: realms, the interpreter frame chain (arguments, locals, whole operand stacks, open closure cells), the job
  queue, the pending exception, atoms, the module registry, `temp_roots`, and the host roots.
- **Safe points** (function entry, loop back edge, entry of a native call) are the only places where a collection starts;
  allocation never collects. Native code keeps `Value`s in Odin locals that the collector cannot see; `cell_new` and
  `get`/`call` push what they return on `temp_roots`, which a native call truncates when it returns. Builtins that read
  straight out of internal storage and then call back into JavaScript root explicitly (`root`).
- **Weak references** (WeakMap and WeakSet keys, WeakRef, FinalizationRegistry) are ephemerons processed to a fixpoint
  after the strong marking. Shape transition caches are weak too.
- **Host roots**: each `Cell` has an `ext` count. `persist`/`ext_ref` increment it (O(1), no table), `unpersist`/
  `ext_unref` decrement it. Cells with a count that is not zero are listed in `rt.ext_cells` and are roots.
- **Host classes** (`host_class.odin`): objects of a class the host registers carry an opaque pointer, a finalizer, and
  optionally the references the opaque data holds (`gc_mark`) and exotic hooks for properties the object does not store.
  Finalizers of dead host objects run before any cell of the collection is freed. `gc_mark` is used twice: to
  **subtract** those references from the host counts (a cycle through opaque data does not keep itself alive: QuickJS's
  trial deletion, restricted to the cells with host references) and to trace them when the owner is live. The host part
  of such an object is a block of the size classes, which may hold the opaque data itself (`payload`: Wren's wrappers),
  freed with it. Only the objects listed in `rt.gc_hooked` are asked (`host_object_set_marked`).
- **Small blocks** (at most 512 bytes: cells, inline slots, small arrays and string data) come from size-class free lists
  cut out of 256 KiB chunks of the injected allocator (`mem_alloc`, `mem_free`, `mem_resize`; callers always pass the
  size they allocated with). A cell costs a pop and a push, not a host allocation.
- The heap is capped by `Host_Config.malloc_limit`. A collection runs when the heap passes `max(2.5 × live, live + 4 MiB)`.
- `Runtime.gc_swept` counts the cells freed and kept (kept: counted from the bits, not read); `Runtime.gc_ns` the time of
  the markings and sweeps. `-define:JSRT_GC_CENSUS=true` counts what died by kind (`Runtime.gc_dead`).
- The strings of numbers made lately (`str_from_u64`: `n.toString()`, an index as a key) are kept in 256 slots until the
  next collection clears them: a page that makes the same number a string for each element of a list makes it once. Such
  a string (`STR_NUMBER`) joined to a constant of the code, or to another, is kept too (`Runtime.concat_strings`, 256
  slots, cleared the same way): `t.toString() + ":true"` for each element is one string.

### Allocations nothing sees

Each falls back to the general path wherever the protocol can be seen. Wren's `examples/jsbench/hotcheck.js` checks each.

- **`for…of` and array destructuring over `Array.prototype.values`** (an array, `arguments`, a NodeList): when the
  object's `@@iterator` is this realm's `values` and `%ArrayIteratorPrototype%.next` is still the built-in data property,
  `for_of_start` leaves the object and an index on the operand stack in place of the iterator and its `next`
  (`for_of_fast`), and `for_of_next` steps them as the iterator would, its length read again at each step
  (`array_values_at`). A close (a `break`, a `return`, a throw, a destructuring that leaves elements) makes the iterator
  and calls its `return` only if `%ArrayIteratorPrototype%` or what it inherits from may have one (a proxy, a host object,
  lazy members: asked) (`for_of_close`). `yield*` keeps its iterator.
- **A mapped `arguments` object's closure cells are in its own cell** when nothing else can hold them: no function inside
  captures an argument, no direct eval, no coroutine (`mapped_args_in_cell`, found once per function, kept in its
  bytecode's cell flags). The frame lists them as its own (it closes them at its return), and an open one keeps its
  object alive (`Var_Ref.owner`).
- **`Object.getOwnPropertyDescriptor(o, p).field`** read at once (the hot loop: the call followed by `get_field`): the
  field, without the descriptor; a field the descriptor would not have makes it (`descriptor_field`).
- **`Object.defineProperty(o, p, {value: v, enumerable: !0, ...})`**, a literal of loads and constants given to the call:
  its fields go to the descriptor without the object, unless `Object.prototype` has a field the literal does not
  (`hot_define_literal`, `define_property_literal`).

### Where the memory of a realm goes (Wasm)

The linear memory of a Wasm module only grows, so what counts there is the high-water mark.

- **Lazy members.** A Web IDL prototype of Wren's glue is marked lazy with `JS_SetLazyMembers`: its shape is private and
  flagged, and `shape_find`, the enumerations of a shape (`own_property_keys`, `plain_keys_object`) and `add_property`
  call `shape_realize` first, which runs the glue's callback. It defines the members the eager code defined, with the
  same keys, order, descriptors, names and lengths. A realm then creates the function objects of the interfaces a script
  looks at, not all of them. In Wren: an empty realm went from 6 592 to 4 352 KiB of linear memory, and from 2.3 to
  1.3 ms to create. `shape_realize` is contextless and makes `runtime.default_context()`: the exception of
  [README.md](README.md), Memory.
- **Native functions.** A function object has exactly the two slots (`length`, `name`) it is born with. A C function of
  the glue without user data keeps its pointer in `Native_Data.data` (low bit set, `native_data_is_raw`). Its `name` is
  the string of the property key's atom when there is one (`str_interned`).
- **The compiler** (`compile_alloc.odin`): the front-end's allocator takes blocks up to 2 KiB from the arena, recycles them
  by size class (a larger free block is cut for a smaller request), and takes larger ones from the host heap, one by one,
  so that a table that dies is given back at once. `js_create_function` frees a function's tables (`free_func_def`) as
  soon as its bytecode exists, the passes free their buffers, and the serialized stream is built in one buffer
  (`serialize.odin`). A 650 KiB framework-like bundle asked the arena for 14.6 MB, now 6.5.

## Serialized-bytecode reader and verifier (`serialize.odin`)

It parses the front-end's stream, `BC_VERSION 29`: QuickJS's `JS_WriteObject(..., JS_WRITE_OBJ_BYTECODE)` (28) except for
a function's record, which is a **head** (flags, name, counts, position, closure variables without their names) and a
**body** with its length in front (closure names, cpool, vardefs, bytecode, line table, source). It also reads the atom
table (both atom encodings of the format), BigInt, arrays, objects and modules.

Most functions of a page never run, so a function is read in two steps. `read_object` keeps the stream (`Bytecode_Store`,
shared by the functions read from it, freed with the last of them), goes over the atom table noting where each atom is,
and reads the top-level function, head and body. A head is read with its parent's cpool; a body, and with it the heads
of the functions it holds, at the function's first run. An atom is read at its first use. Until then the function's
`code` is `LAZY_CODE`, one instruction (`lazy_body`, past `OPCODE_COUNT`: no stream can hold it) that reads the body and
starts the frame again: every way into a function ends there, and a call pays nothing for it. The JIT reads the body
itself at its entry when its threshold is 1, and does not compile or inline what has not run.
`Function.prototype.toString` reads the body. The line table and the source stay in the stream.

Once a body is read, the atom operands of its code (a copy) are rewritten and a **stack-height verifier** checks it. The
interpreter trusts the *types* of operands, as QuickJS does: bytecode comes from the compiler. The reader and the
verifier guarantee shape and stack discipline, not type correctness. A stream that fails: `read_object` throws for the
top-level function (Wren then compiles the source); a nested function throws a `SyntaxError` at each of its calls.

## Interpreter (`interp.odin`, `ops.odin`, `coro.odin`)

A `switch`-dispatch loop over the QuickJS instruction set. The common instructions (locals, arguments, integer and float
arithmetic, comparisons, branches, `get_field`/`put_field` with the prototype walk, array reads and writes, global
variables through a per-realm slot cache, string constants, **calls and returns**, and the native getter of an accessor
that `get_field` or a global finds: a DOM attribute, `window.document`) run in `interp_hot.odin`, a loop with raw
pointers whose few live values stay in registers. Everything else, and every fast path that does not apply, leaves it
with the pc on the instruction for the full dispatch in `interp.odin`. The hot loop is inlined into `interp_run`
(measured: a separate procedure is 20 to 25 % slower).

- Frames come from segmented value stacks, so that generators and async functions can suspend them (`coro.odin`:
  generators, async functions, async generators, `for await`, `yield*`).
- A plain JavaScript-to-JavaScript call does not recurse natively: `frame_push` puts the callee's `Frame` at the end of
  its value-stack block and the same `interp_run` activation runs it (`Frame.stackless`). So does `new` of a bytecode
  function, a spread call, and a getter or a setter that a property instruction finds (`Stackless`: what the frame's
  return gives its caller). Native callees (`c_function`) are called from the hot loop without a frame. What goes
  through a native (`map`, a Proxy trap, `Reflect`, a bound function, a listener) takes a new `interp_run` on the host
  stack. `Host_Config.max_stack_depth` bounds all of it, with a `RangeError` at the limit.
- On Wasm the host stack is two stacks (`stack.odin`): the shadow stack in linear memory is 2 MiB, every page of which is
  committed for each realm, and a recursion that runs past it goes on in blocks of the heap (the host moves the stack
  pointer, `stack_move_hook`; the blocks go when the outermost call returns). The machine's stack ends in a trap, so the
  engine asks the host (`native_stack_low_hook`) at each move and at each entry into a running engine, and stops with the
  same `RangeError`. Natively: one stack, and `Host_Config.max_stack_bytes`.
- The interrupt hook runs on a budget from the loop back edge. Operators follow the specification (`+` through
  ToPrimitive, ModRing bitwise, BigInt paths, loose and strict equality). Try/catch uses a per-frame handler stack
  (`catch`/`gosub`/`ret`/`nip_catch`).

## Standard library

Everything QuickJS-ng 0.17 ships, in `b_*.odin`: Object, Function, Array, String (with Unicode case mapping and
normalization from `src/js/unicode`), Number, Math and BigInt (`numconv`, `bigint`), Symbol, JSON (with source text
access), RegExp, Date (`datetime`), Map, Set, WeakMap, WeakSet, WeakRef, FinalizationRegistry, Promise, generators,
Reflect, Proxy, ArrayBuffer (resizable, immutable), SharedArrayBuffer (growable), TypedArray, Float16Array, DataView,
Atomics, Iterator helpers and `Iterator.concat`, `Array.fromAsync`, `DisposableStack`, `AsyncDisposableStack`,
`SuppressedError`, Uint8Array base64 and hex, `Error.prototype.stack`. `Intl` stays on the host (Wren's glue).

**Regular expressions.** Literals reach the runtime already compiled by the front-end to the **bytecode of QuickJS's
libregexp**. `lre_exec.odin` executes that format (a verifier checks it before use), so literals and `new RegExp` share
one matcher. This is not the matcher of `src/js/regexp` ([regexp.md](regexp.md)): the bytecode format is the contract
between the halves. Unicode properties, case folding and the properties of strings (`\p{RGI_Emoji}` …) come from the
tables generated from the pinned UCD ([unicode.md](unicode.md)).

- The matcher recognises a greedy loop of one character (`\S+`, `[^"]*`, `.*`) as the compiler emits it and takes the run
  at once, with one state of the kind `.run` for all of its positions. The character that follows the loop is tried
  before it goes back to a position. The format does not change, and a subject read as code points takes the bytecode's
  way.
- A search whose regexp starts with such a run, without back references, goes on after the run when it fails: what
  follows was tried at every position a later start could reach. So `/\S+@\S+\.\S+/` on a long token is linear where
  backtracking is quadratic.

## Measurements (Windows x64, Odin `-o:speed`, Zig 0.15 `-O2` for QuickJS)

| | gt:js | QuickJS-ng C |
|---|---:|---:|
| micro benchmarks, geometric mean of 20 cases | 100 % of QuickJS's speed (was 68 %) | 100 % |
| macro benchmarks (JSON, regexp, strings, array methods, Map/Set, classes, generators…), 28 cases | 119 % | 100 % |
| best and worst case (micro) | for-of 233 %, global variables 126 % | switch 62 %, nested int loops 69 % |
| peak working set, 300 k objects + 100 k Map entries | 188 MiB (was 244) | 135 MiB |
| freestanding wasm32 module, runtime + compiler (`-o:size`) | 1.63 MB (`-o:speed`: 1.99 MB) | QuickJS + glue + bindings 4.26 MB |

The benchmarks are Wren's `examples/jsbench`. Timings on one machine swing by ±30 % between runs when other builds run,
and a change that adds no work to the hot loop can still move an unrelated case by ±10 % (code layout): compare
interleaved runs and keep the best. Fuzzing: 40 000 mutants of serialized bytecode load with no crash; 30 000 mutants of
`language/` and `built-ins/` sources compile and run under an interrupt budget with no crash. Running the bytecode
mutants that load is opt-in, since a type-confused image can crash any interpreter that trusts the compiler.

## Intended divergences from QuickJS

- **A tagged union and not NaN-boxing** for values; a **precise tracing GC** and not reference counts with a cycle
  collector (Wren's C API layer re-creates the counted-reference contract for its glue).
- **Exhaustive Odin enums and `switch`** for tags, exotic kinds and opcodes; **generated opcode and atom tables** from the
  QuickJS headers.
- **Rope strings with Latin-1/UTF-16 compaction** as the default string representation.
- `JS_WriteObject` of data (the structured clone format) is not implemented.

## Known gaps

The 34 test262 failures above, all shared with QuickJS-ng. Speed is at parity with QuickJS on the micro benchmarks. The
slow cases pay one dispatch per bytecode (`switch` on integers 62 %, nested integer loops 69 %: the next step is
superinstructions or a pre-decoded code array), native-to-JavaScript callbacks (`sort` comparators, `forEach`: a new
`interp_run` activation each, about 1.9× slower than QuickJS) and destructuring. Memory is 1.4× QuickJS on
allocation-heavy scripts (natively a plain object costs 136 bytes; on wasm32, 104: `Object` 40 + 4 inline slots of 16;
what is left is mostly the 16 bytes of a `Value`).
