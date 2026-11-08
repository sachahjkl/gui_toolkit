package tk_cdp

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
a_frame_comes_back_as_it_left :: proc(t: ^testing.T) {
	for size in ([]int{0, 5, 125, 126, 65535, 65536}) {
		payload := make([]byte, size, context.temp_allocator)
		for i in 0 ..< size { payload[i] = byte(i) }
		mask := [4]byte{1, 2, 3, 4}
		sent := ws_encode(WS_TEXT, payload, mask, context.temp_allocator)
		// (a server's frame is this one without the mask: strip it, and undo it)
		at := size < 126 ? 2 : (size < 65536 ? 4 : 10)
		plain := make([dynamic]byte, context.temp_allocator)
		append(&plain, sent[0], sent[1] & 0x7f)
		append(&plain, ..sent[2:at])
		for b, i in sent[at + 4:] { append(&plain, b ~ mask[i % 4]) }
		opcode, fin, got, used, complete := ws_decode(plain[:])
		testing.expect(t, complete && fin)
		testing.expect_value(t, opcode, u8(WS_TEXT))
		testing.expect_value(t, used, len(plain))
		testing.expect_value(t, string(got), string(payload))
	}
}

@(test)
half_a_frame_waits_for_the_rest :: proc(t: ^testing.T) {
	_, _, _, _, complete := ws_decode({0x81, 5, 'h', 'e'})
	testing.expect(t, !complete)
	_, _, _, _, complete = ws_decode({0x81})
	testing.expect(t, !complete)
	_, _, _, _, complete = ws_decode({0x81, 126, 0})
	testing.expect(t, !complete, "half a length")
}

@(test)
an_answer_is_the_one_of_its_call :: proc(t: ^testing.T) {
	_, _, mine := answer(`{"method":"Page.frame","params":{}}`, 3)
	testing.expect(t, !mine, "an event")
	_, _, mine = answer(`{"id":2,"result":{}}`, 3)
	testing.expect(t, !mine, "another call")
	_, _, mine = answer(`not json`, 3)
	testing.expect(t, !mine, "not JSON")
	_, failure, mine2 := answer(`{"id":3,"error":{"code":-32000,"message":"no such box"}}`, 3)
	testing.expect(t, mine2)
	testing.expect_value(t, failure, "no such box (-32000)")
	r, none, mine3 := answer(`{"id":3,"result":{"x":1.5}}`, 3)
	testing.expect(t, mine3 && none == "")
	o, _ := r.(json.Object)
	testing.expect_value(t, number(o["x"]), 1.5)
}

@(test)
a_call_names_its_session_only_when_it_has_one :: proc(t: ^testing.T) {
	testing.expect_value(t, request(3, "Page.enable", "{}", ""), `{"id":3,"method":"Page.enable","params":{}}`)
	testing.expect_value(t, request(4, "Page.enable", "{}", "S1"), `{"id":4,"method":"Page.enable","params":{},"sessionId":"S1"}`)
	testing.expect_value(t, quote("a\"b\n"), `"a\"b\n"`)
}

@(test)
a_socket_address_gives_its_path :: proc(t: ^testing.T) {
	testing.expect_value(t, socket_path("ws://127.0.0.1:9222/devtools/page/1"), "/devtools/page/1")
	testing.expect_value(t, socket_path("ws://127.0.0.1:9222"), "")
	testing.expect_value(t, socket_path("http://x/y"), "")
}

@(test)
a_response_with_chunks_or_without :: proc(t: ^testing.T) {
	status, body, ok := http_parse("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi")
	testing.expect(t, ok && status == 200 && body == "hi")
	status, body, ok = http_parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: Chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n")
	testing.expect(t, ok && body == "abcde", body)
	_, _, ok = http_parse("HTTP/1.1 200 OK\r\n")
	testing.expect(t, !ok, "no end of the head")
}

@(test)
a_key_by_its_name :: proc(t: ^testing.T) {
	key, mods, text := key_parts("ctrl+shift+t")
	testing.expect_value(t, key, "t")
	testing.expect_value(t, mods, KEY_CTRL | KEY_SHIFT)
	testing.expect_value(t, text, "")
	key, mods, text = key_parts("Enter")
	testing.expect_value(t, key, "Enter")
	testing.expect_value(t, mods, 0)
	key, _, text = key_parts("a")
	testing.expect_value(t, text, "a")
	key, _, _ = key_parts("ESC")
	testing.expect_value(t, key, "Escape")
	key, mods, text = key_parts("Alt+space")
	testing.expect(t, key == " " && mods == KEY_ALT && text == " ", "a space types itself")
	key, _, _ = key_parts("ArrowDown")
	testing.expect_value(t, key, "ArrowDown")
}

@(test)
the_words_of_a_line :: proc(t: ^testing.T) {
	w := words(`click --name "nav0"  type "a \"b\" c" x"y`)
	testing.expect_value(t, strings.join(w, "|", context.temp_allocator), `click|--name|nav0|type|a "b" c|x"y`)
	w = words(`type "unclosed`)
	testing.expect_value(t, strings.join(w, "|", context.temp_allocator), `type|"unclosed`)
	testing.expect_value(t, len(words("   ")), 0)
}

@(test)
the_options_of_a_command :: proc(t: ^testing.T) {
	o := options({"Lazy", "column", "--index", "2", "--gone", "--timeout", "500", "--all"})
	testing.expect_value(t, strings.join(o.rest[:], " ", context.temp_allocator), "Lazy column")
	testing.expect_value(t, option(&o, "index"), "2")
	testing.expect(t, has_option(&o, "gone") && option(&o, "gone", "x") == "x", "an option alone")
	testing.expect(t, has_option(&o, "all"), "the last one, alone")
	testing.expect(t, !has_option(&o, "name"))
	testing.expect_value(t, json_number(word_number("1.5")), "1.5")
	testing.expect_value(t, json_number(word_number("nope")), "0")
}

@(private = "file")
checker :: proc(w, h: int) -> Picture {
	p := Picture{w, h, make([]u8, w * h * 4, context.temp_allocator)}
	for y in 0 ..< h {
		for x in 0 ..< w {
			at := (y * w + x) * 4
			v: u8 = (x + y) % 2 == 0 ? 255 : 0
			p.pixels[at], p.pixels[at + 1], p.pixels[at + 2], p.pixels[at + 3] = v, 128, 255 - v, 255
		}
	}
	return p
}

@(test)
a_picture_comes_back_as_it_left :: proc(t: ^testing.T) {
	p := checker(7, 5)
	data, ok := png_encode(p, context.temp_allocator)
	testing.expect(t, ok)
	back, decoded := png_decode(data, context.temp_allocator)
	testing.expect(t, decoded)
	testing.expect(t, back.width == 7 && back.height == 5 && string(back.pixels) == string(p.pixels), "the same pixels")
	_, bad := png_decode({1, 2, 3}, context.temp_allocator)
	testing.expect(t, !bad, "not a PNG")
}

@(test)
two_pictures_compared :: proc(t: ^testing.T) {
	a := checker(4, 4)
	b := checker(4, 4)
	b.pixels[0] ~= 0xff            // one pixel far off
	b.pixels[4 * 5 + 1] += 10      // one a little: under the delta
	r := compare(a, b, PIXEL_DELTA, context.temp_allocator)
	testing.expect(t, !r.size_differs)
	testing.expect_value(t, r.share, 1.0 / 16)
	testing.expect(t, r.diff.pixels[0] == 255 && r.diff.pixels[1] == 0 && r.diff.pixels[3] == 255, "red where it differs")
	testing.expect(t, compare(a, checker(4, 3), PIXEL_DELTA).size_differs, "another size")
}

@(test)
a_picture_made_smaller_keeps_its_mean :: proc(t: ^testing.T) {
	p := checker(8, 6)
	s := shrink(p, 4, context.temp_allocator)
	testing.expect(t, s.width == 4 && s.height == 3, "the height follows")
	// (two by two of a checker: the mean of black and white)
	testing.expect(t, s.pixels[0] >= 127 && s.pixels[0] <= 128 && s.pixels[1] == 128 && s.pixels[3] == 255, fmt.tprint(s.pixels[:4]))
	same := shrink(p, 0, context.temp_allocator)
	testing.expect(t, same.width == 8 && string(same.pixels) == string(p.pixels), "0: as it is")
}

@(test)
a_script_and_a_timeline_are_read :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "tk_cdp_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	script := fmt.tprintf("%s/steps.txt", dir)
	_ = os.write_entire_file(script, "# a comment\r\nclick --name \"nav0\"\r\n\r\nidle\n")
	s, ok := read_script(script, context.temp_allocator)
	testing.expect(t, ok && len(s.lines) == 2 && s.lines[0] == `click --name "nav0"` && s.times == nil, "the lines, no times")
	timeline := fmt.tprintf("%s/timeline.json", dir)
	_ = os.write_entire_file(timeline, `{"kind":"played","steps":[{"t":0,"line":"start","image":"step-000.png"},{"t":12.5,"line":"key Enter","image":"step-001.png"}],"frames":[]}`)
	s, ok = read_script(timeline, context.temp_allocator)
	testing.expect(t, ok && len(s.lines) == 1 && s.lines[0] == "key Enter" && s.times[0] == 12.5, "the actions, with their times")
	testing.expect_value(t, s.dir, dir)
	_, ok = read_script(fmt.tprintf("%s/none.txt", dir), context.temp_allocator)
	testing.expect(t, !ok, "no file")
}

@(test)
a_time_as_javascript_writes_it :: proc(t: ^testing.T) {
	testing.expect_value(t, len(time_text({})), len("1970-01-01T00:00:00.000Z"))
}

@(test)
an_answer_printed_as_javascript_would :: proc(t: ^testing.T) {
	v, err := json.parse_string(`{"b":[1,2.5,{}],"a":"x\"","c":null,"d":true,"e":720.0,"f":[]}`, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, stringify(v), `{"a":"x\"","b":[1,2.5,{}],"c":null,"d":true,"e":720,"f":[]}`)
	testing.expect_value(t, stringify(v.(json.Object)["b"], 2), "[\n  1,\n  2.5,\n  {}\n]")
}
