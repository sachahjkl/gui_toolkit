package tk_http

// Request bodies of HTML forms, built in memory: multipart/form-data (text fields and files) and
// application/x-www-form-urlencoded, and a query string added to a URL. Pure: no system call.

import "core:bytes"
import "core:math/rand"
import "core:strings"

// A field of a multipart form: a text, or a file when file_name is set.
Form_Field :: struct {
	name:         string,
	value:        []u8,     // the text, or the file's bytes
	file_name:    string,   // "": a text field
	content_type: string,   // a file's ("": application/octet-stream); a text field has none
}

// A name and a value of a URL-encoded form or of a query string.
Param :: struct {
	name, value: string,
}

form_text :: proc(name, value: string) -> Form_Field {
	return {name = name, value = transmute([]u8)value}
}

form_file :: proc(name, file_name, content_type: string, data: []u8) -> Form_Field {
	return {name = name, value = data, file_name = file_name, content_type = content_type}
}

// The body of a multipart/form-data form and its Content-Type (with the boundary), both allocated with `allocator`. The
// boundary is random and occurs in none of the fields.
multipart :: proc(fields: []Form_Field, allocator := context.allocator) -> (body: []u8, content_type: string) {
	alphabet := "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
	letters: [24]u8
	boundary: string
	for {
		for &c in letters { c = alphabet[rand.int_max(len(alphabet))] }
		boundary = strings.concatenate({"tk_http-", string(letters[:])}, context.temp_allocator)
		if boundary_free(fields, boundary) { break }
	}
	return multipart_with(fields, boundary, allocator), strings.concatenate({"multipart/form-data; boundary=", boundary}, allocator)
}

// The body with a boundary chosen by the caller (the tests: exact bytes).
@(private)
multipart_with :: proc(fields: []Form_Field, boundary: string, allocator := context.allocator) -> []u8 {
	size := 0
	for f in fields { size += len(f.value) + len(f.name) + len(f.file_name) + len(f.content_type) + len(boundary) + 128 }
	b := strings.builder_make(0, size + len(boundary) + 8, allocator)
	for f in fields {
		strings.write_string(&b, "--")
		strings.write_string(&b, boundary)
		strings.write_string(&b, "\r\nContent-Disposition: form-data; name=\"")
		write_quoted(&b, f.name)
		strings.write_byte(&b, '"')
		if f.file_name != "" {
			strings.write_string(&b, "; filename=\"")
			write_quoted(&b, f.file_name)
			strings.write_string(&b, "\"\r\nContent-Type: ")
			strings.write_string(&b, f.content_type != "" ? f.content_type : "application/octet-stream")
		}
		strings.write_string(&b, "\r\n\r\n")
		strings.write_bytes(&b, f.value)
		strings.write_string(&b, "\r\n")
	}
	strings.write_string(&b, "--")
	strings.write_string(&b, boundary)
	strings.write_string(&b, "--\r\n")
	return b.buf[:]
}

// The boundary is in no field: a field that held it would end the form there.
@(private)
boundary_free :: proc(fields: []Form_Field, boundary: string) -> bool {
	for f in fields {
		if bytes.contains(f.value, transmute([]u8)boundary) { return false }
		if strings.contains(f.name, boundary) || strings.contains(f.file_name, boundary) { return false }
	}
	return true
}

// A name in quotes as browsers write it: a quote or a line break would end the header.
@(private = "file")
write_quoted :: proc(b: ^strings.Builder, s: string) {
	for c in transmute([]u8)s {
		switch c {
		case '"':  strings.write_string(b, "%22")
		case '\r': strings.write_string(b, "%0D")
		case '\n': strings.write_string(b, "%0A")
		case:      strings.write_byte(b, c)
		}
	}
}

// The body of an application/x-www-form-urlencoded form: "a=1&b=x+y", each name and value encoded (form_encode).
form_urlencoded :: proc(params: []Param, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for p, i in params {
		if i > 0 { strings.write_byte(&b, '&') }
		write_form_encoded(&b, p.name)
		strings.write_byte(&b, '=')
		write_form_encoded(&b, p.value)
	}
	return strings.to_string(b)
}

// `url` with `params` added to its query string (before a fragment), encoded as a form's.
query_append :: proc(url: string, params: []Param, allocator := context.allocator) -> string {
	if len(params) == 0 { return strings.clone(url, allocator) }
	head, fragment := url, ""
	if i := strings.index_byte(url, '#'); i >= 0 { head, fragment = url[:i], url[i:] }
	b := strings.builder_make(allocator)
	strings.write_string(&b, head)
	switch {
	case !strings.contains_rune(head, '?'):                             strings.write_byte(&b, '?')
	case !strings.has_suffix(head, "?") && !strings.has_suffix(head, "&"): strings.write_byte(&b, '&')
	}
	for p, i in params {
		if i > 0 { strings.write_byte(&b, '&') }
		write_form_encoded(&b, p.name)
		strings.write_byte(&b, '=')
		write_form_encoded(&b, p.value)
	}
	strings.write_string(&b, fragment)
	return strings.to_string(b)
}

// `s` encoded as a form's name or value: letters, digits and *-._ stay, a space is +, any other byte is %XX.
form_encode :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(s), allocator)
	write_form_encoded(&b, s)
	return strings.to_string(b)
}

@(private = "file")
write_form_encoded :: proc(b: ^strings.Builder, s: string) {
	hex := "0123456789ABCDEF"
	for c in transmute([]u8)s {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '*', '-', '.', '_': strings.write_byte(b, c)
		case ' ': strings.write_byte(b, '+')
		case:
			strings.write_byte(b, '%')
			strings.write_byte(b, hex[c >> 4])
			strings.write_byte(b, hex[c & 15])
		}
	}
}
