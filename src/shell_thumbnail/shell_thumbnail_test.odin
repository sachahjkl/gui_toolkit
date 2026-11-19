package shell_thumbnail

import "core:testing"

@(test)
a_registry_clsid_reads_as_windows_lays_it_out :: proc(t: ^testing.T) {
	g, ok := guid_parse("{e357fccd-a995-4576-B01F-234630154e96}")
	testing.expect(t, ok, "a CLSID of the registry")
	want := GUID{0xe357fccd, 0xa995, 0x4576, {0xb0, 0x1f, 0x23, 0x46, 0x30, 0x15, 0x4e, 0x96}}
	testing.expect_value(t, g, want)
	for bad in ([]string{"", "e357fccd-a995-4576-b01f-234630154e96", "{e357fccd-a995-4576-b01f-234630154e9}", "{e357fccd-a995-4576-b01f-234630154e9g}", "{e357fccd_a995-4576-b01f-234630154e96}"}) {
		_, read := guid_parse(bad)
		testing.expectf(t, !read, "%q is no CLSID", bad)
	}
}

// What the shell gets is opaque BGRA: an opaque pixel keeps its colour, a transparent one is the page's white, half
// between.
@(test)
pixels_are_bgra_on_white :: proc(t: ^testing.T) {
	rgba := []u8{10, 20, 30, 255, 0, 0, 0, 0, 0, 0, 0, 128}
	bgra := make([]u8, len(rgba), context.temp_allocator)
	bgra_on_white(rgba, bgra)
	testing.expect_value(t, [4]u8{bgra[0], bgra[1], bgra[2], bgra[3]}, [4]u8{30, 20, 10, 255})
	testing.expect_value(t, [4]u8{bgra[4], bgra[5], bgra[6], bgra[7]}, [4]u8{255, 255, 255, 255})
	testing.expect_value(t, [4]u8{bgra[8], bgra[9], bgra[10], bgra[11]}, [4]u8{127, 127, 127, 255})
}
