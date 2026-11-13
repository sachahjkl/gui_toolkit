package tk_licence

import "core:fmt"
import "core:strings"
import "core:testing"
import signing "../signing"

// A sample product, with the same constants as the worker's tests (licence-worker/test/fixtures/sample-product.json).
@(private = "file")
SAMPLE :: Product{
	name           = "sample",
	title          = "Sample",
	version_tag    = "SAMPLE1",
	sign_context   = "sample-licence-v1\n",
	file_extension = ".samplelicence",
	public_key     = OTHER_PUBLIC_KEY,
	dev_public_key = DEV_PUBLIC_KEY,
	editions       = {0 = {id = "supporter", title = "Supporter"}, 1 = {id = "patron", title = "Patron"}},
}

// The sample's development pair, public on purpose ("gt-licence-sample-dev-seed-0001!"), and a second pair.
@(private = "file") DEV_SEED         :: "Z3QtbGljZW5jZS1zYW1wbGUtZGV2LXNlZWQtMDAwMSE"
@(private = "file") DEV_PUBLIC_KEY   :: "zHs7wxUEefqH37-vN5cKoTnZOCCFBnmcoQGrw6i3UAk"
@(private = "file") OTHER_SEED       :: "Z3QtbGljZW5jZS1vdGhlci1zYW1wbGUtc2VlZC0wMiE"
@(private = "file") OTHER_PUBLIC_KEY :: "V91HlwwFnqUMQs402LFbpG21HljQ6QrKRpc81zDVXLo"

// What the worker signs for the sample's fields (licence-worker/test/cross.test.ts asserts the same text).
@(private = "file")
SAMPLE_VECTOR :: "SAMPLE1.eyJwcm9kdWN0Ijoic2FtcGxlIiwiZWRpdGlvbiI6InN1cHBvcnRlciIsIm5hbWUiOiJKZWFubmUgRHVwb250IiwiZW1haWwiOiJqZWFubmVAZXhhbXBsZS5vcmciLCJkYXRlIjoiMjAyNi0xMC0yMiIsIm9yZGVyIjoiU0FNUExFLTAwMDEifQ._1saqlbzGri15FPx4Bcul5NC2IDUxv6xaNGLCBqKAvayX9yZK_zvwfSYbwGHo-2Vt279B3lZRABDIQniVgzzCQ"
// The same fields with two years of updates.
@(private = "file")
SAMPLE_VECTOR_UPDATES :: "SAMPLE1.eyJwcm9kdWN0Ijoic2FtcGxlIiwiZWRpdGlvbiI6InN1cHBvcnRlciIsIm5hbWUiOiJKZWFubmUgRHVwb250IiwiZW1haWwiOiJqZWFubmVAZXhhbXBsZS5vcmciLCJkYXRlIjoiMjAyNi0xMC0yMiIsIm9yZGVyIjoiU0FNUExFLTAwMDEiLCJ1cGRhdGVzX3VudGlsIjoiMjAyOC0xMC0yMiJ9.umls9XeZduIng1jj-slTJ3SARm60Je9TJngrYRDjkbYkVHK1DgcBa3rlI152izIAJBHbHEJZmOZS7NyK9GiiCw"

// Wren's licences, as Wren's own package and worker make them: the generic package reads and makes the very same text.
@(private = "file")
WREN :: Product{name = "wren", version_tag = "WREN1", sign_context = "wren-license-v1\n", file_extension = ".wrenlicense",
	public_key = "NLbdwv2jpoDIMu5pVxyjYBUMEu2Lvfd8StzxR0PGqs8", editions = {0 = {id = "supporter", title = "Supporter"}, 1 = {id = "patron", title = "Patron"}}}
@(private = "file") WREN_DEV_SEED :: "d3Jlbi1kZXYtbGljZW5zZS10ZXN0LXNlZWQtMDAwMSE"   // "wren-dev-license-test-seed-0001!"
@(private = "file")
WREN_VECTOR :: "WREN1.eyJwcm9kdWN0Ijoid3JlbiIsImVkaXRpb24iOiJzdXBwb3J0ZXIiLCJuYW1lIjoiSmVhbm5lIER1cG9udCIsImVtYWlsIjoiamVhbm5lQGV4YW1wbGUub3JnIiwiZGF0ZSI6IjIwMjYtMTAtMjIiLCJvcmRlciI6IldSRU4tMDAwMSJ9.dws8E6hZSTQQ9ONP84BMYChi5P9LRY9APBq3zukrwi8i-sPguPrDWM7aJEVrDv0SHGRT6WrFhxD6k0kWQrRaBQ"

@(private = "file")
sample :: proc() -> Licence {
	return {edition = "supporter", name = "Jeanne Dupont", email = "jeanne@example.org", date = "2026-10-22", order = "SAMPLE-0001"}
}

@(private = "file")
seed_of :: proc(text: string) -> [32]byte {
	s, ok := signing.key_decode(text)
	assert(ok)
	return s
}

@(private = "file")
dev_text :: proc(l: Licence, p := SAMPLE) -> string {
	s := seed_of(DEV_SEED)
	t, ok := sign(p, s[:], l, context.temp_allocator)
	assert(ok)
	return t
}

@(test)
signature_is_the_workers :: proc(t: ^testing.T) {
	testing.expect_value(t, dev_text(sample()), SAMPLE_VECTOR)
	ws := seed_of(WREN_DEV_SEED)
	w, _ := sign(WREN, ws[:], {edition = "supporter", name = "Jeanne Dupont", email = "jeanne@example.org", date = "2026-10-22", order = "WREN-0001"}, context.temp_allocator)
	testing.expect_value(t, w, WREN_VECTOR)
	lic, err := verify(WREN, WREN_VECTOR, allocator = context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, lic.order, "WREN-0001")
}

@(test)
valid_licence_verifies :: proc(t: ^testing.T) {
	text := dev_text(sample())
	testing.expect(t, strings.has_prefix(text, "SAMPLE1."))
	lic, err := verify(SAMPLE, text, DEV_PUBLIC_KEY)
	defer licence_destroy(&lic)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, lic.product, "sample")
	testing.expect_value(t, lic.edition, "supporter")
	testing.expect_value(t, lic.name, "Jeanne Dupont")
	testing.expect_value(t, lic.email, "jeanne@example.org")
	testing.expect_value(t, lic.date, "2026-10-22")
	testing.expect_value(t, lic.order, "SAMPLE-0001")
	testing.expect_value(t, lic.updates_until, "")
	testing.expect(t, edition_known(SAMPLE, lic.edition))
}

@(test)
non_ascii_names_survive :: proc(t: ^testing.T) {
	l := sample()
	l.name = "Zoé \"Zaza\" Müller \\ 日本"
	lic, err := verify(SAMPLE, dev_text(l), DEV_PUBLIC_KEY)
	defer licence_destroy(&lic)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, lic.name, l.name)
}

@(test)
editions_known_and_unknown :: proc(t: ^testing.T) {
	l := sample()
	l.edition = "patron"
	lic, err := verify(SAMPLE, dev_text(l), DEV_PUBLIC_KEY)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, edition_rank(SAMPLE, lic.edition), 1)
	testing.expect_value(t, edition_title(SAMPLE, lic.edition), "Patron")
	licence_destroy(&lic)
	// an edition this build does not know is read all the same (an older build keeps working with newer licences)
	l.edition = "founder"
	lic, err = verify(SAMPLE, dev_text(l), DEV_PUBLIC_KEY)
	defer licence_destroy(&lic)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, !edition_known(SAMPLE, lic.edition))
	testing.expect_value(t, edition_rank(SAMPLE, lic.edition), -1)
	testing.expect_value(t, edition_title(SAMPLE, lic.edition), "founder")
}

@(test)
altered_payload_is_refused :: proc(t: ^testing.T) {
	text := dev_text(sample())
	parts := strings.split(text, ".", context.temp_allocator)
	l := sample()
	l.edition = "patron"
	oparts := strings.split(dev_text(l), ".", context.temp_allocator)
	// the payload of one licence with the signature of another
	forged := strings.join({parts[0], oparts[1], parts[2]}, ".", context.temp_allocator)
	_, err := verify(SAMPLE, forged, DEV_PUBLIC_KEY)
	testing.expect_value(t, err, Error.Bad_Signature)
	// one character of the payload changed
	b := transmute([]byte)strings.clone(text, context.temp_allocator)
	i := len("SAMPLE1.") + 10
	b[i] = b[i] == 'A' ? 'B' : 'A'
	_, err = verify(SAMPLE, string(b), DEV_PUBLIC_KEY)
	testing.expect(t, err == .Bad_Signature || err == .Bad_Payload || err == .Bad_Encoding, "a changed payload never passes")
	// one character of the signature changed
	b = transmute([]byte)strings.clone(text, context.temp_allocator)
	b[len(b) - 5] = b[len(b) - 5] == 'A' ? 'B' : 'A'
	_, err = verify(SAMPLE, string(b), DEV_PUBLIC_KEY)
	testing.expect_value(t, err, Error.Bad_Signature)
}

@(test)
other_key_is_refused :: proc(t: ^testing.T) {
	s := seed_of(OTHER_SEED)
	text, ok := sign(SAMPLE, s[:], sample(), context.temp_allocator)
	testing.expect(t, ok)
	_, err := verify(SAMPLE, text, DEV_PUBLIC_KEY)
	testing.expect_value(t, err, Error.Bad_Signature)
	// the product's own key, when none is given
	lic, err2 := verify(SAMPLE, text)
	defer licence_destroy(&lic)
	testing.expect_value(t, err2, Error.None)
}

@(test)
foreign_product_is_refused :: proc(t: ^testing.T) {
	s := seed_of(DEV_SEED)
	text, _ := sign_payload(SAMPLE, s[:], transmute([]byte)string(`{"product":"other","edition":"supporter","name":"x"}`), context.temp_allocator)
	_, err := verify(SAMPLE, text, DEV_PUBLIC_KEY)
	testing.expect_value(t, err, Error.Wrong_Product)
	// no product at all
	text, _ = sign_payload(SAMPLE, s[:], transmute([]byte)string(`{"edition":"supporter","name":"x"}`), context.temp_allocator)
	_, err = verify(SAMPLE, text, DEV_PUBLIC_KEY)
	testing.expect_value(t, err, Error.Wrong_Product)
	// another product's tag and context: not this product's format, whatever the key
	w := seed_of(WREN_DEV_SEED)
	text, _ = sign(WREN, w[:], sample(), context.temp_allocator)
	_, err = verify(SAMPLE, text, WREN.public_key)
	testing.expect_value(t, err, Error.Bad_Format)
}

@(test)
signature_covers_the_context :: proc(t: ^testing.T) {
	// the same key and payload, signed under another product's context, is not a licence of this one
	s := seed_of(DEV_SEED)
	other := SAMPLE
	other.sign_context = "sample-update-v1\n"
	text, _ := sign(other, s[:], sample(), context.temp_allocator)
	_, err := verify(SAMPLE, text, DEV_PUBLIC_KEY)
	testing.expect_value(t, err, Error.Bad_Signature)
}

@(test)
extra_fields_are_ignored :: proc(t: ^testing.T) {
	s := seed_of(DEV_SEED)
	text, _ := sign_payload(SAMPLE, s[:], transmute([]byte)string(`{"product":"sample","edition":"supporter","name":"N","future":{"a":[1,2]},"order":"7"}`), context.temp_allocator)
	lic, err := verify(SAMPLE, text, DEV_PUBLIC_KEY)
	defer licence_destroy(&lic)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, lic.name, "N")
	testing.expect_value(t, lic.email, "")
	testing.expect_value(t, lic.order, "7")
}

@(test)
signed_but_not_a_licence :: proc(t: ^testing.T) {
	s := seed_of(DEV_SEED)
	long := strings.repeat("x", MAX_FIELD + 1, context.temp_allocator)
	cases := []string{`not json`, `[1,2]`, `"x"`, `{"product":"sample","name":12}`,
		strings.concatenate({`{"product":"sample","name":"`, long, `"}`}, context.temp_allocator),
		`{"product":"sample","updates_until":"soon"}`}
	for p in cases {
		text, _ := sign_payload(SAMPLE, s[:], transmute([]byte)p, context.temp_allocator)
		_, err := verify(SAMPLE, text, DEV_PUBLIC_KEY)
		testing.expectf(t, err == .Bad_Payload, "%s: %v", p, err)
	}
}

@(test)
text_forms :: proc(t: ^testing.T) {
	text := dev_text(sample())
	// wrapped, indented, commented, quoted: all the same licence
	wrapped := strings.builder_make(context.temp_allocator)
	strings.write_string(&wrapped, "# Sample licence of Jeanne Dupont\r\n# order SAMPLE-0001\r\n")
	for i := 0; i < len(text); i += 60 {
		strings.write_string(&wrapped, "   ")
		strings.write_string(&wrapped, text[i:min(i + 60, len(text))])
		strings.write_string(&wrapped, "\r\n")
	}
	lic, err := verify(SAMPLE, strings.to_string(wrapped), DEV_PUBLIC_KEY)
	testing.expect_value(t, err, Error.None)
	licence_destroy(&lic)
	lic, err = verify(SAMPLE, strings.concatenate({"\"", text, "\"\n"}, context.temp_allocator), DEV_PUBLIC_KEY)
	testing.expect_value(t, err, Error.None)
	licence_destroy(&lic)
	// the file the tool writes reads as the key
	lic, err = verify(SAMPLE, file_text(SAMPLE, sample(), text, "Open this file with Sample.", context.temp_allocator), DEV_PUBLIC_KEY)
	testing.expect_value(t, err, Error.None)
	licence_destroy(&lic)

	expect :: proc(t: ^testing.T, text: string, want: Error, loc := #caller_location) {
		_, err := verify(SAMPLE, text, DEV_PUBLIC_KEY, context.temp_allocator)
		testing.expect_value(t, err, want, loc = loc)
	}
	expect(t, "", .Empty)
	expect(t, "  \n# only a comment\n", .Empty)
	expect(t, "hello", .Bad_Format)
	expect(t, "SAMPLE2.aaaa.bbbb", .Bad_Format)
	expect(t, "SAMPLE1.aaaa", .Bad_Format)
	expect(t, "SAMPLE1.aaaa.bbbb.cccc", .Bad_Format)
	expect(t, "SAMPLE1..bbbb", .Bad_Format)
	expect(t, "SAMPLE1.a!a.bbbb", .Bad_Encoding)
	expect(t, "SAMPLE1.aaaa.bbbb", .Bad_Signature)   // (valid base64url of a wrong length of signature)
	expect(t, strings.repeat("A", MAX_TEXT + 1, context.temp_allocator), .Too_Long)
}

@(test)
file_names_carry_no_line_break :: proc(t: ^testing.T) {
	l := sample()
	l.name = "Eve\nSAMPLE1.forged.key"
	text := dev_text(l)
	file := file_text(SAMPLE, l, text, allocator = context.temp_allocator)
	testing.expect(t, strings.has_prefix(file, "# Sample licence (Supporter) for Eve SAMPLE1.forged.key\n"))
	lic, err := verify(SAMPLE, file, DEV_PUBLIC_KEY, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, lic.name, l.name)
}

@(test)
public_key_problems :: proc(t: ^testing.T) {
	text := dev_text(sample())
	none := SAMPLE
	none.public_key = ""
	_, err := verify(none, text)
	testing.expect_value(t, err, Error.No_Public_Key)
	_, err = verify(SAMPLE, text, "not a key!")
	testing.expect_value(t, err, Error.Bad_Public_Key)
	_, err = verify(SAMPLE, text, "AAAA")
	testing.expect_value(t, err, Error.Bad_Public_Key)
}

@(test)
dev_public_key_matches_its_seed :: proc(t: ^testing.T) {
	s := seed_of(DEV_SEED)
	k, ok := signing.public_key_of(s[:], context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, k, DEV_PUBLIC_KEY)
	o := seed_of(OTHER_SEED)
	k, _ = signing.public_key_of(o[:], context.temp_allocator)
	testing.expect_value(t, k, OTHER_PUBLIC_KEY)
	w := seed_of(WREN_DEV_SEED)
	k, _ = signing.public_key_of(w[:], context.temp_allocator)
	testing.expect_value(t, k, WREN.public_key)
}

@(test)
years_of_updates :: proc(t: ^testing.T) {
	p := SAMPLE
	// off: no field, every version covered
	testing.expect_value(t, dev_text(sample(), p), SAMPLE_VECTOR)
	testing.expect(t, covers(p, sample(), "2099-01-01"))

	// on: the field is signed, and is the worker's
	p.update_years = 2
	text := dev_text(sample(), p)
	testing.expect_value(t, text, SAMPLE_VECTOR_UPDATES)
	lic, err := verify(p, text, DEV_PUBLIC_KEY, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, lic.updates_until, "2028-10-22")
	testing.expect(t, covers(p, lic, "2028-10-22"))
	testing.expect(t, !covers(p, lic, "2028-10-23"))
	testing.expect(t, covers(p, lic, ""))
	// what is signed holds, whatever the product says later
	p.update_years = 5
	testing.expect(t, !covers(p, lic, "2029-01-01"))

	// a licence with no field, read by a product that counts: from its date, or from updates_from when bought before it
	p.update_years = 2
	p.updates_from = "2027-03-01"
	testing.expect_value(t, updates_until_of(p, sample()), "2029-03-01")
	late := sample()
	late.date = "2027-06-30"
	testing.expect_value(t, updates_until_of(p, late), "2029-06-30")
	// a leap day
	leap := sample()
	leap.date = "2028-02-29"
	p.updates_from = ""
	testing.expect_value(t, updates_until_of(p, leap), "2030-02-28")
	testing.expect_value(t, date_add_years("2028-02-29", 4), "2032-02-29")
	testing.expect_value(t, date_add_years("2028-2-29", 1), "")
	testing.expect(t, !date_valid("2028/02/29"))
}

// One licence for sale: the file's first line names no edition, and the key still carries it.
@(test)
a_single_edition_is_not_named :: proc(t: ^testing.T) {
	p := SAMPLE
	p.editions = {0 = {id = "supporter", title = "Supporter"}}
	l := sample()
	file := file_text(p, l, dev_text(l), allocator = context.temp_allocator)
	testing.expectf(t, strings.has_prefix(file, fmt.tprintf("# Sample licence for %s\n", l.name)), "%q", file)
	lic, err := verify(p, file, DEV_PUBLIC_KEY, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, lic.edition, l.edition)
}
