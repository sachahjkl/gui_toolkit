package tk_json

// Reads over the values that core:encoding/json parses: a path of keys and indices, a default when the path or the type
// does not match. Data from a server or a file never makes them panic (src/md/features/json.md).

import "core:encoding/json"
import "core:math"

// A step of a path: a key of an object, or an index of an array.
Step :: union {
	string,
	int,
}

// The value at `path` under `v`: nil (no variant) when a step is missing or goes into a value that has no such step;
// json.Null for an explicit null.
get :: proc(v: json.Value, path: ..Step) -> json.Value {
	cur := v
	for step in path {
		switch s in step {
		case string:
			obj, is_object := cur.(json.Object)
			if !is_object { return nil }
			cur = obj[s] or_else nil
		case int:
			arr, is_array := cur.(json.Array)
			if !is_array || s < 0 || s >= len(arr) { return nil }
			cur = arr[s]
		case:
			return nil
		}
	}
	return cur
}

// Whether `path` names a value under `v` (an explicit null is one).
has :: proc(v: json.Value, path: ..Step) -> bool {
	return get(v, ..path) != nil
}

// The string at `path`, or `default`.
text :: proc(v: json.Value, path: ..Step, default := "") -> string {
	s, is_string := get(v, ..path).(json.String)
	return is_string ? s : default
}

// The number at `path` (an integer or a float), or `default`.
number :: proc(v: json.Value, path: ..Step, default := 0.0) -> f64 {
	#partial switch x in get(v, ..path) {
	case json.Integer: return f64(x)
	case json.Float:   return x
	}
	return default
}

// The integer at `path`: an integer, or a float that is whole and in the range of i64 (`3.0`); else `default`.
integer :: proc(v: json.Value, path: ..Step, default: i64 = 0) -> i64 {
	#partial switch x in get(v, ..path) {
	case json.Integer:
		return x
	case json.Float:
		// 2^63 is exact as an f64; the interval is [-2^63, 2^63)
		if x >= -9223372036854775808.0 && x < 9223372036854775808.0 && math.trunc(x) == x { return i64(x) }
	}
	return default
}

// The boolean at `path`, or `default`.
boolean :: proc(v: json.Value, path: ..Step, default := false) -> bool {
	b, is_boolean := get(v, ..path).(json.Boolean)
	return is_boolean ? b : default
}

// The array at `path`, or nil.
array :: proc(v: json.Value, path: ..Step) -> json.Array {
	a, _ := get(v, ..path).(json.Array)
	return a
}

// The object at `path`, or nil.
object :: proc(v: json.Value, path: ..Step) -> json.Object {
	o, _ := get(v, ..path).(json.Object)
	return o
}
