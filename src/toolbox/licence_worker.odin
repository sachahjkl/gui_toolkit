package tk_toolbox

// `licence worker`: the licence Worker's file of a product (licence-worker/products/<program>.jsonc), made from the
// program's licence.Product, so that the program and its shop cannot disagree on what a licence is. The shop's own
// values (its site, its mail, its price ids) come from the flags; what is not known yet is written empty, with SET.

import "core:fmt"
import "core:os"
import "core:strings"
import licence "../licence"

// What the Worker's file says besides the product: the shop's.
Worker_Shop :: struct {
	origin:    string,   // the site of the thank-you page ("https://app.example.org")
	mail_from: string,   // "App <licence@mail.example.org>": a domain onboarded in Cloudflare's Email Sending
	hint:      string,   // how a buyer registers the file (Licence_Tool.hint)
}

// The file: production at its top level, the sandbox in env.sandbox (the development pair's key, Paddle's sandbox).
worker_config :: proc(p: licence.Product, shop: Worker_Shop, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	editions := strings.builder_make(context.temp_allocator)
	strings.write_string(&editions, "[")
	for e, i in p.editions {
		if e.id == "" { break }
		if i > 0 { strings.write_string(&editions, ",") }
		fmt.sbprintf(&editions, `{{"id":%q,"title":%q}}`, e.id, e.title)
	}
	strings.write_string(&editions, "]")
	years := p.update_years > 0 ? fmt.tprintf("%d", p.update_years) : ""
	origin := shop.origin != "" ? shop.origin : "https://SET.example.org"
	mail := shop.mail_from != "" ? shop.mail_from : fmt.tprintf("%s <licence@SET.example.org>", p.title)
	fmt.sbprintf(&b, "// The licence Worker of %s, made by `licence worker` from its licence.Product: make it again rather than\n", p.title)
	strings.write_string(&b, "// edit the product's values. SET: what the maintainer still sets (licence-worker/README.md). No secret is here.\n{\n")
	fmt.sbprintf(&b, "\t\"name\": %q,\n", fmt.tprintf("%s-licence", p.name))
	strings.write_string(&b, WORKER_HEAD)
	worker_vars(&b, p, editions_text = strings.to_string(editions), years = years, public_key = p.public_key,
		prices_api = PADDLE_LIVE, origin = origin, mail = mail, hint = shop.hint, indent = "\t\t")
	strings.write_string(&b, "\t},\n\n\t\"env\": {\n\t\t\"sandbox\": {\n")
	fmt.sbprintf(&b, "\t\t\t\"name\": %q,\n", fmt.tprintf("%s-licence-sandbox", p.name))
	strings.write_string(&b, WORKER_SANDBOX_HEAD)
	worker_vars(&b, p, editions_text = strings.to_string(editions), years = years, public_key = p.dev_public_key,
		prices_api = PADDLE_SANDBOX, origin = fmt.tprintf("%s,http://localhost:8765", origin), mail = mail, hint = shop.hint, indent = "\t\t\t\t")
	strings.write_string(&b, "\t\t\t}\n\t\t}\n\t}\n}\n")
	return strings.to_string(b)
}

@(private = "file")
worker_vars :: proc(b: ^strings.Builder, p: licence.Product, editions_text, years, public_key, prices_api, origin, mail, hint, indent: string) {
	line :: proc(b: ^strings.Builder, indent, name, value: string, set := false, last := false) {
		fmt.sbprintf(b, "%s%q: %q%s%s\n", indent, name, value, last ? "" : ",", set && value == "" ? "   // SET" : "")
	}
	line(b, indent, "PRODUCT", p.name)
	line(b, indent, "PRODUCT_TITLE", p.title)
	line(b, indent, "VERSION_TAG", p.version_tag)
	line(b, indent, "SIGN_CONTEXT", p.sign_context)
	line(b, indent, "FILE_EXTENSION", p.file_extension)
	line(b, indent, "ORDER_PREFIX", strings.to_upper(p.name, context.temp_allocator))
	line(b, indent, "EDITIONS", editions_text)
	line(b, indent, "UPDATE_YEARS", years)
	line(b, indent, "UPDATES_FROM", p.updates_from)
	line(b, indent, "LICENSE_PUBLIC_KEY", public_key, set = true)
	fmt.sbprintf(b, "%s\"PRICES\": \"{{}}\",   // SET: {{\"pri_...\":\"<edition>\"}}, what `paddle -apply` prints\n", indent)
	line(b, indent, "PADDLE_API_BASE", prices_api)
	line(b, indent, "ALLOWED_ORIGIN", origin)
	line(b, indent, "MAIL_FROM", mail)
	line(b, indent, "MAIL_REPLY_TO", "")
	line(b, indent, "MAIL_SUBJECT", "")
	line(b, indent, "MAIL_TEXT", "")
	line(b, indent, "FILE_HINT", hint != "" ? hint : fmt.tprintf("Open this file with %s, or paste the key where it asks for a licence.", p.title))
	line(b, indent, "WEBHOOK_TOLERANCE_SECONDS", "300")
	line(b, indent, "RESEND_ENABLED", "false")
	line(b, indent, "RESEND_MAX_PER_HOUR", "3")
	line(b, indent, "RESEND_REQUIRE_TOKEN", "false")
	line(b, indent, "MAIL_BACKOFF_MINUTES", "1,5,30,120,720,2880")
	line(b, indent, "MAIL_MAX_ATTEMPTS", "7")
	line(b, indent, "PII_RETENTION_DAYS", "90", last = true)
}

@(private = "file")
WORKER_HEAD :: `	"main": "../src/index.ts",
	"compatibility_date": "2026-10-01",
	"workers_dev": true,
	"observability": { "enabled": true },
	"kv_namespaces": [{ "binding": "LICENSES" }],
	"durable_objects": { "bindings": [{ "name": "ORDERS", "class_name": "LicenseOrder" }] },
	"migrations": [{ "tag": "v1", "new_sqlite_classes": ["LicenseOrder"] }],
	"send_email": [{ "name": "EMAIL" }],

	"vars": {
`

@(private = "file")
WORKER_SANDBOX_HEAD :: `			"workers_dev": true,
			"observability": { "enabled": true },
			"kv_namespaces": [{ "binding": "LICENSES" }],
			"durable_objects": { "bindings": [{ "name": "ORDERS", "class_name": "LicenseOrder" }] },
			"migrations": [{ "tag": "v1", "new_sqlite_classes": ["LicenseOrder"] }],
			"send_email": [{ "name": "EMAIL" }],
			"vars": {
`

// licence worker <out.jsonc> [-origin:URL] [-mail:"Name <address>"]
@(private)
licence_worker :: proc(tool: Licence_Tool, args: []string) -> string {
	plain := plain_args(args)
	if len(plain) != 1 { return "licence worker <out.jsonc> [-origin:URL] [-mail:\"Name <address>\"]" }
	text := worker_config(tool.product, {origin = flag_value(args, "origin"), mail_from = flag_value(args, "mail"), hint = tool.hint}, context.temp_allocator)
	if err := os.write_entire_file(plain[0], transmute([]u8)text); err != nil { return fmt.tprintf("%s: %v", plain[0], err) }
	fmt.printfln("wrote %s", plain[0])
	return ""
}
