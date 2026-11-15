# json: JSON read and written

`import tk_json "gt:json"` (or the relative path of the submodule). Pure Odin, any target. The design is in
[src/md/features/json.md](../src/md/features/json.md).

Parse with `core:encoding/json` (`json.parse_string(text, parse_integers = true)`); read the value with the path reads
of this package; write JSON with its quoter and its writer.

## Reads

A path is a list of steps: a `string` is a key of an object, an `int` an index of an array. A missing key, an index out
of range, a step into a value that has no such step, or a value of another type gives the default. No read panics.

| Procedure | Result |
|---|---|
| `get(v, ..path) -> json.Value` | the value; `nil` (no variant) when the path is missing, `json.Null` for an explicit `null` |
| `has(v, ..path) -> bool` | whether the path names a value (a `null` is one) |
| `text(v, ..path, default = "") -> string` | a string |
| `number(v, ..path, default = 0.0) -> f64` | an integer or a float |
| `integer(v, ..path, default = 0) -> i64` | an integer, or a float that is whole and in the range of `i64` (`3.0`) |
| `boolean(v, ..path, default = false) -> bool` | a boolean |
| `array(v, ..path) -> json.Array` | an array, or `nil` (a `for` over it does nothing) |
| `object(v, ..path) -> json.Object` | an object, or `nil` |

```odin
v, err := json.parse_string(body, parse_integers = true, allocator = context.temp_allocator)
status := tk_json.text(v, "status", default = "idle")
first := tk_json.text(v, "data", 0, "id")
for it in tk_json.array(v, "data") {
	started := tk_json.number(it, "time", "started")
}
if _, is_null := tk_json.get(v, "exit").(json.Null); is_null { /* sent as null */ }
```

## The quoter

| Procedure | Result |
|---|---|
| `quote(s, allocator = context.temp_allocator) -> string` | `s` as a JSON string literal, quotes included (temp memory by default: it goes into a request's body, made at once with `fmt.tprintf`) |
| `quote_into(b, s)` | the same, written to a `strings.Builder` |
| `write_float(b, f)` | `f` in its shortest form that reads back to the same bits; `null` for NaN and the infinities |

The escapes: `"` and `\`; `\b \f \n \r \t`; the other control characters and DEL as `\u00XX` (upper-case hex). Text past
ASCII stays as UTF-8. A byte that is no UTF-8 is written as U+FFFD, so the output is always valid UTF-8. The same
escapes are valid in a TOML basic string. The runs with nothing to escape are copied whole, 16 bytes at a time.

`write_float` writes a whole float with no decimal point (`2`). A reader that keeps the type of a number needs `.0`
added (`tk_config`'s export adds it).

## The writer

`Writer` writes one document to a `strings.Builder`. The program begins and ends the objects and arrays and gives each
member its `key` before its value; the writer places the commas, the colons and, with an indent, the line breaks.

| Procedure | Result |
|---|---|
| `writer_make(b, indent = "") -> Writer` | a writer to `b`; with an indent (`"  "`), one item per line and `": "` after a key |
| `begin_object(w)`, `end_object(w)` | `{` and `}`; an empty object is `{}` |
| `begin_array(w)`, `end_array(w)` | `[` and `]`; an empty array is `[]` |
| `key(w, k)` | the key of the next member of the current object |
| `write_text(w, s)` | a string (`quote_into`) |
| `write_integer(w, n)` | an `i64` |
| `write_number(w, f)` | an `f64` (`write_float`) |
| `write_boolean(w, on)`, `write_null(w)` | `true` / `false`, `null` |
| `write_raw(w, json_text)` | JSON text the caller made, as it is |
| `write_value(w, v)` | a parsed `json.Value`, whole; the keys of an object sorted |
| `to_text(v, indent = "", allocator = context.temp_allocator) -> string` | a parsed value as JSON text |

```odin
b := strings.builder_make(context.temp_allocator)
w := tk_json.writer_make(&b)
tk_json.begin_object(&w)
tk_json.key(&w, "sessionID"); tk_json.write_text(&w, id)
tk_json.key(&w, "parts")
tk_json.begin_array(&w)
for p in parts { tk_json.write_text(&w, p) }
tk_json.end_array(&w)
tk_json.end_object(&w)
// {"sessionID":"ses_1","parts":["a","b"]}
```

The writer does not check the grammar: a key in an array or a member with no key is the program's error. It tracks
`WRITER_DEPTH_MAX` (64) levels of nesting and asserts past them.
