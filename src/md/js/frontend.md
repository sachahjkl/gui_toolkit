# The front-end (`src/js/frontend`)

The package `frontend` is the first half of the engine. It compiles ECMAScript source to **QuickJS-ng 0.17 bytecode**,
the same byte for byte as `JS_WriteObject` makes (`BC_VERSION 28`, flags `JS_WRITE_OBJ_BYTECODE |
JS_WRITE_OBJ_STRIP_SOURCE`), with two choices of our own since round 31 of Wren's
[performance.md](https://github.com/sachahjkl/wren/blob/master/docs/performance.md): `o["x"]` is `o.x`, and `return f()`
stays a call and a return (no `tail_call`). The other half, the runtime ([runtime.md](runtime.md)), reads that bytecode.
The two halves meet only at the **bytecode format**: `opcodes.odin`, `atoms.odin`, `serialize.odin`.

The package compiles for `windows_amd64`, `linux_amd64` and `freestanding_wasm32`. Every allocation goes through the
injected allocator: an arena frees a whole compilation at once. No system call, no libc. It uses the leaf packages
`numconv` (numeric literals, [numconv.md](numconv.md)) and `unicode` (`ucd`, Unicode 17.0.0, [unicode.md](unicode.md)).

## Why a direct port of the QuickJS compiler

The first version went through an AST (lexer, parser, resolver and emitter apart; see Wren's history, commit
`dc13ba87`). It could not reach byte parity: QuickJS emits in **one pass** during the parse, and its bytecode depends on
that exact order. Examples: the rewrites of the last opcode emitted (`get_lvalue`, optional chaining, `delete`), the order
in which variables and scopes are made, the `OP_scope_get_var` placed before the scope is known, the labels numbered in
the order of emission, the `line_num` taken at the token. An AST imposes another order. Refused: the AST.

So the package follows the structure of `quickjs.c` (parse and emission, then `resolve_variables`, `resolve_labels`,
`compute_stack_size`), rewritten in idiomatic Odin:

- `JS_Value` is an exhaustive `union` (integer, float, string, BigInt, function, template) in place of a tagged
  `JSValue`; the compiler checks each `switch`.
- Strings are `String_Value` (Latin-1 or UTF-16, as `JSString`) without reference counts.
- Errors follow QuickJS's "the first one wins" model, but without `longjmp` and without exceptions: each procedure returns
  `bool` (error) as in the C, which keeps the port readable line by line against it.
- No GC: everything lives in the compilation's allocator. A function's tables (`free_func_def`) and the passes' buffers
  are still freed explicitly (`delete`) as soon as its bytecode exists: a recycling allocator
  (`src/js/compile_alloc.odin`) gives them to the next functions. With a plain arena, `delete` does nothing and the
  result is the same. The size given to `delete` must be the size of the allocation.

## Regular expression literals

For each regexp literal, QuickJS stores in the constant pool the pattern's string **and** the compiled libregexp
bytecode, then emits `OP_regexp`. So the syntax verdict of a regexp is part of the script's verdict. `js_regexp.odin` ports
`lre_compile` (parser and emitter) with its particularities that show in the bytes:

- character ranges follow libunicode's `CharRange` (an inverted set ends at `0xFFFFFFFF`);
- `\p{gc=…}` rebuilds the segmentation of the table `unicode_gc_table` (one range per run of one category, plus the
  alternating Lu/Ll runs), because libunicode adds these ranges without merging them;
- string sets (`v`) keep the order of the hash table and of the `rqsort` sort of `cutils.h`;
- case folding keeps libunicode's exceptions (U+FB05, U+FB06).

The runtime executes this format (`lre_exec.odin`), not the one of `src/js/regexp`.

## Stack guard

`Compile_Options.stack_budget` (bytes, default 512 KiB) bounds the stack the compilation uses under its entry point, as
`js_check_stack_overflow` does. Every recursion (expressions, statements, functions, `js_create_function`, regexps)
checks the address of a local variable; past the budget, the compilation fails with "stack overflow" and does not crash.
On wasm32, that variable lives in the shadow stack (the one that would overflow). `max_nesting` (default 6000) stays a
second bound, in number of calls. Set `stack_budget` from the caller's remaining stack (Wren's wasm target has a 1 MiB
stack).

## Parity

The judge (`tools/js_parse_judge`) compared the positive corpus and the syntax verdicts of the negative corpus with the
C oracle (QuickJS-ng 0.17 built with zig, with an empty module loader). Results (test262, 2026-10-28):

- `test/language`, positive: 19 272 files, 19 006 compiled on both sides, **19 006 identical (100 %)**; both engines
  reject the 266 others (features QuickJS-ng 0.17 lacks).
- `test/language`, syntax negatives: **4 452 verdicts of 4 452 identical**.
- All of `test/` (48 949 positives + harness): 48 620 identical of 48 623 compiled (99.99 %); 46 files rejected by us only
  (the string properties `\p{RGI_Emoji}`…, below); 4 658 negatives, all verdicts identical.
- Speed: the same order as QuickJS (0.9× to 1.15× depending on the file, compilation alone, without serialization).

The scripts that ran the oracle depended on a private folder and are removed; the judge's `batch` and `diff-batch` run
directly against a folder of reference output.

## What is left

- The string properties of the `v` flag (`Basic_Emoji`, `RGI_Emoji*`, `Emoji_Keycap_Sequence`): the data of
  `emoji-sequences.txt` and `emoji-zwj-sequences.txt` must be in `ucd`, then libunicode's order of insertion reproduced.
  46 files of `built-ins/RegExp`.
- `Changes_When_Casemapped/Lowercased/Uppercased`: libunicode enumerates the entries of `case_conv_table1` without merging
  them; that segmentation must be rebuilt (`unicode_gen.c`, `find_run_type`). 3 files.

## The contract with the runtime

- Entry: `compile_program(src, .script | .module, alloc, opts)`, then `write_object_of(res, alloc)`.
- A regexp literal gives two constants, the pattern's string and the libregexp bytecode (a Latin-1 string), then
  `OP_regexp`.
- A module is a `BC_TAG_MODULE` record that wraps the function.
- Template objects: `TEMPLATE_OBJECT(cooked…, TEMPLATE_OBJECT(raw…, UNDEFINED))`.
- A BigInt of the pool: 32-bit limbs, two's complement, no redundant limb.
- `PREDEFINED_ATOMS` must stay in the order of `quickjs-atom.h`. `Private_brand` and the `Symbol.*` are symbols: no string
  ever matches them.
