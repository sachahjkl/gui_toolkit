package tk_signing

import "core:testing"

// "wren-dev-license-test-seed-0001!" and the public key Wren's licences are checked with.
@(private = "file") SEED_TEXT :: "d3Jlbi1kZXYtbGljZW5zZS10ZXN0LXNlZWQtMDAwMSE"
@(private = "file") PUBLIC_TEXT :: "NLbdwv2jpoDIMu5pVxyjYBUMEu2Lvfd8StzxR0PGqs8"

@(test)
a_key_reads_and_writes_back :: proc(t: ^testing.T) {
	seed, ok := key_decode("  " + SEED_TEXT + "\n")
	testing.expect(t, ok, "white space around a key is no part of it")
	testing.expect_value(t, string(seed[:]), "wren-dev-license-test-seed-0001!")
	testing.expect_value(t, key_encode(seed[:], context.temp_allocator), SEED_TEXT)
	public, made := public_key_of(seed[:], context.temp_allocator)
	testing.expect(t, made)
	testing.expect_value(t, public, PUBLIC_TEXT)
}

@(test)
a_key_of_another_length_or_alphabet_is_refused :: proc(t: ^testing.T) {
	_, ok := key_decode("AAAA")
	testing.expect(t, !ok, "3 bytes")
	_, ok = key_decode(SEED_TEXT + "=")
	testing.expect(t, !ok, "padding")
	_, ok = key_decode("not a key!")
	testing.expect(t, !ok, "not base64url")
	_, made := public_key_of([]byte{1, 2, 3}, context.temp_allocator)
	testing.expect(t, !made, "a seed is 32 bytes")
}
