// Package tk_signing: Ed25519 keys as text. A public key, or the 32-byte seed of a private one, is written as base64url
// without padding: the form a program builds in (a product's public key), a release workflow keeps in a secret, and
// the licence and update packages read. (Named tk_signing: import it as `signing "<toolkit>/signing"`.)
package tk_signing

import "core:crypto/ed25519"
import "core:encoding/base64"
import "core:strings"

// A key (public, or the seed of a private one) of base64url text: its 32 bytes. White space around it is ignored.
key_decode :: proc(text: string) -> (key: [32]byte, ok: bool) {
	b, err := base64.decode(strings.trim_space(text), base64.DEC_URL_TABLE, allocator = context.temp_allocator, options = {.Strict, .No_Padding})
	if err != nil || len(b) != 32 { return {}, false }
	copy(key[:], b)
	return key, true
}

// The base64url text of a key (no padding).
key_encode :: proc(key: []byte, allocator := context.allocator) -> string {
	return base64.encode(key, base64.ENC_URL_TABLE, allocator, {.No_Padding})
}

// The public key (base64url) of a private key's 32-byte seed. False: `seed` is not 32 bytes.
public_key_of :: proc(seed: []byte, allocator := context.allocator) -> (key: string, ok: bool) {
	private_key: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&private_key, seed) { return "", false }
	defer ed25519.private_key_clear(&private_key)
	public_bytes: [ed25519.PUBLIC_KEY_SIZE]byte
	ed25519.private_key_public_bytes(&private_key, public_bytes[:])
	return key_encode(public_bytes[:], allocator), true
}
