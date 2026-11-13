# signing: keys as text

`signing` (package `tk_signing`) reads and writes Ed25519 keys as text: base64url without padding, 32 bytes. The packages
`licence` and `update` check signatures with such keys, and their tools make and print them.

```odin
import signing "gt:signing"

seed, ok := signing.key_decode(secret_text)                       // a public key, or the seed of a private one
text := signing.key_encode(seed[:], context.temp_allocator)        // back to its text
public, made := signing.public_key_of(seed[:], context.temp_allocator)   // the public key of a private key's seed
```

- `key_decode(text) -> (key: [32]byte, ok: bool)` ignores white space around the text. It refuses padding, another
  alphabet and another length.
- `key_encode(key, allocator) -> string` writes base64url without padding.
- `public_key_of(seed, allocator) -> (key: string, ok: bool)` is false when `seed` is not 32 bytes.
