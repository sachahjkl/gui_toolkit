# One JSON helper (`gt:json`, package `tk_json`)

## Purpose

The toolkit and its programs read JSON from servers, tools and files (`cargo metadata`, the flowgraph's store, an HTTP
API), and write JSON for requests, exports and indexes. Before this package each one had its own helpers: three private
`json_text` in the toolkit (`flowgraph`, `config`, `toolbox`) and opencode native's `jget`/`jstr`/`jnum`/`jbool`/`jarr`
and `jquote`. They differed on the points that matter: the escapes (`\u001f` or `\u001F`, DEL raw or escaped), a byte
that is no UTF-8 (raw or U+FFFD), a float read as an integer. One package fixes these once.

## Decisions

- **Parsing stays `core:encoding/json`.** The package adds no parser and no value type: it reads the `json.Value` that
  `json.parse` makes, and its writer's output reads back with `json.parse`. A second parser is a second set of bugs.
- **A read is a path with a default, and never panics.** `text(v, "a", 0, "b", default = "x")` walks object keys
  (`string`) and array indices (`int`). A missing key, an index out of range, a step into a value that is not an
  object or an array, or a value of the wrong type gives the default. A reply from a server is data that a program
  does not trust: a type assertion that panics on it is a crash on a server's change.
- **Missing and null are not the same.** `get` returns `nil` (no variant) for a missing path and `json.Null` for an
  explicit `null`: a program that must tell "not sent" from "sent as null" (opencode native's exit code) can.
- **Numbers.** `number` takes an `Integer` or a `Float`. `integer` takes an `Integer`, or a `Float` that is whole and
  in the range of `i64` (a server can write `3.0`); else the default. A clamp (`max(n, 0)`) is the caller's business.
- **One quoter.** `quote_into` writes a string literal: `"` and `\` escaped, `\b \f \n \r \t` by their letter, the other
  control characters and DEL as `\u00XX` (upper-case hex; DEL because TOML's basic strings refuse it raw, and
  `tk_config` quotes TOML keys and strings with the same procedure). Text past ASCII stays as UTF-8, never as `\u`
  escapes: the output is shorter and readable. A byte that is no UTF-8 is written as U+FFFD: JSON text is UTF-8, and a
  reader refuses or changes such a byte anyway. The runs with nothing to escape are copied whole, found 16 bytes at a
  time (`ascii.index_any_byte`): an attached file's data URL is megabytes of such a run.
- **A small streaming writer.** `Writer` writes to a `strings.Builder` as the program walks its data: no tree of values
  to build first, no reflection (`json.marshal` writes a struct's field names, not the protocol's names). The writer
  places the commas and the colons itself, which is where hand-written JSON breaks. Its only option is the indent: none
  (a request's body) or a string per level (a file that a person reads: one item per line).
- **A float that JSON cannot hold is `null`.** NaN and the infinities have no JSON form; `null` keeps the document
  valid. A float is written in its shortest form that reads back to the same bits.

## Refused alternatives

- **A JSON parser of our own, or a typed tree.** `core:encoding/json` parses correctly and is maintained with Odin.
- **`json.marshal` / `json.unmarshal` for every case.** They fit a struct that mirrors the document. The protocols that
  the programs speak have optional fields, unions by a `type` field and names that are not Odin names; a path read and
  a writer fit them better. A program can still use them where they fit.
- **Reads that return `(value, ok)`.** Every caller wanted a default, and a pair cannot be used inside an expression;
  `get` and the explicit `default` cover the rare case that must know.
- **Escaping text past ASCII as `\uXXXX`.** It is valid but longer and unreadable in a file, and no reader of ours
  needs ASCII-only output.
- **Keeping the bytes that are no UTF-8.** Some readers refuse the whole document, others change the byte: the output
  then differs by reader.
- **A writer that checks the grammar (a key in an array, a value without a key).** The program's code fixes the shape;
  a check on every call costs more than it finds. The writer only asserts that the nesting is not deeper than it can
  track.

## Subtle points

- The order of a parsed object's keys is lost (`json.Object` is a map). `write_value` writes them sorted, so the same
  value gives the same bytes.
- The paths use Odin's implicit conversion into the `Step` union: a string literal is a key and an integer literal an
  index, in one variadic list.
- `tk_site`'s search index keeps its own string writer: it drops control characters on purpose (an index of plain
  text), which is no general JSON quoting.
