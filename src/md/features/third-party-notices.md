# Third-party notices

`toolbox.third_party_notices` writes a program's `THIRD-PARTY-NOTICES`: the licence texts of what its executable holds
besides its own code. The release puts the file beside the program. A check fails when the file is not what the command
writes.

## What a program states

The toolkit knows its own works (its licence, fonts, icons, Odin's core library, wgpu-native) and its native libraries
(`native_crates(features)`). A program states the rest in its `Project`:

- `crates`: the Cargo manifests of its own Rust libraries (opencode native's `native/ocn_native/Cargo.toml`).
- `works`: what it links or embeds that no crate brings (libghostty-vt, built from Zig sources): a name, a licence id and
  the licence's file in the project or its text.

One file per project. A program's crates and the toolkit's are deduplicated by name and version: a program that builds
the toolkit's crates into its own library (gt_webp, gt_mermaid by path) lists each crate once.

## One file for every target

The crates are those of Linux and Windows together (`NOTICES_TARGETS`, two `--filter-platform`). The file is committed
once, its check runs on every system, and the same file goes beside each build. A file per system would make the check
differ by system and the release would need two files. A Linux archive then lists a Windows-only crate (`windows`): a
licence given that a binary does not need costs a line; one missing breaks the licence.

`cargo metadata` runs without `--offline`. A system's build fetches only its own target's crates, so the other target's
crates are fetched once by the check. `--locked` keeps the versions to the lock.

## Path crates

A crate without a source (a path dependency) is walked for its dependencies but not listed. It is the program's code or
the toolkit's, whose licences the file already gives; neither ships a licence file of its own. A third party's crate kept
in a project is a path crate too: the program states it as a work.

## Refused

- A notices file per system: two files to release, a check that depends on the system.
- `--offline`: on Linux, the Windows crates are missing from a fresh registry and the check fails.
- Listing a path crate: the program's own crates have no licence file, and the program's licence is already named.
