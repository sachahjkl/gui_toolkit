package rpc_test

// The child of the tests: this test program started again with MODE_ENV set. Its @(init) serves JSON-RPC on its
// standard input and output, then ends, before the test runner starts.
//
//	echo       answers each request by its method (below); ends at the end of its input
//	lsp        the same with Content-Length framing
//	stubborn   the same, but stays after the end of its input and ignores SIGTERM: only a kill ends it

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import tk_json "gt:json"

MODE_ENV :: "GT_RPC_TEST_CHILD"

@(init, private = "file")
child_init :: proc "contextless" () {
	context = runtime.default_context()
	mode, is_child := os.lookup_env(MODE_ENV, context.temp_allocator)
	if !is_child { return }
	context.allocator = runtime.heap_allocator()
	// (out of the temp memory that serve frees at each message)
	os.exit(serve(strings.clone(mode)))
}

@(private = "file")
Input :: struct {
	lsp: bool,
	buf: [dynamic]u8,
}

// The next message's text ("", false at the end of the input).
@(private = "file")
next_message :: proc(in_: ^Input) -> (text: string, ok: bool) {
	chunk: [4096]u8
	for {
		if in_.lsp {
			if end := strings.index(string(in_.buf[:]), "\r\n\r\n"); end >= 0 {
				head := string(in_.buf[:end])
				colon := strings.index_byte(head, ':')
				n, _ := strconv.parse_int(strings.trim_space(head[colon + 1:]))
				if len(in_.buf) >= end + 4 + n {
					text = strings.clone(string(in_.buf[end + 4:end + 4 + n]))
					remove_range(&in_.buf, 0, end + 4 + n)
					return text, true
				}
			}
		} else if nl := strings.index_byte(string(in_.buf[:]), '\n'); nl >= 0 {
			text = strings.clone(string(in_.buf[:nl]))
			remove_range(&in_.buf, 0, nl + 1)
			return text, true
		}
		n, err := os.read(os.stdin, chunk[:])
		if err != nil || n <= 0 { return "", false }
		append(&in_.buf, ..chunk[:n])
	}
}

@(private = "file")
send :: proc(lsp: bool, text: string) {
	if lsp {
		fmt.fprintf(os.stdout, "Content-Length: %d\r\n\r\n%s", len(text), text)
	} else {
		_, _ = os.write_string(os.stdout, strings.concatenate({text, "\n"}, context.temp_allocator))
	}
}

// The text of the id of `v` as JSON.
@(private = "file")
id_json :: proc(v: json.Value) -> string { return tk_json.to_text(tk_json.get(v, "id"), "", context.temp_allocator) }

@(private = "file")
serve :: proc(mode: string) -> int {
	in_ := Input{lsp = mode == "lsp"}
	lsp := in_.lsp
	if mode == "stubborn" { ignore_terminate() }
	never := make([dynamic]string)
	cancels := 0
	for {
		free_all(context.temp_allocator)
		text, ok := next_message(&in_)
		if !ok { break }
		v, err := json.parse_string(text, .JSON, true, context.temp_allocator)
		if err != .None { continue }
		method := tk_json.text(v, "method")
		id := id_json(v)
		params := tk_json.get(v, "params")
		result :: proc(lsp: bool, id: string, value: string) {
			send(lsp, fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":%s}}`, id, value))
		}
		switch method {
		case "echo":
			result(lsp, id, tk_json.to_text(params, "", context.temp_allocator))
		case "ask":
			// a request back; its answer is the next message
			send(lsp, `{"jsonrpc":"2.0","id":"q-1","method":"confirm","params":{"question":"go?"}}`)
			answer, has := next_message(&in_)
			if !has { return 0 }
			av, _ := json.parse_string(answer, .JSON, true, context.temp_allocator)
			result(lsp, id, fmt.tprintf(`{{"confirmed":%s,"id":%s}}`, tk_json.to_text(tk_json.get(av, "result"), "", context.temp_allocator), id_json(av)))
		case "notify":
			n := int(tk_json.integer(params, "n"))
			for i in 0 ..< n { send(lsp, fmt.tprintf(`{{"jsonrpc":"2.0","method":"update","params":{{"i":%d}}}}`, i)) }
			result(lsp, id, fmt.tprintf("%d", n))
		case "flood":
			n := int(tk_json.integer(params, "n"))
			pad := strings.repeat("p", 1000, context.temp_allocator)
			for i in 0 ..< n { send(lsp, fmt.tprintf(`{{"jsonrpc":"2.0","method":"flood","params":{{"i":%d,"pad":"%s"}}}}`, i, pad)) }
			result(lsp, id, "true")
		case "never":
			append(&never, strings.clone(id))
		case "$/cancel_request":
			cancels += 1
			wanted := tk_json.to_text(tk_json.get(params, "requestId"), "", context.temp_allocator)
			for nid, i in never {
				if nid != wanted { continue }
				send(lsp, fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"error":{{"code":-32800,"message":"cancelled"}}}}`, nid))
				ordered_remove(&never, i)
				break
			}
		case "cancels":
			result(lsp, id, fmt.tprintf("%d", cancels))
		case "huge":
			size := int(tk_json.integer(params, "size"))
			send(lsp, fmt.tprintf(`{{"jsonrpc":"2.0","method":"big","params":"%s"}}`, strings.repeat("x", size, context.temp_allocator)))
			send(lsp, `{"jsonrpc":"2.0","method":"after"}`)
			result(lsp, id, "true")
		case "garbage":
			send(lsp, "not json")
			send(lsp, `{"jsonrpc":"2.0","no":"method"}`)
			send(lsp, `{"jsonrpc":"2.0","id":"bad-1"}`)
			send(lsp, `[{"jsonrpc":"2.0","method":"b","params":1},{"jsonrpc":"2.0","method":"b","params":2}]`)
			send(lsp, strings.concatenate({strings.repeat("[", 200, context.temp_allocator), strings.repeat("]", 200, context.temp_allocator)}, context.temp_allocator))
			result(lsp, id, "true")
		case "stderr":
			total := int(tk_json.integer(params, "bytes"))
			chunk := strings.repeat("e", 64 * 1024, context.temp_allocator)
			for written := 0; written < total; written += len(chunk) { _, _ = os.write_string(os.stderr, chunk) }
			_, _ = os.write_string(os.stderr, "END-MARK")
			result(lsp, id, "true")
		case "exit":
			_, _ = os.write_string(os.stderr, "bye\n")
			return int(tk_json.integer(params, "code"))
		case "crash":
			runtime.trap()
		}
	}
	if mode == "stubborn" {
		for { time.sleep(time.Hour) }
	}
	return 0
}
