# update: signed updates of a program

`import update "gt:update"` (or the relative path of the submodule). Pure Odin (`core:` and the toolkit's nothing else), any
target; the placement of a new program is written for Windows and Linux.

The package is named `tk_update` (the directory is `update`): a program may have an `update` package of its own, and Odin
package names are unique within a build.

It checks what a release publishes and puts the new program in place of the running one. The `Updater` does all of it on a
thread of its own (below); a program with an HTTP client of its own can call the pieces instead.

## The Updater

```odin
u := update.updater_start({
    product = PRODUCT,
    folder  = "https://github.com/me/app/releases/latest/download/",   // the manifest, its .sig and the program are there
    current = APP_VERSION,
    exe     = process.executable_path(),
    news    = proc(user: rawptr) { ui.post(&(^App)(user).state, on_update_news, user) },
    user    = app,
})
update.set_auto(u, .Install)   // from the program's preference: .Off, .Check (offer what it finds) or .Install
...
st := update.status(u)          // on the interface's thread, in on_update_news: phase, version, result, failed, asked, serial
update.check_now(u)             // "Check for updates": its result is said even when nothing is new (st.asked)
update.install_now(u)           // the version on offer (phase Available), when the mode is not .Install
update.updater_stop(u)          // at the end: no news after it; a download under way ends by itself
```

`updater_start` removes what an earlier update left (`remove_leftovers`) and starts a thread that waits. With `check` on, it
checks `first_check` after the start (`FIRST_CHECK`, 20 s: the session's network may come later than the program), then every
`every` (`CHECK_EVERY`, a day); a check that failed is made again after `retry` (`RETRY_AFTER`, an hour). With `install` on,
what a check finds is downloaded and put in place at once. The phases:

| Phase | What it is |
|---|---|
| `Idle` | nothing on offer: the last check found nothing newer (or a 404: no release for this system), or none was made |
| `Checking` | the manifest and its signature are being fetched and checked (`check_release`) |
| `Available` | a newer version, signed and checked: `install_now` installs it |
| `Downloading` | the program is being downloaded (at most the manifest's size) and put in place (`place`) |
| `Installed` | the new program is in place: it runs at the next start. The program restarts when it likes |
| `Managed` | the program runs from `/nix/store`: its package manager updates it, nothing is asked |

`news(user)` is called on the updater's thread at each change, never after `updater_stop` returned: the program posts to its
interface's thread and reads `status` there. `Status.serial` grows at each change, so a program says each result once;
`Status.asked` says the result answers `check_now` or `install_now`, which a program says even when it is "up to date".
Downloads go through `tk_http` (`docs/http.md`): WinHTTP on Windows, libcurl on Linux.

The release publishes the files with `toolbox.update_command` (`docs/toolbox.md`): a manifest and its `.sig` for each
platform, and the program alone under `expected_file_name`.

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

The release tool: `signing.key_decode` (the private key from its secret), `manifest_of(product, data, {version, platform,
channel, published})` (the manifest of the program's bytes: its file name, size and SHA-256 are made from them),
`manifest_bytes`, `sign`. `signing.public_key_of` and `signing.key_encode` make and show a key pair
([signing.md](signing.md)).

## What the program does

1. `check_release(product, manifest, signature, {platform = PLATFORM, channel = channel, current = APP_VERSION, announced =
   tag})` (a `Release_Target`): the signature first (`verify(product, manifest, signature, target)`, which reads its platform
   and channel), then
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
