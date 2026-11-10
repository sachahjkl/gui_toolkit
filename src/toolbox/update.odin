package tk_toolbox

// The signed manifests of a program's releases (the toolkit's update package): what a project's tool runs as its `update`
// command, for its product.
//   update keygen <file>                                  the key pair; <file> is outside any git work tree
//   update pubkey                                         the public key of $UPDATE_SIGNING_KEY
//   update manifest <program> <version> <channel> <out>   a manifest and its .sig, by $UPDATE_SIGNING_KEY ("-": no channel)
//   update verify <manifest> <channel>                    a manifest and its .sig, checked with the product's key

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import update "../update"

// The environment variable of the private key (base64url of its 32 bytes): a secret of the release workflow.
UPDATE_KEY_ENV :: "UPDATE_SIGNING_KEY"

// Runs `update <args>` for `product`. Returns the exit code (2: the words were not understood).
update_command :: proc(product: update.Product, args: []string) -> int {
	what := len(args) > 0 ? args[0] : ""
	switch {
	case what == "keygen" && len(args) == 2:
		return update_keygen(args[1])
	case what == "pubkey" && len(args) == 1:
		seed, ok := update_seed()
		if !ok { return 1 }
		pub, _ := update.public_key_of(seed[:], context.temp_allocator)
		fmt.println(pub)
		return 0
	case what == "manifest" && len(args) == 5:
		why := update_manifest(product, args[1], args[2], args[3] == "-" ? "" : args[3], args[4])
		if why != "" { fmt.eprintfln("update: %s", why); return 1 }
		return 0
	case what == "verify" && len(args) == 3:
		return update_verify(product, args[1], args[2] == "-" ? "" : args[2])
	}
	fmt.eprintln("update: keygen <file> | pubkey | manifest <program> <version> <channel|-> <out.json> | verify <manifest.json> <channel|->")
	return 2
}

// Writes the manifest of `program` (named as a release's program: expected_file_name) at `out`, and its signature at
// `out`.sig, by $UPDATE_SIGNING_KEY. why: "" when both are written.
update_manifest :: proc(product: update.Product, program, version, channel, out: string) -> (why: string) {
	seed, ok := update_seed()
	if !ok { return fmt.tprintf("no update key in %s", UPDATE_KEY_ENV) }
	platform := ""
	for p in update.PLATFORMS {
		if filepath.base(program) == update.expected_file_name(product, version, p, context.temp_allocator) { platform = p }
	}
	if platform == "" { return fmt.tprintf("%s is not named as the program of a release of %s", program, version) }
	data, err := os.read_entire_file(program, context.temp_allocator)
	if err != nil { return fmt.tprintf("cannot read %s", program) }
	y, m, d := time.date(time.now())
	manifest := update.manifest_of(product, data, version, platform, channel, fmt.tprintf("%04d-%02d-%02d", y, int(m), d), context.temp_allocator)
	bytes := update.manifest_bytes(product, manifest, context.temp_allocator)
	sig, signed := update.sign(product, seed[:], bytes, context.temp_allocator)
	if !signed { return "cannot sign" }
	if os.write_entire_file(out, bytes) != nil { return fmt.tprintf("cannot write %s", out) }
	if os.write_entire_file(fmt.tprintf("%s.sig", out), transmute([]u8)sig) != nil { return "cannot write the signature" }
	fmt.printfln("%s: %s %s, %d bytes", out, platform, version, len(data))
	return ""
}

@(private = "file")
update_seed :: proc() -> (seed: [32]byte, ok: bool) {
	text := strings.trim_space(os.get_env(UPDATE_KEY_ENV, context.temp_allocator))
	if text == "" { fmt.eprintfln("update: no update key: set %s", UPDATE_KEY_ENV); return }
	seed, ok = update.seed_decode(text)
	if !ok { fmt.eprintfln("update: %s is not an update private key (32 bytes of base64url)", UPDATE_KEY_ENV) }
	return
}

// Whether `path` is in a git work tree: a signing key there could be committed.
@(private)
in_git_tree :: proc(path: string) -> bool {
	// (the folder's: the key's file does not exist yet, and abs reads the file system)
	dir, err := filepath.abs(filepath.dir(path), context.temp_allocator)
	if err != nil { return true }
	for {
		if os.exists(fmt.tprintf("%s/.git", dir)) { return true }
		parent := filepath.dir(dir)
		if parent == dir { return false }
		dir = parent
	}
}

@(private = "file")
update_keygen :: proc(path: string) -> int {
	if in_git_tree(path) { fmt.eprintfln("update: refusing to write a signing key inside a git work tree: %s", path); return 1 }
	if os.exists(path) { fmt.eprintfln("update: %s exists already: a second key would orphan the releases signed with the first", path); return 1 }
	seed: [32]byte
	crypto.rand_bytes(seed[:])
	text := update.seed_encode(seed[:], context.temp_allocator)
	pub, _ := update.public_key_of(seed[:], context.temp_allocator)
	if os.write_entire_file(path, transmute([]u8)text) != nil { fmt.eprintfln("update: cannot write %s", path); return 1 }
	fmt.println(pub)   // (the public half only: the private one stays in the file)
	return 0
}

@(private = "file")
update_verify :: proc(product: update.Product, file, channel: string) -> int {
	data, e1 := os.read_entire_file(file, context.temp_allocator)
	sig, e2 := os.read_entire_file(fmt.tprintf("%s.sig", file), context.temp_allocator)
	if e1 != nil || e2 != nil { fmt.eprintln("update: cannot read the manifest or its signature"); return 1 }
	platform := ""
	for p in update.PLATFORMS { if filepath.base(file) == update.manifest_name(p, channel, context.temp_allocator) { platform = p } }
	if platform == "" { fmt.eprintfln("update: %s is not named as a manifest of that channel", file); return 1 }
	m, err := update.verify(product, data, strings.trim_space(string(sig)), platform, channel, context.temp_allocator)
	if err != .None { fmt.eprintln(update.error_text(err)); return 1 }
	fmt.printfln("good: %s %s", m.version, m.file)
	return 0
}
