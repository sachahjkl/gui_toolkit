// Package tk_licence: a program's paid licence, checked offline. A licence is a signed statement: a product, an edition, a
// name, an e-mail address, a date and an order number, signed with Ed25519 by the seller's private key (the project's tool:
// toolbox.licence_commands, or the shop's worker: licence-worker/). The program carries the public half (Product.public_key)
// and checks the signature itself, with no network. (Named tk_licence: a program may have a `licence` package of its own.)
//
// Text form (what is pasted, or kept in a file of the product's extension; white space, quotes and lines that start with
// '#' are ignored):
//
//     <VERSION_TAG>.<payload>.<signature>
//
// payload: base64url, no padding, of the JSON {"product":..,"edition":..,"name":..,"email":..,"date":..,"order":..} and,
// for a product that counts its years of updates, "updates_until". Fields it does not know are ignored.
// signature: base64url, no padding, of the Ed25519 signature over Product.sign_context followed by the payload's bytes
// exactly as they are in the text (nothing to canonicalize; a key signed for another use cannot pass for a licence).
//
// The words said to the user are the program's: error_text names no product. The file of a licence and its store are in
// store.odin (read and written off the interface's thread).
package tk_licence

import "base:runtime"
import "core:crypto/ed25519"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

// Longest key text taken, and longest value of a field: a licence is a few hundred bytes.
MAX_TEXT  :: 8192
MAX_FIELD :: 256
// The editions a product may sell.
MAX_EDITIONS :: 4

// One edition: its id in the payload ("supporter") and its name for people ("Supporter").
Edition_Def :: struct {
	id:    string,
	title: string,
}

// What a program's licence is, the same in the program that checks it, the tool that issues it and the shop's worker.
// A constant of the program (its strings live as long as it).
Product :: struct {
	name:           string,   // "app": the payload's "product"; a licence of another product is refused
	title:          string,   // "App": the program's name, in the comment lines of a licence file
	version_tag:    string,   // "APP1": the text's first part
	sign_context:   string,   // "app-licence-v1\n": what a signature covers before the payload
	file_extension: string,   // ".applicence": the file a licence is kept and sent in
	public_key:     string,   // base64url of the Ed25519 public key ("": none made yet: no licence is accepted)
	dev_public_key: string,   // a development pair's public key, public on purpose; accepted only where asked (Store_Options.accept_dev)
	editions:       [MAX_EDITIONS]Edition_Def,   // in the order of their rank (the last is the highest); empty ids end the list
	update_years:   int,      // 0: a licence covers every version; N: the versions released until N years after its start
	updates_from:   string,   // with update_years: a licence bought before this day ("YYYY-MM-DD") counts its years from it
}

Licence :: struct {
	product:       string,
	edition:       string,   // an id of Product.editions (a newer one a build does not know is still read: edition_known)
	name:          string,
	email:         string,
	date:          string,   // the day it was issued, "2026-10-22"
	order:         string,   // the order number
	updates_until: string,   // "": not counted; else the last release day its updates cover ("2028-10-22")
}

Error :: enum u8 {
	None,
	Empty,
	Too_Long,
	Bad_Format,        // not <VERSION_TAG>.<payload>.<signature>
	Bad_Encoding,      // not base64url
	Bad_Payload,       // signed, but not the JSON of a licence
	Wrong_Product,     // signed for another program
	Bad_Signature,     // altered, or signed with another key
	No_Public_Key,     // this build has no key to check licences with
	Bad_Public_Key,
	Not_Read,          // the file could not be read (the store)
	Not_Written,       // the licence could not be kept (the store)
}

// Neutral words for an Error; a program that names itself words its own.
error_text :: proc(e: Error) -> string {
	switch e {
	case .None:           return ""
	case .Empty:          return "The licence is empty."
	case .Too_Long:       return "That is too long to be a licence key."
	case .Bad_Format:     return "That is not a licence key of this program: it must start with its tag and have three parts separated by dots."
	case .Bad_Encoding:   return "The licence key is damaged: it is not valid base64url text."
	case .Bad_Payload:    return "The licence key is damaged: its content is not a licence."
	case .Wrong_Product:  return "This licence is for another product."
	case .Bad_Signature:  return "The signature does not match: the key was altered or was not issued by the seller."
	case .No_Public_Key:  return "This build has no key to check licences with."
	case .Bad_Public_Key: return "The public key for licences is not valid."
	case .Not_Read:       return "The licence file could not be read."
	case .Not_Written:    return "The licence could not be saved."
	}
	return ""
}

licence_destroy :: proc(l: ^Licence, allocator := context.allocator) {
	delete(l.product, allocator); delete(l.edition, allocator); delete(l.name, allocator); delete(l.email, allocator)
	delete(l.date, allocator); delete(l.order, allocator); delete(l.updates_until, allocator)
	l^ = {}
}

////////////////////////////////
// Editions

// Whether `id` is an edition of the product.
edition_known :: proc(p: Product, id: string) -> bool {
	return edition_rank(p, id) >= 0
}

// The rank of `id` in Product.editions (-1: not one of them).
edition_rank :: proc(p: Product, id: string) -> int {
	for e, i in p.editions {
		if e.id == "" { break }
		if e.id == id { return i }
	}
	return -1
}

// The name of edition `id` for people: its title, or the id itself for an edition this build does not know.
edition_title :: proc(p: Product, id: string) -> string {
	for e in p.editions {
		if e.id == "" { break }
		if e.id == id { return e.title != "" ? e.title : e.id }
	}
	return id
}

////////////////////////////////
// The text

// The text with its white space removed and the '#' comment lines dropped (a key wrapped in an e-mail or a file).
// Surrounding quotes, as a copied value may have, are removed too.
normalize :: proc(text: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "#") { continue }
		for c in transmute([]byte)l {
			if c != ' ' && c != '\t' && c != '"' && c != '\'' { strings.write_byte(&sb, c) }
		}
	}
	return strings.to_string(sb)
}

@(private)
b64_decode :: proc(s: string) -> ([]byte, base64.Error) {
	return base64.decode(s, base64.DEC_URL_TABLE, allocator = context.temp_allocator, options = {.Strict, .No_Padding})
}

// A key (public, or the seed of a private one) of base64url text: its 32 bytes.
key_decode :: proc(text: string) -> (key: [32]byte, ok: bool) {
	b, err := b64_decode(strings.trim_space(text))
	if err != nil || len(b) != 32 { return {}, false }
	copy(key[:], b)
	return key, true
}

key_encode :: proc(key: []byte, allocator := context.allocator) -> string {
	return base64.encode(key, base64.ENC_URL_TABLE, allocator, {.No_Padding})
}

// The public key (base64url) of a private key's 32-byte seed.
public_key_of :: proc(seed: []byte, allocator := context.allocator) -> (key: string, ok: bool) {
	priv: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&priv, seed) { return "", false }
	defer ed25519.private_key_clear(&priv)
	pub: [ed25519.PUBLIC_KEY_SIZE]byte
	ed25519.private_key_public_bytes(&priv, pub[:])
	return key_encode(pub[:], allocator), true
}

// Reads and checks a licence of `p` against `public_key` (base64url text of the 32 bytes; "": the product's). On success
// the fields are owned by `allocator` (licence_destroy). Nothing but a signature made with the matching private key passes.
verify :: proc(p: Product, text: string, public_key := "", allocator := context.allocator) -> (lic: Licence, err: Error) {
	key := public_key != "" ? public_key : p.public_key
	if len(text) > MAX_TEXT { return {}, .Too_Long }
	t := normalize(text, context.temp_allocator)
	if t == "" { return {}, .Empty }
	parts := strings.split(t, ".", context.temp_allocator)
	if len(parts) != 3 || parts[0] != p.version_tag || parts[1] == "" || parts[2] == "" { return {}, .Bad_Format }

	payload, e1 := b64_decode(parts[1])
	sig, e2 := b64_decode(parts[2])
	if e1 != nil || e2 != nil { return {}, .Bad_Encoding }

	if key == "" { return {}, .No_Public_Key }
	pk_bytes, pk_ok := key_decode(key)
	if !pk_ok { return {}, .Bad_Public_Key }
	pk: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&pk, pk_bytes[:]) { return {}, .Bad_Public_Key }
	if len(sig) != ed25519.SIGNATURE_SIZE || !ed25519.verify(&pk, signed_bytes(p, payload), sig) { return {}, .Bad_Signature }

	// signed by the seller: its content is read only now
	l, ok := payload_read(payload, allocator)
	if !ok { return {}, .Bad_Payload }
	if l.product != p.name { licence_destroy(&l, allocator); return {}, .Wrong_Product }
	return l, .None
}

// The product's sign_context then the payload: what the signature covers.
signed_bytes :: proc(p: Product, payload: []byte, allocator := context.temp_allocator) -> []byte {
	out := make([]byte, len(p.sign_context) + len(payload), allocator)
	copy(out, p.sign_context)
	copy(out[len(p.sign_context):], payload)
	return out
}

// The payload of `l`: its fields in this order, as JSON with no space (the worker's JSON.stringify makes the same bytes).
// updates_until is written only when it is set.
payload_of :: proc(l: Licence, allocator := context.allocator) -> []byte {
	b := strings.builder_make(allocator)
	field :: proc(b: ^strings.Builder, name, value: string, first := false) {
		if !first { strings.write_byte(b, ',') }
		strings.write_byte(b, '"')
		strings.write_string(b, name)
		strings.write_string(b, `":`)
		quoted, _ := json.marshal(value, {}, context.temp_allocator)
		strings.write_bytes(b, quoted)
	}
	strings.write_byte(&b, '{')
	field(&b, "product", l.product, first = true)
	field(&b, "edition", l.edition)
	field(&b, "name", l.name)
	field(&b, "email", l.email)
	field(&b, "date", l.date)
	field(&b, "order", l.order)
	if l.updates_until != "" { field(&b, "updates_until", l.updates_until) }
	strings.write_byte(&b, '}')
	return b.buf[:]
}

@(private)
payload_read :: proc(payload: []byte, allocator: runtime.Allocator) -> (l: Licence, ok: bool) {
	v, err := json.parse(payload, allocator = context.temp_allocator)
	if err != .None { return {}, false }
	obj, is_obj := v.(json.Object)
	if !is_obj { return {}, false }
	field :: proc(o: json.Object, name: string, allocator: runtime.Allocator) -> (s: string, ok: bool) {
		x, has := o[name]
		if !has { return "", true }   // (an absent field is empty; "product" is checked by the caller)
		str, is_str := x.(json.String)
		if !is_str || len(str) > MAX_FIELD { return "", false }
		return strings.clone(str, allocator), true
	}
	names := [?]string{"product", "edition", "name", "email", "date", "order", "updates_until"}
	targets := [?]^string{&l.product, &l.edition, &l.name, &l.email, &l.date, &l.order, &l.updates_until}
	for name, i in names {
		s, good := field(obj, name, allocator)
		if !good { licence_destroy(&l, allocator); return {}, false }
		targets[i]^ = s
	}
	if l.updates_until != "" && !date_valid(l.updates_until) { licence_destroy(&l, allocator); return {}, false }
	return l, true
}

// The licence text for `lic`, signed with the private key `seed` (32 bytes). Its product is `p`'s; for a product that counts
// its years of updates, updates_until is written when lic has none (updates_until_of). For the tool and the tests.
sign :: proc(p: Product, seed: []byte, lic: Licence, allocator := context.allocator) -> (text: string, ok: bool) {
	l := lic
	l.product = p.name
	if l.updates_until == "" && p.update_years > 0 { l.updates_until = updates_until_of(p, l) }
	return sign_payload(p, seed, payload_of(l, context.temp_allocator), allocator)
}

// A licence text for any payload (the tests make damaged and foreign ones with it).
sign_payload :: proc(p: Product, seed: []byte, payload: []byte, allocator := context.allocator) -> (text: string, ok: bool) {
	priv: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&priv, seed) { return "", false }
	defer ed25519.private_key_clear(&priv)
	sig: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(&priv, signed_bytes(p, payload), sig[:])
	enc := base64.ENC_URL_TABLE
	pt := base64.encode(payload, enc, context.temp_allocator, {.No_Padding})
	st := base64.encode(sig[:], enc, context.temp_allocator, {.No_Padding})
	return strings.concatenate({p.version_tag, ".", pt, ".", st}, allocator), true
}

// The text of a licence file: comment lines that say whose it is (and `hint`, a line of the program's: how to register it),
// then the key wrapped at 76 columns. verify reads it as the key alone.
file_text :: proc(p: Product, lic: Licence, key: string, hint := "", allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	title := p.title != "" ? p.title : p.name
	fmt.sbprintfln(&b, "# %s licence (%s) for %s", title, edition_title(p, lic.edition), one_line(lic.name))
	fmt.sbprintfln(&b, "# Order %s, %s.", one_line(lic.order), one_line(lic.date))
	if lic.updates_until != "" { fmt.sbprintfln(&b, "# Updates until %s.", lic.updates_until) }
	if hint != "" { fmt.sbprintfln(&b, "# %s", one_line(hint)) }
	for i := 0; i < len(key); i += 76 {
		strings.write_string(&b, key[i:min(i + 76, len(key))])
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// (a name with a line break would end the comment and start a line that is read as the key)
@(private = "file")
one_line :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "\n", " ", context.temp_allocator)
	out, _ = strings.replace_all(out, "\r", " ", context.temp_allocator)
	return out
}

////////////////////////////////
// Years of updates

// Whether `s` is a day, "YYYY-MM-DD" (digits where they go; the calendar is not checked further).
date_valid :: proc(s: string) -> bool {
	if len(s) != 10 || s[4] != '-' || s[7] != '-' { return false }
	for c, i in transmute([]byte)s {
		if i == 4 || i == 7 { continue }
		if c < '0' || c > '9' { return false }
	}
	return true
}

// `day` ("YYYY-MM-DD") `years` later; the 29th of February becomes the 28th in a year that has none. "" when day is not one.
date_add_years :: proc(day: string, years: int, allocator := context.temp_allocator) -> string {
	if !date_valid(day) { return "" }
	y, _ := strconv.parse_int(day[:4], 10)
	m, _ := strconv.parse_int(day[5:7], 10)
	d, _ := strconv.parse_int(day[8:], 10)
	y += years
	leap := (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
	if m == 2 && d == 29 && !leap { d = 28 }
	return fmt.aprintf("%04d-%02d-%02d", y, m, d, allocator = allocator)
}

// The last release day the updates of `l` cover: its own updates_until, else (a product that counts them) update_years after
// its date, or after updates_from for a licence bought before that day. "": every version.
updates_until_of :: proc(p: Product, l: Licence, allocator := context.temp_allocator) -> string {
	if l.updates_until != "" { return strings.clone(l.updates_until, allocator) }
	if p.update_years <= 0 { return "" }
	start := l.date
	if date_valid(p.updates_from) && (!date_valid(start) || p.updates_from > start) { start = p.updates_from }
	return date_add_years(start, p.update_years, allocator)
}

// Whether the updates of `l` cover a version released on `released` ("YYYY-MM-DD"; "": the version's day is not known,
// covered). ISO days compare as text.
covers :: proc(p: Product, l: Licence, released: string) -> bool {
	until := updates_until_of(p, l)
	if until == "" || released == "" { return true }
	return released <= until
}
