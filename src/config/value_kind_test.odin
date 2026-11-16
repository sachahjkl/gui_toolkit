package tk_config

// The value kinds: what each reads, refuses and shows (value_kind.odin).

import "core:testing"

@(private = "file")
VALUE_DEFS := [?]Def{
	{name = "cache.size", kind = .Int, default = {i = 4 << 20}, value_kind = .Size},
	{name = "cache.size_kib", kind = .Int, default = {i = 1024}, value_kind = .Size, unit = .Kibibyte},
	{name = "input.delay", kind = .Int, default = {i = 300}, value_kind = .Duration},
	{name = "net.timeout", kind = .Float, default = {f = 5}, value_kind = .Duration, unit = .Second},
	{name = "update.every", kind = .Int, default = {i = 24}, value_kind = .Duration, unit = .Hour},
	{name = "cache.size_mib", kind = .Int, default = {i = 256}, value_kind = .Size, unit = .Mebibyte},
	{name = "look.glow", kind = .Float, default = {f = 0.45}, value_kind = .Fraction},
	{name = "look.gap", kind = .Float, default = {f = 12}, value_kind = .Length},
	{name = "look.zoom", kind = .Float, default = {f = 1.25}, value_kind = .Factor},
	{name = "look.accent", kind = .String, default = {s = "#e8743b"}, value_kind = .Color},
	{name = "update.url", kind = .String, default = {s = "https://example.org/"}, value_kind = .Address},
	{name = "keys.show", kind = .String, default = {s = "Ctrl+Shift+U"}, value_kind = .Keys},
	{name = "file.last", kind = .String, default = {s = ""}, value_kind = .Path},
}

@(private = "file")
value_prefs :: proc() -> Prefs {
	p := prefs_make()
	register(&p, VALUE_DEFS[:])
	return p
}

// A size typed with a suffix is its count of bytes (a bare letter binary, "MB" decimal), in the setting's unit; one
// of another kind's unit is refused.
@(test)
a_size_typed_with_a_suffix :: proc(t: ^testing.T) {
	p := value_prefs()
	defer prefs_destroy(&p)
	cases := []struct { text: string, bytes: i64 }{
		{"4 MiB", 4 << 20}, {"4M", 4 << 20}, {"4mib", 4 << 20}, {"2 MB", 2_000_000}, {"1.5 KiB", 1536}, {"512", 512},
		{"512 B", 512}, {"1 GiB", 1 << 30},
	}
	for c in cases {
		testing.expectf(t, set_from_string(&p, "cache.size", c.text, .User) == .None, "%q is a size", c.text)
		testing.expectf(t, int_of(&p, "cache.size") == c.bytes, "%q: %d bytes, not %d", c.text, c.bytes, int_of(&p, "cache.size"))
	}
	testing.expect_value(t, set_from_string(&p, "cache.size", "4 ms", .User), Set_Error.Bad_Type)
	testing.expect_value(t, set_from_string(&p, "cache.size", "-1 KiB", .User), Set_Error.Out_Of_Range)
	// (a setting kept in KiB: the suffix converts to its unit)
	testing.expect_value(t, set_from_string(&p, "cache.size_kib", "4 MiB", .User), Set_Error.None)
	testing.expect_value(t, int_of(&p, "cache.size_kib"), 4096)
	testing.expect_value(t, set_from_string(&p, "cache.size_kib", "8", .User), Set_Error.None)
	testing.expect_value(t, int_of(&p, "cache.size_kib"), 8)
}

// A size shows in the largest unit at which it is exact, and what is shown reads back the same.
@(test)
a_size_shows_in_its_largest_exact_unit :: proc(t: ^testing.T) {
	p := value_prefs()
	defer prefs_destroy(&p)
	d := entry(&p, ref_of(&p, "cache.size")).def
	cases := []struct { bytes: i64, shown: string }{
		{4 << 20, "4 MiB"}, {1536, "1.5 KiB"}, {1000, "1000 B"}, {(1 << 30) + 1, "1073741825 B"},
	}
	for c in cases {
		testing.expect_value(t, shown_text(d, {i = c.bytes}), c.shown)
		v, err := parse_value(d, c.shown)
		testing.expectf(t, err == .None && v.i == c.bytes, "%q reads back as %d", c.shown, c.bytes)
	}
	// (97.65625 MiB is not exact to two decimals: the next unit down that is)
	testing.expect_value(t, shown_text(d, {i = 100_000 << 10}), "100000 KiB")
	kib := entry(&p, ref_of(&p, "cache.size_kib")).def
	testing.expect_value(t, shown_text(kib, {i = 4096}), "4 MiB")
}

// A time reads its suffixes into the setting's unit and shows with that unit.
@(test)
a_duration_shows_its_unit :: proc(t: ^testing.T) {
	p := value_prefs()
	defer prefs_destroy(&p)
	d := entry(&p, ref_of(&p, "input.delay")).def
	testing.expect_value(t, shown_text(d, {i = 300}), "300 ms")
	testing.expect_value(t, unit_symbol(d), "ms")
	testing.expect_value(t, set_from_string(&p, "input.delay", "1.5 s", .User), Set_Error.None)
	testing.expect_value(t, int_of(&p, "input.delay"), 1500)
	testing.expect_value(t, set_from_string(&p, "input.delay", "2 min", .User), Set_Error.None)
	testing.expect_value(t, int_of(&p, "input.delay"), 120_000)
	testing.expect_value(t, set_from_string(&p, "input.delay", "250", .User), Set_Error.None)
	testing.expect_value(t, int_of(&p, "input.delay"), 250)
	testing.expect_value(t, set_from_string(&p, "input.delay", "3 KiB", .User), Set_Error.Bad_Type)
	s := entry(&p, ref_of(&p, "net.timeout")).def
	testing.expect_value(t, shown_text(s, {f = 5}), "5 s")
	testing.expect_value(t, set_from_string(&p, "net.timeout", "1500 ms", .User), Set_Error.None)
	testing.expect_value(t, float_of(&p, "net.timeout"), 1.5)
	// (a setting kept in hours: a day is 24 of them, and it shows in hours)
	testing.expect_value(t, set_from_string(&p, "update.every", "2 d", .User), Set_Error.None)
	testing.expect_value(t, int_of(&p, "update.every"), 48)
	testing.expect_value(t, shown_text(entry(&p, ref_of(&p, "update.every")).def, {i = 48}), "48 h")
	// (a size kept in MiB: shown in its largest exact unit, typed in any)
	testing.expect_value(t, set_from_string(&p, "cache.size_mib", "1 GiB", .User), Set_Error.None)
	testing.expect_value(t, int_of(&p, "cache.size_mib"), 1024)
	testing.expect_value(t, shown_text(entry(&p, ref_of(&p, "cache.size_mib")).def, {i = 1024}), "1 GiB")
}

// A share is 0 to 1, typed as a share or in percent, shown in percent; a field's bare number is its percent.
@(test)
a_fraction_is_shown_in_percent :: proc(t: ^testing.T) {
	p := value_prefs()
	defer prefs_destroy(&p)
	d := entry(&p, ref_of(&p, "look.glow")).def
	testing.expect_value(t, shown_text(d, {f = 0.45}), "45 %")
	testing.expect_value(t, shown_text(d, {f = 0.07}), "7 %")
	testing.expect_value(t, set_from_string(&p, "look.glow", "60%", .User), Set_Error.None)
	testing.expect_value(t, float_of(&p, "look.glow"), 0.6)
	testing.expect_value(t, set_from_string(&p, "look.glow", "0.3", .User), Set_Error.None)
	testing.expect_value(t, float_of(&p, "look.glow"), 0.3)
	testing.expect_value(t, set_from_string(&p, "look.glow", "1.2", .User), Set_Error.Out_Of_Range)
	v, err := parse_shown(d, "45")
	testing.expect_value(t, err, Set_Error.None)
	testing.expect_value(t, v.f, 0.45)
}

// A colour that does not parse is refused, and so are an address with no scheme and keys with an empty part; the
// empty text is the program's own for each.
@(test)
a_color_that_does_not_parse_is_refused :: proc(t: ^testing.T) {
	p := value_prefs()
	defer prefs_destroy(&p)
	for bad in ([]string{"red", "#12", "#12345", "#gggggg", "e8743b", "#e8743b0"}) {
		testing.expectf(t, set_from_string(&p, "look.accent", bad, .User) == .Bad_Type, "%q is no colour", bad)
	}
	testing.expect_value(t, string_of(&p, "look.accent"), "#e8743b")
	for good in ([]string{"#fff", "#ffff", "#1a2b3c", "#1A2B3C80", ""}) {
		testing.expectf(t, set_from_string(&p, "look.accent", good, .User) == .None, "%q is a colour", good)
	}
	testing.expect(t, value_hint(entry(&p, ref_of(&p, "look.accent")).def) != "", "a refused colour says what is taken")
	testing.expect_value(t, set_from_string(&p, "update.url", "example.org/updates", .User), Set_Error.Bad_Type)
	testing.expect_value(t, set_from_string(&p, "update.url", "https:", .User), Set_Error.Bad_Type)
	testing.expect_value(t, set_from_string(&p, "update.url", "file:///srv/updates", .User), Set_Error.None)
	testing.expect_value(t, set_from_string(&p, "keys.show", "Ctrl++", .User), Set_Error.None)
	testing.expect_value(t, set_from_string(&p, "keys.show", "Ctrl+K Ctrl+S", .User), Set_Error.None)
	testing.expect_value(t, set_from_string(&p, "keys.show", "Ctrl+ +K", .User), Set_Error.Bad_Type)
	testing.expect_value(t, set_from_string(&p, "keys.show", "Ctrl++Shift", .User), Set_Error.Bad_Type)
	testing.expect_value(t, set_from_string(&p, "file.last", "a\x00b", .User), Set_Error.Bad_Type)
}

// A length and a factor take their own symbol, and no other kind's.
@(test)
a_measure_takes_its_own_symbol :: proc(t: ^testing.T) {
	p := value_prefs()
	defer prefs_destroy(&p)
	testing.expect_value(t, set_from_string(&p, "look.gap", "14 px", .User), Set_Error.None)
	testing.expect_value(t, float_of(&p, "look.gap"), 14)
	testing.expect_value(t, set_from_string(&p, "look.gap", "2 em", .User), Set_Error.Bad_Type)
	testing.expect_value(t, set_from_string(&p, "look.zoom", "1.5x", .User), Set_Error.None)
	testing.expect_value(t, float_of(&p, "look.zoom"), 1.5)
	d := entry(&p, ref_of(&p, "look.zoom")).def
	testing.expect_value(t, shown_text(d, {f = 1.25}), "1.25 ×")
}

// Every kind keeps to the storages it names, and every unit to its kind (what register asserts).
@(test)
the_units_belong_to_their_kinds :: proc(t: ^testing.T) {
	for vk in Value_Kind {
		for u, i in KIND_UNITS[vk] {
			testing.expectf(t, UNITS[u].kind == vk, "%v is a unit of %v", u, vk)
			testing.expectf(t, i > 0 || UNITS[u].symbol != "", "%v has a symbol", u)
		}
		if is_measure(vk) { testing.expectf(t, !value_kind_stores(vk, .String), "%v is a number", vk) }
		name := VALUE_KIND_NAMES[vk]
		back, ok := value_kind_of(name)
		testing.expectf(t, ok && back == vk, "%q names %v", name, vk)
	}
	for u in Unit {
		if u == .None { continue }
		found := false
		for k in KIND_UNITS[UNITS[u].kind] { if k == u { found = true } }
		testing.expectf(t, found, "%v is listed with its kind", u)
	}
}
