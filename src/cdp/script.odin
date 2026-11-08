package tk_cdp

// A script: a command per line, as `tk cdp play` runs it and as the window's recorder (Toolkit.startRecording) writes it.
// The words of a line, its options (--name value, or --name alone), the actions on the window.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"

Options :: struct {
	rest:  [dynamic]string,       // the words that are no option
	named: map[string]string,     // an option alone has the value ""
}

// The options of a command's words: "--name value", "--name" alone when the next word is an option or there is none.
options :: proc(words: []string, allocator := context.temp_allocator) -> (o: Options) {
	o.rest = make([dynamic]string, allocator)
	o.named = make(map[string]string, allocator)
	for i := 0; i < len(words); i += 1 {
		w := words[i]
		if !strings.has_prefix(w, "--") { append(&o.rest, w); continue }
		if i + 1 < len(words) && !strings.has_prefix(words[i + 1], "--") {
			o.named[w[2:]] = words[i + 1]
			i += 1
		} else {
			o.named[w[2:]] = ""
		}
	}
	return
}

has_option :: proc(o: ^Options, name: string) -> bool { return name in o.named }

// The value of an option; `default` when it is not given or has none.
option :: proc(o: ^Options, name: string, default := "") -> string {
	v := o.named[name] or_else ""
	return v != "" ? v : default
}

// A number of a script (a word that is not one counts as 0).
word_number :: proc(word: string) -> f64 {
	n, _ := strconv.parse_f64(word)
	return n
}

// A number as JSON, as JavaScript writes it: a whole one without its ".0", what is not a number as null.
json_number :: proc(n: f64) -> string {
	if n != n || n == math.INF_F64 || n == math.NEG_INF_F64 { return "null" }
	if n == math.trunc(n) && abs(n) < 1e15 { return fmt.tprintf("%d", i64(n)) }
	data, err := json.marshal(n, allocator = context.temp_allocator)
	return err == nil ? string(data) : "null"
}

// A line of a script: words, with JSON's quoted strings (what the recorder writes).
words :: proc(line: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	i := 0
	for i < len(line) {
		if is_blank(line[i]) { i += 1; continue }
		if line[i] == '"' {
			if end := quoted_end(line, i); end > 0 {
				s, err := json.parse_string(line[i:end], allocator = allocator)
				if v, is_string := s.(json.String); err == nil && is_string {
					append(&out, v)
					i = end
					continue
				}
			}
		}
		start := i
		for i < len(line) && !is_blank(line[i]) { i += 1 }
		append(&out, line[start:i])
	}
	return out[:]
}

@(private)
is_blank :: proc(c: byte) -> bool { return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f' }

// Where the string that opens at `at` ends (after its quote), or -1.
@(private)
quoted_end :: proc(s: string, at: int) -> int {
	for i := at + 1; i < len(s); i += 1 {
		switch s[i] {
		case '\\': i += 1
		case '"':  return i + 1
		}
	}
	return -1
}

// A box by its name (--name) or by its text (the other words).
@(private)
query :: proc(o: ^Options) -> string {
	if name := option(o, "name"); name != "" { return fmt.tprintf(`"name":%s`, quote(name)) }
	return fmt.tprintf(`"text":%s`, quote(strings.join(o.rest[:], " ", context.temp_allocator)))
}

@(private)
arg :: proc(o: ^Options, i: int) -> f64 { return i < len(o.rest) ? word_number(o.rest[i]) : 0 }

// The commands that act on the window (what a script holds). !known: `command` is not one of them. !ok: it failed (said).
act :: proc(c: ^Client, command: string, args: []string) -> (known, ok: bool) {
	o := options(args)
	params: string
	method := "Input.dispatchMouseEvent"
	button := option(&o, "button", "left")
	switch command {
	case "click":
		method = "Toolkit.click"
		params = fmt.tprintf(`{{%s,"index":%v,"count":%v,"button":%s}}`, query(&o), json_number(word_number(option(&o, "index", "0"))), json_number(word_number(option(&o, "count", "1"))), quote(button))
	case "move":
		params = fmt.tprintf(`{{"type":"mouseMoved","x":%s,"y":%s}}`, json_number(arg(&o, 0)), json_number(arg(&o, 1)))
	case "down":
		params = fmt.tprintf(`{{"type":"mousePressed","x":%s,"y":%s,"button":%s,"buttons":%d,"clickCount":1}}`, json_number(arg(&o, 0)), json_number(arg(&o, 1)), quote(button), button == "right" ? 2 : 1)
	case "up":
		params = fmt.tprintf(`{{"type":"mouseReleased","x":%s,"y":%s,"button":%s,"buttons":0,"clickCount":1}}`, json_number(arg(&o, 0)), json_number(arg(&o, 1)), quote(button))
	case "wheel":
		params = fmt.tprintf(`{{"type":"mouseWheel","x":%s,"y":%s,"deltaX":%s,"deltaY":%s}}`, json_number(arg(&o, 0)), json_number(arg(&o, 1)), json_number(arg(&o, 3) * 100), json_number(arg(&o, 2) * 100))
	case "key":
		return true, len(o.rest) > 0 && key(c, o.rest[0])
	case "type":
		return true, type_text(c, strings.join(o.rest[:], " ", context.temp_allocator))
	case "wait":
		time.sleep(time.Duration(arg(&o, 0) * f64(time.Millisecond)))
		return true, true
	case "wait-for":
		method = "Toolkit.waitFor"
		timeout := option(&o, "timeout")
		params = fmt.tprintf(`{{%s,"gone":%v%s}}`, query(&o), has_option(&o, "gone"), timeout != "" ? fmt.tprintf(`,"timeout":%s`, json_number(word_number(timeout))) : "")
	case "idle":
		timeout := option(&o, "timeout")
		r, called := call(c, "Toolkit.waitIdle", timeout != "" ? fmt.tprintf(`{{"timeout":%s}}`, json_number(word_number(timeout))) : "{}")
		if !called { return true, false }
		res, _ := r.(json.Object)
		if idle, _ := res["idle"].(json.Boolean); !idle { fmt.println("still moving at the timeout") }
		return true, true
	case "press":
		method = "Toolkit.axAction"
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `{{"name":%s,"action":%s,"index":%s`, quote(strings.join(o.rest[:], " ", context.temp_allocator)), quote(option(&o, "action", "Click")), json_number(word_number(option(&o, "index", "0"))))
		if role := option(&o, "role"); role != "" { fmt.sbprintf(&b, `,"role":%s`, quote(role)) }
		if has_option(&o, "value") { fmt.sbprintf(&b, `,"value":%s`, quote(o.named["value"])) }
		if has_option(&o, "number") { fmt.sbprintf(&b, `,"value":%s`, json_number(word_number(o.named["number"]))) }
		strings.write_string(&b, "}")
		params = strings.to_string(b)
	case:
		return false, false
	}
	_, ok = call(c, method, params)
	return true, ok
}
