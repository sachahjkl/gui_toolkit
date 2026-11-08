package tk_site

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
a_path_is_a_file_of_the_folder :: proc(t: ^testing.T) {
	cases := [?][2]string{
		{"/index.html", "R/index.html"},
		{"/", "R/index.html"},
		{"/classic/", "R/classic/index.html"},
		{"/classic/./a.html", "R/classic/a.html"},
		{"/classic/../a.html", "R/a.html"},
		{"//img///a.png", "R/img/a.png"},
		{"img\\a.png", "R/img/a.png"},
		{"/a b.png", "R/a b.png"},
	}
	for c in cases {
		file, ok := site_file("R", c[0])
		testing.expectf(t, ok && file == c[1], "%s: %s", c[0], file)
	}
}

@(test)
a_path_never_leaves_the_folder :: proc(t: ^testing.T) {
	cases := [?]string{
		"/..",
		"/../secret",
		"/a/../../secret",
		"..\\secret",
		"/a\\..\\..\\secret",
		"/.. /secret",
		"/.../secret",
		"/C:/Windows/win.ini",
		"/index.html::$DATA",
		"/index.html.",
		"/index.html ",
		"/a\x00.html",
	}
	for c in cases {
		file, ok := site_file("R", c)
		testing.expectf(t, !ok, "%q gave %s", c, file)
	}
}

@(test)
a_request_says_its_path :: proc(t: ^testing.T) {
	path, ok := site_request_path("GET /img/a%20b.png?v=1 HTTP/1.1\r\nHost: x\r\n\r\n")
	testing.expect(t, ok && path == "/img/a b.png", path)
	path, ok = site_request_path("GET /%2e%2e/secret HTTP/1.1\r\n\r\n")
	testing.expect(t, ok && path == "/../secret", "decoded here, refused by site_file")
	_, inside := site_file("R", path)
	testing.expect(t, !inside, "an encoded way out is one")
	_, ok = site_request_path("GET /a%zz HTTP/1.1\r\n\r\n")
	testing.expect(t, !ok, "what does not decode")
	_, ok = site_request_path("nonsense\r\n\r\n")
	testing.expect(t, !ok, "not a request")
	_, ok = site_request_path("GET http://elsewhere/ HTTP/1.1\r\n\r\n")
	testing.expect(t, !ok, "only paths")
}

@(test)
a_file_has_its_type :: proc(t: ^testing.T) {
	testing.expect_value(t, site_mime("a/b.html"), "text/html")
	testing.expect_value(t, site_mime("b.css"), "text/css")
	testing.expect_value(t, site_mime("b.js"), "text/javascript")
	testing.expect_value(t, site_mime("b.png"), "image/png")
	testing.expect_value(t, site_mime("b.woff2"), "application/octet-stream")
	testing.expect_value(t, site_mime("html"), "application/octet-stream")
}

@(test)
what_a_page_links_is_read :: proc(t: ^testing.T) {
	v, err := json.parse(transmute([]byte)string(`[["/index.html",""],["/classic/","top"],["/a.css",""]]`), allocator = context.temp_allocator)
	testing.expect(t, err == nil, "the page's answer")
	links := site_links(v)
	testing.expect_value(t, len(links), 3)
	testing.expect_value(t, links[1], Site_Link{"/classic/", "top"})
	testing.expect_value(t, site_link_text(links[0]), "/index.html")
	testing.expect_value(t, site_link_text(links[1]), "/classic/#top")
	testing.expect_value(t, len(site_links(nil)), 0)
}

@(test)
an_anchor_is_an_id_of_the_page :: proc(t: ^testing.T) {
	html := `<h2 id="features">x</h2><a href="#main" class="id">`
	testing.expect(t, site_anchor_in(html, "features"), "there")
	testing.expect(t, !site_anchor_in(html, "feature"), "a part of one is not one")
	testing.expect(t, !site_anchor_in(html, "main"), "a link to it is not it")
}

@(test)
a_link_resolves_to_a_file_and_its_anchor :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "tk_site_test_*", context.temp_allocator)
	testing.expect(t, err == nil, "a folder")
	defer os.remove_all(root)
	text := `<p id="here">`
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/index.html", root), transmute([]byte)text) == nil, "a page")
	testing.expect(t, site_link_resolves(root, {"/index.html", ""}), "the page")
	testing.expect(t, site_link_resolves(root, {"/", "here"}), "its anchor, by its folder")
	testing.expect(t, !site_link_resolves(root, {"/index.html", "gone"}), "an anchor it does not have")
	testing.expect(t, !site_link_resolves(root, {"/none.html", ""}), "a page that is not there")
	testing.expect(t, !site_link_resolves(root, {"/../index.html", ""}), "outside")
}

@(test)
pages_are_found_at_every_depth_in_order :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "tk_site_test_*", context.temp_allocator)
	testing.expect(t, err == nil, "a folder")
	defer os.remove_all(root)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/classic/img", root)) == nil, "folders")
	names := [?]string{"index.html", "changelog.html", "style.css", "classic/index.html", "classic/img/a.png"}
	for name in names { testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), []byte{}) == nil, name) }
	pages, ok := site_pages(root)
	testing.expect(t, ok, "listed")
	testing.expect_value(t, strings.join(pages, " ", context.temp_allocator), "changelog.html classic/index.html index.html")
}

@(test)
a_browser_says_its_port_in_a_file :: proc(t: ^testing.T) {
	port, path, ok := site_port_file("51234\n/devtools/browser/abc-def\n")
	testing.expect(t, ok && port == 51234 && path == "/devtools/browser/abc-def", "both lines")
	_, _, ok = site_port_file("51234\r\n/devtools/browser/abc\r\n")
	testing.expect(t, ok, "whatever ends its lines")
	_, _, ok = site_port_file("")
	testing.expect(t, !ok, "not written yet")
	_, _, ok = site_port_file("51234\n")
	testing.expect(t, !ok, "half written")
	_, _, ok = site_port_file("port\n/devtools/browser/abc\n")
	testing.expect(t, !ok, "not a port")
}

// What is found by this mark is killed: an empty one would be found on every command line of the machine.
@(test)
only_a_folder_of_a_run_marks_processes :: proc(t: ^testing.T) {
	testing.expect_value(t, site_run_mark("C:\\Temp/tk_site_check_profile_123"), "tk_site_check_profile_123")
	testing.expect_value(t, site_run_mark("C:\\Temp\\tk_site_check_profile_123"), "tk_site_check_profile_123")
	testing.expect_value(t, site_run_mark("tk_site_check_profile_123"), "tk_site_check_profile_123")
	testing.expect_value(t, site_run_mark("C:/Temp/tk_site_check_profile_123/"), "")
	testing.expect_value(t, site_run_mark("C:/Temp/tk_site_check_profile_"), "")
	testing.expect_value(t, site_run_mark("C:/Users/me/Chrome/User Data"), "")
	testing.expect_value(t, site_run_mark(""), "")
	testing.expect(t, site_processes("") == nil, "no mark, nothing looked for")
}
