# Regular expressions (`src/js/regexp`)

An Odin port of QuickJS-ng's `libregexp`: a full ECMAScript regular-expression parser and bytecode compiler, and a
bounded backtracking interpreter. It replaces the C engine and leans on the language: tagged opcodes, interval character
sets, allocators given by the caller, an explicit (non-recursive) backtrack stack. It builds for `windows_amd64`,
`linux_amd64` and `freestanding_wasm32` with no libc.

Wren uses it for URLPattern (a component's regular expression, with the `v` flag). The runtime's own `RegExp` does not:
it executes the libregexp bytecode the front-end emits ([runtime.md](runtime.md), [frontend.md](frontend.md)).

## Decisions

- **Input of either width.** Input is a slice of code units, UTF-16 (JavaScript's semantics: offsets are UTF-16 indices)
  or UTF-8 (offsets are byte indices). Surrogate pairs combine only in unicode mode. A host with UTF-8 text does not
  convert it first.
- **Bounded by budgets, never by the native stack.** The interpreter is a flat dispatch loop with an explicit backtrack
  stack, so a pathological pattern cannot overflow the native stack. Two budgets bound it, as preferences
  (`regexp.exec.max_steps`, default 10 000 000 dispatches, then `.Out_Of_Steps`; `regexp.exec.max_stack`, default
  1 000 000 saved choice points, then `.Stack_Overflow`), and per call through `Exec_Limits`. A tool's build reads the
  defaults; a host reads them from the registry (`limits_from_prefs`). `settings.odin` is hosted only: freestanding builds
  have no registry.
- **Captures are code-unit offsets**, group 0 the whole match. Allocate on an arena and free a whole match at once.
- **The grammar is the whole of ECMAScript's**, with the `v` flag's nested classes and set operations and the Annex B
  leniencies when neither `u` nor `v` is set (a lone `{`, `]`, `}` as literals; invalid back references as octal or
  identity escapes).

## How it works

- `parser.odin` and `parse_*.odin` build an AST in two passes: a prescan counts the groups and collects the names, so
  forward references resolve.
- `compile*.odin` lower the AST to bytecode (the AST lives in an arena of the compilation's own). Quantifiers become
  split/goto/loop forms with an empty-match guard (`Push_Char_Pos`/`Check_Advance`) on every iteration past the minimum,
  so `(a*)*` cannot loop forever and `(.*)?` that matched nothing leaves its group undefined. Classes resolve to
  `ucd.Char_Range` interval sets, case-folded once at compile time when `i` is set. A lookbehind body is compiled in
  reverse, so that a dedicated backward interpreter walks it.
- `vm.odin`, `vm_behind.odin` and `vm_read.odin` are the interpreter: forward and reverse dispatch, UTF-8 and UTF-16
  reading in both directions, word boundaries, back references, and the lookaround sub-runner (the captures of a positive
  lookaround persist; a failed or negative one leaves none).

## Judged against the C reference

The differential judge stays in Wren (`wrentool engine rx-diff`, `src/tools/rxdiff`): it links QuickJS-ng 0.17's
`libregexp.c` and `libunicode.c`, which Wren builds with zig, and the toolkit has no C compiler. It runs both engines
over a literal corpus, tens of thousands of random fuzz patterns, and a speed benchmark, and reports every divergence.

Last run (Unicode 16.0.0, seed 12345, 30 000 fuzz patterns):

- **About 2 016 000 checks.** No divergence on compile and exec, normalization, and property, category and script ranges
  (exact at the boundaries). The only mismatches (about 3 700) are scalar Unicode predicates (`is_id_start`,
  `is_id_continue`, `is_cased`, `is_case_ignorable`) on a few code points where QuickJS 0.17's bundled
  `libunicode-table.h` differs from UCD 16.0.0: a data-version skew, not an engine difference. The UCD pin now follows
  QuickJS-ng (17.0.0, [unicode.md](unicode.md)).
- **Speed:** 2.1× to 4.6× slower than the C on five typical patterns (about 0.2 to 3 µs per exec). The gap is the capture
  snapshot taken at each choice point; a copy-on-write capture scheme would narrow it.
- **A bug of the reference:** QuickJS-ng 0.17's `lre_exec` corrupts the heap when a group with `+` or `*` (`(a|b)+`) runs
  many times in one process. It reproduces in pure C, without this engine. The judge guards the C calls, and the fuzz
  generator avoids the trigger for the differential pass while it still fuzzes the Odin engine over the whole grammar in
  its `-NoC` mode, where it holds.
