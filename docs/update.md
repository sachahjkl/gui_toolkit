# update: signed updates of a program

`import update "gt:update"` (or the relative path of the submodule). Pure Odin (`core:` and the toolkit's nothing else), any
target; the placement of a new program is written for Windows and Linux.

The package is named `tk_update` (the directory is `update`): a program may have an `update` package of its own, and Odin
package names are unique within a build.

It checks what a release publishes and puts the new program in place of the running one. It does not download: the program
fetches the files with its own HTTP client, and says the result with its own words.

## A product

```odin
PRODUCT :: update.Product{
    name         = "app",                  // the manifest's "product", the stem of the release's file names
    sign_context = "app-update-v1\n",      // what a signature covers before the manifest
    public_key   = "<base64url of the Ed25519 public key>",
}
```

`max_binary` bounds the program a manifest may name (0: `MAX_BINARY`, 256 MiB). The same `Product` signs in the release tool
and checks in the program.

## What a release publishes

For each platform (`PLATFORM_WINDOWS_X64`, `PLATFORM_LINUX_X64`; `PLATFORM` is this program's), and each channel for a
product that has channels:

| File | What it is |
|---|---|
| `manifest_name(platform, channel)` | `update-<platform>[-<channel>].json`: schema, product, channel, version, platform, file, size, SHA-256, date |
| the same name + `.sig` | base64url (no padding) of the Ed25519 signature of `sign_context` + the manifest's bytes |
| `expected_file_name(product, version, platform)` | `<product>-<version>-<platform>`, `.exe` on Windows: the program alone |

A product without channels passes channel `""`: its manifests have no `"channel"`, and a manifest of a channel is refused there.

The release tool: `seed_decode` (the private key from its secret), `manifest_of` (the manifest of the program's bytes),
`manifest_bytes`, `sign`. `public_key_of` and `seed_encode` make and show a key pair.

## What the program does

1. `check_release(product, manifest, signature, PLATFORM, channel, APP_VERSION, announced)`: the signature first (`verify`), then
   what the manifest says (schema, product, channel, platform, version, file name, checksum, size), the version the release
   announced (`""`: none claimed; another one is a replay), and that it is newer (`check_newer`; a version that is not `X.Y.Z`, a
   development build, never updates). `require_signature = false` reads an unsigned manifest, for a channel of the user's own.
2. Download `m.file` (at most `m.size` bytes), then `place(exe, bytes, m)`: the length and the SHA-256 against the manifest
   (`check_binary`), a program of this system (`is_program`), written beside the running one as `<exe>.update`, read back and
   checked again, then put in its place. Windows renames the running program to `<exe>.old` first (a running program can be
   renamed, not overwritten) and puts it back if the new one cannot take its name. Linux makes the new file executable and
   renames it over the old one: the running process keeps its open file.
3. At the next start, `remove_leftovers(exe)` deletes `<exe>.old` and a `<exe>.update` never put in place.

Every refusal is an `Error`; `error_text` says it in a sentence. Nothing is written over the program before every check passed,
and a failure leaves the program as it was.

`version_valid`, `version_compare`, `sha256_hex` and `hex_digest_ok` are the checks' own pieces, for a caller that needs them.

## A program that should not update itself

A program installed by a package manager is updated by it: the program does not call `place` then. A copy that runs from
`/nix/store` is one (the toolkit's `desktop` package says so).
