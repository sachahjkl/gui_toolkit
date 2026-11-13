// Package tk_update: the signed manifest of a release, what a program checks before it installs an update, and how it puts the
// new program in place of the running one. (Named tk_update: a program may have an `update` package of its own; import it as
// `update "<toolkit>/update"`.) The Updater (updater.odin) does the whole of it on a thread of its own, with tk_http; a program
// with an HTTP client of its own calls the pieces below.
//
// A release publishes, for each platform (and each channel, for a product that has channels), a manifest (a small JSON file) and
// its detached signature:
//
//   update-windows-x64-stable.json      {"schema":1,"product":"app","channel":"stable","version":"1.2.3","platform":"windows-x64",
//                                        "file":"app-1.2.3-windows-x64.exe","size":8877760,"sha256":"<64 hex>","published":"2026-11-05"}
//   update-windows-x64-stable.json.sig  base64url (no padding) of the Ed25519 signature of the product's sign_context + the manifest
//
// A product without channels has no "channel" in its manifests (channel ""). The file of a release is
// `<product>-<version>-<platform>`, with ".exe" on Windows: on Linux it is the program alone, beside any archive.
//
// The public half of the key is built into the program (Product.public_key); the private half signs in the release workflow
// (sign). A program that updates itself:
//
//   1. check_release(product, manifest, signature, its platform, its channel, its version, ...): the signature, then the content
//      (read only once signed), the channel, the version the release announced, and that it is newer (a downgrade replays an old,
//      signed, vulnerable release: the version is in what is signed, and it must grow)
//   2. downloads `m.file`, then place(exe, bytes, m): the length and the SHA-256 against the signed manifest, then the new program
//      written beside the running one and put in its place
//   3. remove_leftovers(exe) at its next start
//
// Anything else is refused with an Error and nothing is installed. The manifest names its file by the one name a release gives
// it (expected_file_name), so a signed manifest cannot point the program at another path.
package tk_update

import "base:runtime"
import "core:crypto/ed25519"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import i18n "../i18n"

// What a program says of itself, the same in the program that checks and in the tool that signs.
Product :: struct {
	name:         string,   // "app": the manifest's "product", and the stem of the release's file names
	sign_context: string,   // what a signature covers before the manifest ("app-update-v1\n"): an update signature is no other message
	public_key:   string,   // base64url of the Ed25519 public key that signs the updates
	max_binary:   i64,      // the largest program a manifest may name (0: MAX_BINARY)
}

SCHEMA :: 1

PLATFORM_WINDOWS_X64 :: "windows-x64"
PLATFORM_LINUX_X64   :: "linux-x64"
PLATFORMS            :: [?]string{PLATFORM_WINDOWS_X64, PLATFORM_LINUX_X64}
// The platform of this program ("": none that updates itself).
PLATFORM :: PLATFORM_WINDOWS_X64 when ODIN_OS == .Windows && ODIN_ARCH == .amd64 else PLATFORM_LINUX_X64 when ODIN_OS == .Linux && ODIN_ARCH == .amd64 else ""

MAX_MANIFEST       :: 16 * 1024   // bytes of a manifest: a real one is about 300
MAX_SIGNATURE_TEXT :: 256         // an Ed25519 signature is 86 characters of base64url
MIN_BINARY         :: 1 << 20     // a program of less than 1 MiB is not one (and a manifest cannot ask for an empty file)
MAX_BINARY         :: 256 << 20   // 256 MiB, unless the product says another

Manifest :: struct {
	channel:   string,   // what it was published for ("": a product without channels)
	version:   string,   // X.Y.Z: digits only (a channel says what is a pre-release)
	platform:  string,   // PLATFORM_WINDOWS_X64, PLATFORM_LINUX_X64
	file:      string,   // the name of the release asset, exactly expected_file_name(product, version, platform)
	sha256:    string,   // 64 lowercase hex digits of the file
	published: string,   // a date, for people
	size:      i64,      // bytes of the file
}

Error :: enum {
	None,
	Too_Long,            // the manifest is empty or larger than MAX_MANIFEST
	Bad_Encoding,        // the signature is not base64url of 64 bytes
	No_Public_Key,
	Bad_Public_Key,
	Bad_Signature,       // not signed by the update key, or the manifest was changed
	Bad_Manifest,        // signed, but not a manifest this program understands
	Wrong_Schema,
	Wrong_Product,
	Wrong_Channel,       // signed, but for another channel than the one asked (or one where none was asked)
	Wrong_Platform,
	Bad_Version,
	Not_Newer,           // the same version, or an older one
	Version_Mismatch,    // a signed manifest, but of another version than the release that carried it
	Bad_File_Name,
	Bad_Hash,
	Bad_Size,
	Size_Mismatch,       // the file's length is not the signed one
	Hash_Mismatch,       // the file's SHA-256 is not the signed one
	Not_A_Program,       // the file is not a program of this platform
	Not_Written,         // the new program could not be written beside the running one
	Not_Written_Whole,   // ... or what was read back is not what was signed
	Not_Moved_Aside,     // Windows: the running program could not be renamed
	Not_Placed,          // the new program could not take the running one's name (the running one is back)
}

error_text :: proc(e: Error) -> string {
	switch e {
	case .None:             return i18n.tr("no error")
	case .Too_Long:         return i18n.tr("the update manifest is empty or too large")
	case .Bad_Encoding:     return i18n.tr("the update signature is not well formed")
	case .No_Public_Key:    return i18n.tr("this build has no update key: it cannot check an update")
	case .Bad_Public_Key:   return i18n.tr("the update key built into this build is not valid")
	case .Bad_Signature:    return i18n.tr("the update is not signed by its publisher (or was altered): refused")
	case .Bad_Manifest:     return i18n.tr("the update manifest is not understood")
	case .Wrong_Schema:     return i18n.tr("the update manifest is of another format")
	case .Wrong_Product:    return i18n.tr("the update manifest is not for this program")
	case .Wrong_Channel:    return i18n.tr("the update is of another channel")
	case .Wrong_Platform:   return i18n.tr("the update is for another platform")
	case .Bad_Version:      return i18n.tr("the update names an invalid version")
	case .Not_Newer:        return i18n.tr("the update is not newer than the installed version")
	case .Version_Mismatch: return i18n.tr("the signed manifest is for another version than the release that carried it")
	case .Bad_File_Name:    return i18n.tr("the update names an unexpected file")
	case .Bad_Hash:         return i18n.tr("the update manifest carries an invalid checksum")
	case .Bad_Size:         return i18n.tr("the update manifest carries an invalid size")
	case .Size_Mismatch:    return i18n.tr("the downloaded file is not the size that was signed: refused")
	case .Hash_Mismatch:    return i18n.tr("the downloaded file does not match its signed checksum: refused")
	case .Not_A_Program:    return i18n.tr("the download is not a program of this system: refused")
	case .Not_Written:      return i18n.tr("the update could not be written beside the program")
	case .Not_Written_Whole: return i18n.tr("the update was not written whole")
	case .Not_Moved_Aside:  return i18n.tr("the running program could not be moved aside")
	case .Not_Placed:       return i18n.tr("the update could not be put in place")
	}
	return i18n.tr("unknown error")
}

manifest_destroy :: proc(m: ^Manifest, allocator := context.allocator) {
	delete(m.channel, allocator); delete(m.version, allocator); delete(m.platform, allocator); delete(m.file, allocator)
	delete(m.sha256, allocator); delete(m.published, allocator)
	m^ = {}
}

////////////////////////////////
// Names and versions

// The name of the release asset of `version` on `platform`: the one a manifest may name.
expected_file_name :: proc(p: Product, version, platform: string, allocator := context.allocator) -> string {
	ext := platform == PLATFORM_WINDOWS_X64 ? ".exe" : ""
	return fmt.aprintf("%s-%s-%s%s", p.name, version, platform, ext, allocator = allocator)
}

// The name of the manifest of `platform` on `channel` ("": none), as a release publishes it: update-<platform>[-<channel>].json.
// Its signature is the same name with ".sig".
manifest_name :: proc(platform, channel: string, allocator := context.allocator) -> string {
	if channel == "" { return fmt.aprintf("update-%s.json", platform, allocator = allocator) }
	return fmt.aprintf("update-%s-%s.json", platform, channel, allocator = allocator)
}

// Whether `data` starts as a program of `platform`: PE on Windows, ELF on Linux.
is_program :: proc(data: []byte, platform: string) -> bool {
	magic: string
	switch platform {
	case PLATFORM_WINDOWS_X64: magic = "MZ"
	case PLATFORM_LINUX_X64:   magic = "\x7fELF"
	case:                      return false
	}
	return len(data) >= len(magic) && string(data[:len(magic)]) == magic
}

// X.Y.Z, three numbers of digits only (at most six each, no sign, no suffix). Never a pre-release or a build label.
version_parts :: proc(v: string) -> (parts: [3]int, ok: bool) {
	fields := strings.split(v, ".", context.temp_allocator)
	if len(fields) != 3 { return {}, false }
	for f, i in fields {
		if len(f) == 0 || len(f) > 6 { return {}, false }
		n := 0
		for c in transmute([]u8)f {
			if c < '0' || c > '9' { return {}, false }
			n = n * 10 + int(c - '0')
		}
		parts[i] = n
	}
	return parts, true
}

version_valid :: proc(v: string) -> bool { _, ok := version_parts(v); return ok }

// -1, 0 or 1; false when either is not X.Y.Z.
version_compare :: proc(a, b: string) -> (order: int, ok: bool) {
	pa, oka := version_parts(a)
	pb, okb := version_parts(b)
	if !oka || !okb { return 0, false }
	for i in 0 ..< 3 {
		if pa[i] < pb[i] { return -1, true }
		if pa[i] > pb[i] { return 1, true }
	}
	return 0, true
}

////////////////////////////////
// Keys and signatures

@(private)
b64_decode :: proc(s: string) -> ([]byte, base64.Error) {
	return base64.decode(s, base64.DEC_URL_TABLE, allocator = context.temp_allocator, options = {.Strict, .No_Padding})
}

public_key_decode :: proc(text: string) -> (key: [ed25519.PUBLIC_KEY_SIZE]byte, ok: bool) {
	b, err := b64_decode(strings.trim_space(text))
	if err != nil || len(b) != ed25519.PUBLIC_KEY_SIZE { return {}, false }
	copy(key[:], b)
	return key, true
}

// The seed of a private key written as base64url (32 bytes).
seed_decode :: proc(text: string) -> (seed: [32]byte, ok: bool) {
	b, err := b64_decode(strings.trim_space(text))
	if err != nil || len(b) != 32 { return {}, false }
	copy(seed[:], b)
	return seed, true
}

seed_encode :: proc(seed: []byte, allocator := context.allocator) -> string {
	return base64.encode(seed, base64.ENC_URL_TABLE, allocator, {.No_Padding})
}

// The public key (base64url) of a private key.
public_key_of :: proc(seed: []byte, allocator := context.allocator) -> (key: string, ok: bool) {
	priv: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&priv, seed) { return "", false }
	defer ed25519.private_key_clear(&priv)
	pub: [ed25519.PUBLIC_KEY_SIZE]byte
	ed25519.private_key_public_bytes(&priv, pub[:])
	return base64.encode(pub[:], base64.ENC_URL_TABLE, allocator, {.No_Padding}), true
}

// The product's sign_context then the manifest: what the signature covers.
signed_bytes :: proc(p: Product, manifest: []byte, allocator := context.temp_allocator) -> []byte {
	out := make([]byte, len(p.sign_context) + len(manifest), allocator)
	copy(out, p.sign_context)
	copy(out[len(p.sign_context):], manifest)
	return out
}

// The detached signature (base64url, no padding) of `manifest` made with the private key `seed`. For the release tool and the tests.
sign :: proc(p: Product, seed: []byte, manifest: []byte, allocator := context.allocator) -> (signature: string, ok: bool) {
	priv: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&priv, seed) { return "", false }
	defer ed25519.private_key_clear(&priv)
	sig: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(&priv, signed_bytes(p, manifest), sig[:])
	return base64.encode(sig[:], base64.ENC_URL_TABLE, allocator, {.No_Padding}), true
}

////////////////////////////////
// The manifest

// The manifest of the release file `data` (the release tool's): its size and SHA-256, its name for `version` on `platform`.
manifest_of :: proc(p: Product, data: []byte, version, platform, channel, published: string, allocator := context.allocator) -> Manifest {
	return {
		channel = strings.clone(channel, allocator), version = strings.clone(version, allocator), platform = strings.clone(platform, allocator),
		file = expected_file_name(p, version, platform, allocator), sha256 = sha256_hex(data, allocator),
		published = strings.clone(published, allocator), size = i64(len(data)),
	}
}

// The bytes of a manifest (a fixed layout: the signature covers exactly these bytes, and a verifier reads whatever they say).
manifest_bytes :: proc(p: Product, m: Manifest, allocator := context.allocator) -> []byte {
	channel := m.channel != "" ? fmt.tprintf(`"channel":"%s",`, m.channel) : ""
	text := fmt.aprintf(
		`{{"schema":%d,"product":"%s",%s"version":"%s","platform":"%s","file":"%s","size":%d,"sha256":"%s","published":"%s"}}` + "\n",
		SCHEMA, p.name, channel, m.version, m.platform, m.file, m.size, m.sha256, m.published, allocator = context.temp_allocator,
	)
	return transmute([]byte)strings.clone(text, allocator)
}

// A manifest checked for what it says, once it is known to be signed or by a caller that made it. Never trust it before the signature.
@(private)
manifest_read :: proc(p: Product, data: []byte, platform, channel: string, allocator: runtime.Allocator) -> (m: Manifest, err: Error) {
	// a manifest is text: no NUL or other control character anywhere in it, whatever a string's parser would make of one (a file name
	// cut short at a NUL is a different name)
	for c in data {
		if (c < ' ' && c != '\n' && c != '\r' && c != '\t') || c == 0x7f { return {}, .Bad_Manifest }
	}
	v, perr := json.parse(data, parse_integers = true, allocator = context.temp_allocator)   // (without it every number is a float: a size is an integer)
	if perr != .None { return {}, .Bad_Manifest }
	obj, is_obj := v.(json.Object)
	if !is_obj { return {}, .Bad_Manifest }

	schema, has_schema := obj["schema"].(json.Integer)
	if !has_schema || schema != SCHEMA { return {}, .Wrong_Schema }
	product, has_product := obj["product"].(json.String)
	if !has_product || string(product) != p.name { return {}, .Wrong_Product }
	chan, _ := obj["channel"].(json.String)   // (none: "", which only a product without channels asks)
	if string(chan) != channel { return {}, .Wrong_Channel }
	plat, has_plat := obj["platform"].(json.String)
	if !has_plat || string(plat) != platform { return {}, .Wrong_Platform }
	version, has_version := obj["version"].(json.String)
	if !has_version || !version_valid(string(version)) { return {}, .Bad_Version }
	file, has_file := obj["file"].(json.String)
	if !has_file || string(file) != expected_file_name(p, string(version), platform, context.temp_allocator) { return {}, .Bad_File_Name }
	sha, has_sha := obj["sha256"].(json.String)
	if !has_sha || !hex_digest_ok(string(sha)) { return {}, .Bad_Hash }
	size, has_size := obj["size"].(json.Integer)
	max_binary := p.max_binary > 0 ? p.max_binary : MAX_BINARY
	if !has_size || size < MIN_BINARY || i64(size) > max_binary { return {}, .Bad_Size }
	published, _ := obj["published"].(json.String)
	if len(published) > 32 { return {}, .Bad_Manifest }
	for c in transmute([]u8)string(published) { if c < ' ' || c == 0x7f { return {}, .Bad_Manifest } }

	m.channel = strings.clone(string(chan), allocator)
	m.version = strings.clone(string(version), allocator)
	m.platform = strings.clone(string(plat), allocator)
	m.file = strings.clone(string(file), allocator)
	m.sha256 = strings.clone(string(sha), allocator)
	m.published = strings.clone(string(published), allocator)
	m.size = i64(size)
	return m, .None
}

// 64 lowercase hex digits.
hex_digest_ok :: proc(s: string) -> bool {
	if len(s) != 64 { return false }
	for c in transmute([]u8)s {
		switch c {
		case '0' ..= '9', 'a' ..= 'f':
		case: return false
		}
	}
	return true
}

// Reads and checks a manifest against the product's public key for `platform` and `channel` ("": none). On success the fields are
// owned by `allocator` (manifest_destroy). Nothing but a manifest signed with the matching private key is read at all.
verify :: proc(p: Product, manifest: []byte, signature, platform, channel: string, allocator := context.allocator) -> (m: Manifest, err: Error) {
	if len(manifest) == 0 || len(manifest) > MAX_MANIFEST { return {}, .Too_Long }
	sig_text := strings.trim_space(signature)
	if sig_text == "" || len(sig_text) > MAX_SIGNATURE_TEXT { return {}, .Bad_Encoding }
	sig, serr := b64_decode(sig_text)
	if serr != nil || len(sig) != ed25519.SIGNATURE_SIZE { return {}, .Bad_Encoding }

	if p.public_key == "" { return {}, .No_Public_Key }
	pk_bytes, pk_ok := public_key_decode(p.public_key)
	if !pk_ok { return {}, .Bad_Public_Key }
	pk: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&pk, pk_bytes[:]) { return {}, .Bad_Public_Key }
	if !ed25519.verify(&pk, signed_bytes(p, manifest, context.temp_allocator), sig) { return {}, .Bad_Signature }

	// signed by the publisher: its content is read only now
	return manifest_read(p, manifest, platform, channel, allocator)
}

// What a program does with the manifest and the signature it downloaded for a release: the signature and the content (verify),
// that it is the version the release announced (a signed manifest of an old version put under a new release is a replay), and
// that it is newer than `current`. `announced` is the version of the release's tag ("" when none is claimed).
// `require_signature` false (a channel of the user's own, where the user turned the signature off) reads the manifest without a
// signature: only the length and the SHA-256 of the file are then checked against it, which proves nothing about who made it.
check_release :: proc(p: Product, manifest: []byte, signature, platform, channel, current, announced: string, allocator := context.allocator, require_signature := true) -> (m: Manifest, err: Error) {
	if require_signature {
		m, err = verify(p, manifest, signature, platform, channel, allocator)
	} else {
		if len(manifest) == 0 || len(manifest) > MAX_MANIFEST { return {}, .Too_Long }
		m, err = manifest_read(p, manifest, platform, channel, allocator)
	}
	if err != .None { return {}, err }
	if announced != "" && m.version != announced { manifest_destroy(&m, allocator); return {}, .Version_Mismatch }
	if e := check_newer(m, current); e != .None { manifest_destroy(&m, allocator); return {}, e }
	return m, .None
}

// Whether `m` is an update for a program of version `current` (X.Y.Z): strictly newer. An installed version that is not X.Y.Z
// (a development build) is refused too: such a build is updated by hand.
check_newer :: proc(m: Manifest, current: string) -> Error {
	order, ok := version_compare(m.version, current)
	if !ok { return .Bad_Version }
	if order <= 0 { return .Not_Newer }
	return .None
}

////////////////////////////////
// The file

sha256_hex :: proc(data: []byte, allocator := context.allocator) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	digest: [sha2.DIGEST_SIZE_256]byte
	sha2.final(&ctx, digest[:])
	HEX := "0123456789abcdef"
	out := make([]byte, 64, allocator)
	for b, i in digest {
		out[i * 2] = HEX[b >> 4]
		out[i * 2 + 1] = HEX[b & 0xf]
	}
	return string(out)
}

// The downloaded bytes against the signed manifest: the length first, then the SHA-256. Both must match.
check_binary :: proc(m: Manifest, data: []byte) -> Error {
	if i64(len(data)) != m.size { return .Size_Mismatch }
	if sha256_hex(data, context.temp_allocator) != m.sha256 { return .Hash_Mismatch }
	return .None
}

// `exe` (the running program) becomes the program of `data`, checked against `m` first: written beside it as <exe>.update, read
// back and checked again, then put in its place. On Windows a running program can be renamed, not overwritten: it goes aside as
// <exe>.old (remove_leftovers deletes it at the next start), and if the new one cannot take its name it comes back. On Linux the
// new file is made executable and renamed over it: the running process keeps its open file. A failure leaves the program as it was.
place :: proc(exe: string, data: []byte, m: Manifest) -> Error {
	if e := check_binary(m, data); e != .None { return e }
	if !is_program(data, m.platform) || m.platform != PLATFORM { return .Not_A_Program }
	next := fmt.tprintf("%s.update", exe)
	if os.write_entire_file(next, data) != nil { _ = os.remove(next); return .Not_Written }
	back, err := os.read_entire_file(next, context.temp_allocator)
	if err != nil || check_binary(m, back) != .None { _ = os.remove(next); return .Not_Written_Whole }
	when ODIN_OS == .Windows {
		old := fmt.tprintf("%s.old", exe)
		_ = os.remove(old)
		if os.rename(exe, old) != nil { _ = os.remove(next); return .Not_Moved_Aside }
		if os.rename(next, exe) != nil {
			_ = os.rename(old, exe)   // (back as it was)
			_ = os.remove(next)
			return .Not_Placed
		}
	} else {
		_ = os.chmod(next, os.Permissions_Default_File | {.Execute_User, .Execute_Group, .Execute_Other})
		if os.rename(next, exe) != nil { _ = os.remove(next); return .Not_Placed }
	}
	return .None
}

// What an update left beside `exe`: the program it replaced (Windows: <exe>.old) and a new one never put in place (<exe>.update).
// At the start of the program, before anything else.
remove_leftovers :: proc(exe: string) {
	_ = os.remove(fmt.tprintf("%s.old", exe))
	_ = os.remove(fmt.tprintf("%s.update", exe))
}
