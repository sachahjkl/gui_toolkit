package tk_toolbox

// The licences of a program (the toolkit's licence package): what a project's tool runs as its `licence` and `paddle`
// commands, for its product (docs/licence.md).
//   licence keygen [-private:FILE] [-force]          the signing key pair; FILE outside any git work tree
//   licence pubkey [-private:FILE | -dev]            the public key, the line of the program's Product
//   licence issue -name:N -email:E -edition:ID -order:ID [-date:YYYY-MM-DD] [-private:FILE | -dev] [-out:FILE]
//   licence verify FILE | -text:KEY [-public:KEY | -dev]
//   licence secrets <secrets.yaml> <out.env> [-keys:A,B]   the worker's secrets, decrypted by sops, to a git-ignored file
//   paddle [-apply] [-environment:sandbox|live] [-name:N] [-description:D] [-amounts:ID=CENTS,...] [-currency:EUR]
// keygen, pubkey, issue and verify need no network; paddle talks to Paddle's API (gt:http) only with -apply.

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import http "../http"
import "../fsx"
import licence "../licence"
import "../platform"

// What a program's tool says of its licences. Its strings live as long as the tool (constants).
Licence_Tool :: struct {
	product:  licence.Product,
	key_dir:  string,         // the folder of the private key ("": <user config>/<product.name>-licence, licence_key_dir)
	dev_seed: string,         // base64url of the development pair's private key, public on purpose ("": no -dev)
	hint:     string,         // a comment line of an issued file: how to register it ("Open this file with App.")
	paddle:   Paddle_Catalog, // the defaults of the paddle command
}

// What the paddle command makes: one product, one one-time price per edition, taxes included.
Paddle_Catalog :: struct {
	name:        string,   // the product's name in Paddle ("App User Licence")
	description: string,   // what the checkout says of it
	amounts:     string,   // "supporter=2900,patron=9900": an edition's price in the currency's smallest unit
	currency:    string,   // "EUR"
}

// The secrets the worker declares: what `licence secrets` keeps of a decrypted file (the setup keys of Paddle stay out).
WORKER_SECRETS :: [?]string{"LICENSE_PRIVATE_KEY", "PADDLE_WEBHOOK_SECRET", "PADDLE_API_KEY", "ADMIN_TOKEN", "MAIL_BOUNCE_SECRET"}

// The environment variable of the paddle command's API key: a server-side key with the catalogue's rights, never saved.
PADDLE_KEY_ENV :: "PADDLE_API_KEY"

PADDLE_SANDBOX :: "https://sandbox-api.paddle.com"
PADDLE_LIVE    :: "https://api.paddle.com"

// The commands `licence` and `paddle` of a project's tool, for `tool` (copied).
licence_commands :: proc(tool: Licence_Tool) -> [2]Command {
	user := new_clone(tool)
	return {
		{name = "licence", usage = "keygen | pubkey | issue | verify | secrets: the licences of the program (docs/licence.md)", run_with = licence_run, user = user},
		{name = "paddle", usage = "[-apply] [-environment:sandbox|live] [-name:N] [-description:D] [-amounts:ID=CENTS,...] [-currency:C]: the Paddle catalogue",
			run_with = paddle_run, user = user, checked = true, flags = PADDLE_FLAGS[:], positionals = 0},
	}
}

// (static: the command keeps the slice after licence_commands returns)
@(private = "file", rodata)
PADDLE_FLAGS := [?]string{"apply", "environment:", "name:", "description:", "amounts:", "currency:"}

LICENCE_USAGE :: `licence keygen [-private:FILE] [-force]
licence pubkey [-private:FILE | -dev]
licence issue -name:N -email:E -edition:ID -order:ID [-date:YYYY-MM-DD] [-private:FILE | -dev] [-out:FILE]
licence verify FILE | -text:KEY [-public:KEY | -dev]
licence secrets <secrets.yaml> <out.env> [-keys:A,B]
`

@(private = "file")
licence_run :: proc(args: []string, user: rawptr) -> int {
	tool := (^Licence_Tool)(user)^
	what := len(args) > 0 ? args[0] : ""
	rest := len(args) > 0 ? args[1:] : nil
	switch what {
	case "keygen":  return done(licence_keygen(tool, rest))
	case "pubkey":  return done(licence_pubkey(tool, rest))
	case "issue":   return done(licence_issue(tool, rest))
	case "verify":  return done(licence_verify(tool, rest))
	case "secrets":
		plain := plain_args(rest)
		if len(plain) != 2 { break }
		keys := WORKER_SECRETS
		names := keys[:]
		if has_flag(rest, "keys") { names = strings.split(flag_value(rest, "keys"), ",", context.temp_allocator) }
		return done(sops_dotenv(plain[0], plain[1], names))
	}
	fmt.eprint(LICENCE_USAGE)
	return EXIT_USAGE
}

////////////////////////////////
// The private key

// The folder of the private key: tool.key_dir, else `<product>-licence` in the user's configuration folder (Linux
// ~/.config/<product>-licence, Windows %APPDATA%\<product>-licence): outside any repository.
licence_key_dir :: proc(tool: Licence_Tool, allocator := context.temp_allocator) -> string {
	if tool.key_dir != "" { return strings.clone(tool.key_dir, allocator) }
	return platform.user_dir(.Config, fmt.tprintf("%s-licence", tool.product.name), allocator)
}

// The private key's file: -private:FILE, else private.key in licence_key_dir.
@(private = "file")
private_path :: proc(tool: Licence_Tool, args: []string) -> string {
	if has_flag(args, "private") { return flag_value(args, "private") }
	dir := licence_key_dir(tool)
	if dir == "" { return "" }
	p, _ := filepath.join({dir, "private.key"}, context.temp_allocator)
	return p
}

// The seed -dev, -private:FILE or the default file names. why: "" when it is read.
@(private = "file")
chosen_seed :: proc(tool: Licence_Tool, args: []string) -> (seed: [32]byte, why: string) {
	if has_flag(args, "dev") {
		if tool.dev_seed == "" { return {}, "this program has no development pair (Licence_Tool.dev_seed)" }
		s, ok := licence.key_decode(tool.dev_seed)
		if !ok { return {}, "Licence_Tool.dev_seed is not 32 bytes of base64url" }
		return s, ""
	}
	path := private_path(tool, args)
	if path == "" { return {}, "no folder for the private key: pass -private:FILE" }
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return {}, fmt.tprintf("cannot read the private key %s: run `licence keygen` first, or pass -private:FILE", path) }
	s, ok := licence.key_decode(licence.normalize(string(data), context.temp_allocator))
	if !ok { return {}, fmt.tprintf("%s is not a licence private key", path) }
	return s, ""
}

// Makes the signing key pair: the private key's file (outside any git work tree), the public key printed. why: "" done.
licence_keygen :: proc(tool: Licence_Tool, args: []string) -> (why: string) {
	path := private_path(tool, args)
	if path == "" { return "no folder for the private key: pass -private:FILE" }
	if in_git_tree(path) { return fmt.tprintf("refused: %s is in a git work tree, where the private key could be committed", path) }
	if os.exists(path) && !has_flag(args, "force") {
		return fmt.tprintf("%s exists already: a new key makes every licence issued so far invalid. -force replaces it (keep a copy first)", path)
	}
	seed: [32]byte
	crypto.rand_bytes(seed[:])
	fsx.make_dirs(filepath.dir(path))
	text := fmt.tprintf("# %s licence signing key (Ed25519). SECRET: whoever has it can issue licences.\n# Never commit it, never send it. Keep a backup outside this computer.\n%s\n",
		licence_title(tool.product), licence.key_encode(seed[:], context.temp_allocator))
	if !fsx.write_atomic(path, transmute([]byte)text, flush = true, private = true) { return fmt.tprintf("cannot write %s", path) }
	pub, _ := licence.public_key_of(seed[:], context.temp_allocator)
	fmt.printfln("Private key written to %s", path)
	fmt.printfln("Public key: %s\n\nPut it in the program's licence.Product (public_key), and in the worker's LICENSE_PUBLIC_KEY.", pub)
	return ""
}

// Prints the public key of the chosen private key.
licence_pubkey :: proc(tool: Licence_Tool, args: []string) -> (why: string) {
	seed, w := chosen_seed(tool, args)
	if w != "" { return w }
	pub, _ := licence.public_key_of(seed[:], context.temp_allocator)
	fmt.println(pub)
	return ""
}

// Signs a licence, checks it as the program would, writes its file and prints the key.
licence_issue :: proc(tool: Licence_Tool, args: []string) -> (why: string) {
	p := tool.product
	l := licence.Licence{
		edition = flag_value(args, "edition", p.editions[0].id),
		name    = strings.trim_space(flag_value(args, "name")),
		email   = strings.trim_space(flag_value(args, "email")),
		order   = strings.trim_space(flag_value(args, "order")),
		date    = flag_value(args, "date"),
	}
	if l.name == "" || l.order == "" { return "issue needs -name:N and -order:ID (and -email:E, -edition:ID)" }
	if !licence.edition_known(p, l.edition) { return fmt.tprintf("-edition:%s is not an edition of %s", l.edition, p.name) }
	if l.date == "" {
		y, mo, d := time.date(time.now())
		l.date = fmt.tprintf("%04d-%02d-%02d", y, int(mo), d)
	}
	if !licence.date_valid(l.date) { return "-date is YYYY-MM-DD" }
	for f in ([]string{l.name, l.email, l.order}) {
		if len(f) > licence.MAX_FIELD { return fmt.tprintf("a field is longer than %d bytes", licence.MAX_FIELD) }
	}
	seed, w := chosen_seed(tool, args)
	if w != "" { return w }
	text, signed := licence.sign(p, seed[:], l, context.temp_allocator)
	if !signed { return "signing failed" }
	// never hand out what the program would refuse
	pub, _ := licence.public_key_of(seed[:], context.temp_allocator)
	back, err := licence.verify(p, text, pub, context.temp_allocator)
	if err != .None || back.name != l.name || back.order != l.order { return fmt.tprintf("the licence does not verify (%v)", err) }

	path := flag_value(args, "out")
	if path == "" {
		dir := licence_key_dir(tool)
		if dir == "" { return "no folder for the issued licences: pass -out:FILE" }
		path, _ = filepath.join({dir, "issued", fmt.tprintf("%s%s", safe_file_name(l.order), p.file_extension)}, context.temp_allocator)
	}
	fsx.make_dirs(filepath.dir(path))
	if !fsx.write_atomic(path, transmute([]byte)licence.file_text(p, back, text, tool.hint, context.temp_allocator)) { return fmt.tprintf("cannot write %s", path) }
	fmt.printfln("Licence of %s (%s), order %s, %s", l.name, licence.edition_title(p, l.edition), l.order, l.date)
	fmt.printfln("File: %s\n\nKey:\n%s", path, text)
	return ""
}

// Checks a licence file or key with the product's key, -public:KEY, or the development pair (-dev).
licence_verify :: proc(tool: Licence_Tool, args: []string) -> (why: string) {
	p := tool.product
	text := flag_value(args, "text")
	if !has_flag(args, "text") {
		plain := plain_args(args)
		if len(plain) != 1 { return "verify needs a file or -text:KEY" }
		data, err := os.read_entire_file(plain[0], context.temp_allocator)
		if err != nil { return fmt.tprintf("cannot read %s", plain[0]) }
		text = string(data)
	}
	public := p.public_key
	switch {
	case has_flag(args, "dev"):
		seed, w := chosen_seed(tool, args)
		if w != "" { return w }
		public, _ = licence.public_key_of(seed[:], context.temp_allocator)
	case has_flag(args, "public"):
		public = flag_value(args, "public")
	}
	l, err := licence.verify(p, text, public, context.temp_allocator)
	if err != .None {
		fmt.printfln("INVALID: %s", licence.error_text(err))
		return "the licence does not verify"
	}
	until := licence.updates_until_of(p, l)
	fmt.printfln("VALID: %s licence of %s <%s>, order %s, %s%s", licence.edition_title(p, l.edition), l.name, l.email, l.order, l.date,
		until != "" ? fmt.tprintf(", updates until %s", until) : "")
	return ""
}

@(private = "file")
licence_title :: proc(p: licence.Product) -> string { return p.title != "" ? p.title : p.name }

// An order number as a file name.
@(private = "file")
safe_file_name :: proc(s: string) -> string {
	b := transmute([]byte)strings.clone(s, context.temp_allocator)
	for &c in b { if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_') { c = '_' } }
	return len(b) > 0 ? string(b) : "licence"
}

////////////////////////////////
// The worker's secrets, from sops

// Decrypts `secrets` (a sops file: secrets/production.yaml) as dotenv and writes the lines of `keys` to `out`, readable by
// its user only. Nothing secret is printed: the names written only. `out` in a git work tree must be git-ignored. why: "" done.
sops_dotenv :: proc(secrets, out: string, keys: []string) -> (why: string) {
	if in_git_tree(out) {
		_, code := capture({"git", "-C", filepath.dir(out), "check-ignore", "-q", filepath.base(out)})
		if code != 0 { return fmt.tprintf("refused: %s is in a git work tree and not ignored by it", out) }
	}
	text, code := capture({"sops", "--decrypt", "--output-type", "dotenv", secrets})
	if code != 0 { return fmt.tprintf("sops could not decrypt %s (is SOPS_AGE_KEY_FILE set?)", secrets) }
	kept, names := dotenv_keep(text, keys)
	if len(names) == 0 { return fmt.tprintf("%s holds none of %s", secrets, strings.join(keys, ", ", context.temp_allocator)) }
	if !fsx.write_atomic(out, transmute([]byte)kept, flush = true, private = true) { return fmt.tprintf("cannot write %s", out) }
	fmt.printfln("%s: %s", out, strings.join(names, ", ", context.temp_allocator))
	return ""
}

// The lines of a dotenv text whose name is one of `keys`, and their names in the order of the text.
dotenv_keep :: proc(text: string, keys: []string, allocator := context.temp_allocator) -> (kept: string, names: []string) {
	b := strings.builder_make(allocator)
	found := make([dynamic]string, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		eq := strings.index_byte(line, '=')
		if eq <= 0 { continue }
		name := strings.trim_space(line[:eq])
		for k in keys {
			if k != name { continue }
			strings.write_string(&b, line)
			strings.write_byte(&b, '\n')
			append(&found, name)
			break
		}
	}
	return strings.to_string(b), found[:]
}

////////////////////////////////
// The Paddle catalogue

// An edition's price.
Paddle_Amount :: struct {
	edition: string,
	amount:  string,   // the smallest unit of the currency, digits ("2900": 29.00 EUR)
}

// "supporter=2900,patron=9900" as amounts; ok false: a part is not ID=DIGITS, or names no edition of `p`.
paddle_amounts :: proc(p: licence.Product, text: string, allocator := context.temp_allocator) -> (out: []Paddle_Amount, ok: bool) {
	list := make([dynamic]Paddle_Amount, allocator)
	for part in strings.split(text, ",", context.temp_allocator) {
		x := strings.trim_space(part)
		if x == "" { continue }
		eq := strings.index_byte(x, '=')
		if eq <= 0 { return nil, false }
		a := Paddle_Amount{edition = x[:eq], amount = x[eq + 1:]}
		if _, digits := strconv.parse_u64_of_base(a.amount, 10); a.amount == "" || !digits || !licence.edition_known(p, a.edition) { return nil, false }
		append(&list, a)
	}
	return list[:], len(list) > 0
}

// The body of POST /products.
paddle_product_body :: proc(c: Paddle_Catalog) -> string {
	return fmt.tprintf(`{{"name":%s,"tax_category":"standard","description":%s}}`, paddle_quote(c.name), paddle_quote(c.description))
}

// The body of POST /prices: one payment (no billing cycle, no trial), the tax in the price (the buyer pays what is shown),
// one at a time; the edition in its custom data (what the paddle command finds again).
paddle_price_body :: proc(p: licence.Product, c: Paddle_Catalog, product_id: string, a: Paddle_Amount) -> string {
	title := licence.edition_title(p, a.edition)
	return fmt.tprintf(`{{%s"description":%s,"name":%s,"unit_price":{{"amount":%s,"currency_code":%s}},"tax_mode":"internal","quantity":{{"minimum":1,"maximum":1}},"custom_data":{{"edition":%s}}}}`,
		product_id != "" ? fmt.tprintf(`"product_id":%s,`, paddle_quote(product_id)) : "",
		paddle_quote(fmt.tprintf("%s, %s, one payment, taxes included", c.name, title)), paddle_quote(title),
		paddle_quote(a.amount), paddle_quote(c.currency), paddle_quote(a.edition))
}

// The worker's PRICES (price id -> edition) as the JSON text of its setting.
paddle_prices_setting :: proc(ids: []string, amounts: []Paddle_Amount) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	for a, i in amounts {
		if i > 0 { strings.write_byte(&b, ',') }
		fmt.sbprintf(&b, "%s:%s", paddle_quote(ids[i]), paddle_quote(a.edition))
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

@(private = "file")
paddle_run :: proc(args: []string, user: rawptr) -> int {
	tool := (^Licence_Tool)(user)^
	p := tool.product
	c := tool.paddle
	if has_flag(args, "name") { c.name = flag_value(args, "name") }
	if has_flag(args, "description") { c.description = flag_value(args, "description") }
	if has_flag(args, "amounts") { c.amounts = flag_value(args, "amounts") }
	if has_flag(args, "currency") { c.currency = flag_value(args, "currency") }
	if c.currency == "" { c.currency = "EUR" }
	environment := flag_value(args, "environment", "sandbox")
	if environment != "sandbox" && environment != "live" { fmt.eprintln("paddle: -environment:sandbox or -environment:live"); return EXIT_USAGE }
	if c.name == "" { fmt.eprintln("paddle: the product has no name (-name:N)"); return EXIT_USAGE }
	amounts, ok := paddle_amounts(p, c.amounts)
	if !ok { fmt.eprintln("paddle: -amounts:ID=CENTS,... with the program's editions"); return EXIT_USAGE }
	base := environment == "live" ? PADDLE_LIVE : PADDLE_SANDBOX

	if !has_flag(args, "apply") {
		fmt.printfln("DRY RUN (%s, %s): nothing is sent. Add -apply to create it.", environment, base)
		fmt.printfln("POST /products\n%s", paddle_product_body(c))
		for a in amounts { fmt.printfln("POST /prices (product_id: the product above)\n%s", paddle_price_body(p, c, "", a)) }
		return EXIT_DONE
	}
	key := os.get_env(PADDLE_KEY_ENV, context.temp_allocator)
	if key == "" { fmt.eprintfln("paddle: set %s to a server-side API key of the %s account first", PADDLE_KEY_ENV, environment); return EXIT_FAILED }
	return done(paddle_apply(p, c, amounts, base, key, environment))
}

// Makes the product and its prices, or finds them made: a product of this name, a price of this edition, amount and currency
// with no billing cycle, are reused. Safe to run again.
@(private = "file")
paddle_apply :: proc(p: licence.Product, c: Paddle_Catalog, amounts: []Paddle_Amount, base, key, environment: string) -> (why: string) {
	product_id := ""
	list, w := paddle_call(base, key, "GET", "/products?status=active&per_page=200", "")
	if w != "" { return w }
	for x in list { if paddle_text(x, "name") == c.name { product_id = paddle_text(x, "id"); break } }
	if product_id != "" {
		fmt.printfln("product exists: %s", product_id)
	} else {
		made, mw := paddle_call(base, key, "POST", "/products", paddle_product_body(c))
		if mw != "" { return mw }
		if len(made) == 0 { return "Paddle made no product" }
		product_id = paddle_text(made[0], "id")
		fmt.printfln("product created: %s", product_id)
	}

	prices, pw := paddle_call(base, key, "GET", fmt.tprintf("/prices?product_id=%s&status=active&per_page=200", product_id), "")
	if pw != "" { return pw }
	ids := make([]string, len(amounts), context.temp_allocator)
	for a, i in amounts {
		for x in prices {
			o, _ := x.(json.Object)
			unit, _ := o["unit_price"].(json.Object)
			custom, _ := o["custom_data"].(json.Object)
			_, cycle := o["billing_cycle"].(json.Object)
			if !cycle && paddle_text(unit, "amount") == a.amount && paddle_text(unit, "currency_code") == c.currency && paddle_text(custom, "edition") == a.edition {
				ids[i] = paddle_text(x, "id")
				break
			}
		}
		if ids[i] != "" { fmt.printfln("price exists (%s): %s", a.edition, ids[i]); continue }
		made, mw := paddle_call(base, key, "POST", "/prices", paddle_price_body(p, c, product_id, a))
		if mw != "" { return mw }
		if len(made) == 0 { return "Paddle made no price" }
		ids[i] = paddle_text(made[0], "id")
		fmt.printfln("price created (%s): %s", a.edition, ids[i])
	}
	fmt.printfln("\nEnvironment: %s\nProduct:     %s  %s", environment, c.name, product_id)
	for a, i in amounts { fmt.printfln("Price:       %s %s %s, one payment, taxes included  %s", a.edition, a.amount, c.currency, ids[i]) }
	fmt.printfln("\nThe worker's setting (licence-worker/products/<program>.jsonc, this environment):\n  \"PRICES\": %s", paddle_quote(paddle_prices_setting(ids, amounts)))
	fmt.println("The site's buy block: site.Shop.prices, the same ids.")
	return ""
}

// A call of Paddle's API (gt:http); `data` as a list (an object answered is a list of one). why: "" when it answered data.
@(private = "file")
paddle_call :: proc(base, key, method, path, body: string) -> (data: []json.Value, why: string) {
	headers := []http.Header{{"Authorization", fmt.tprintf("Bearer %s", key)}, {"Content-Type", "application/json"}, {"Paddle-Version", "1"}}
	res, err := http.request(method, fmt.tprintf("%s%s", base, path), {headers = headers, body = transmute([]u8)body, timeout = 30 * time.Second}, context.temp_allocator)
	if err != .None { return nil, fmt.tprintf("%s %s: %s", method, path, http.error_text(err)) }
	v, perr := json.parse(res.body, allocator = context.temp_allocator)
	if perr != .None { return nil, fmt.tprintf("%s %s: answered %d, not JSON", method, path, res.status) }
	root, _ := v.(json.Object)
	if e, has := root["error"]; has { return nil, fmt.tprintf("Paddle answered an error to %s %s: %v", method, path, e) }
	if res.status < 200 || res.status > 299 { return nil, fmt.tprintf("%s %s: answered %d", method, path, res.status) }
	#partial switch d in root["data"] {
	case json.Array:  return d[:], ""
	case json.Object:
		out := make([]json.Value, 1, context.temp_allocator)
		out[0] = d
		return out, ""
	}
	return nil, ""
}

@(private = "file")
paddle_text :: proc(v: json.Value, key: string) -> string {
	o, _ := v.(json.Object)
	s, _ := o[key].(json.String)
	return string(s)
}

@(private = "file")
paddle_quote :: proc(s: string) -> string {
	q, _ := json.marshal(s, {}, context.temp_allocator)
	return string(q)
}
