// The configuration `cf` reads (cf deploy, cf dev), made from the product's file that `wrangler -c` reads as it is:
// products/<LICENCE_PRODUCT>.jsonc. One file per product, so the two tools cannot disagree. Secrets are not there:
//
//     LICENCE_PRODUCT=app cf deploy --secrets-file secrets.env                       production (live Paddle)
//     LICENCE_PRODUCT=app cf deploy --mode sandbox --secrets-file secrets.sandbox.env   Paddle's sandbox
import { readFileSync } from "node:fs";
import { bindings, defineConfig } from "cf/config";

interface ProductFile {
	name: string;
	compatibility_date?: string;
	vars?: Record<string, string>;
	env?: Record<string, { name: string; vars?: Record<string, string> }>;
}

// JSONC as wrangler reads it: comments and trailing commas out, strings as they are.
function parseJsonc(text: string): unknown {
	let out = "";
	for (let i = 0; i < text.length; i++) {
		const c = text[i];
		if (c === '"') {
			const start = i;
			for (i++; i < text.length && text[i] !== '"'; i++) if (text[i] === "\\") i++;
			out += text.slice(start, i + 1);
		} else if (c === "/" && text[i + 1] === "/") {
			while (i < text.length && text[i] !== "\n") i++;
			out += "\n";
		} else if (c === "/" && text[i + 1] === "*") {
			i = text.indexOf("*/", i + 2);
			if (i < 0) break;
			i++;
		} else {
			out += c;
		}
	}
	return JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"));
}

export default defineConfig(({ mode }) => {
	const product = process.env.LICENCE_PRODUCT ?? "";
	if (!/^[a-z0-9_-]+$/.test(product)) throw new Error("set LICENCE_PRODUCT to the name of a file of products/ (without .jsonc)");
	const file = parseJsonc(readFileSync(new URL(`./products/${product}.jsonc`, import.meta.url), "utf8")) as ProductFile;
	const s = mode === "sandbox" ? file.env?.sandbox : file;
	if (!s) throw new Error(`products/${product}.jsonc has no env.sandbox`);

	const env: Record<string, unknown> = {
		// no id: the first deploy creates the namespace
		LICENSES: bindings.kv({}),
		// One LicenseOrder Durable Object per transaction (a new_sqlite_classes migration, as in the product's file)
		ORDERS: bindings.durableObject({ className: "LicenseOrder" }),
		// Cloudflare Email Service: sending to anyone needs the Workers Paid plan
		EMAIL: bindings.sendEmail({}),
		LICENSE_PRIVATE_KEY: bindings.secret(),
		PADDLE_WEBHOOK_SECRET: bindings.secret(),
		PADDLE_API_KEY: bindings.secret(),
		// optional: leave them out of the secrets file to keep /admin/*, /mail/bounce closed
		ADMIN_TOKEN: bindings.secret(),
		MAIL_BOUNCE_SECRET: bindings.secret(),
	};
	for (const [k, v] of Object.entries(s.vars ?? {})) env[k] = bindings.text(String(v));

	return {
		worker: {
			name: s.name,
			compatibilityDate: file.compatibility_date ?? "2026-10-01",
			entrypoint: "src/index.ts",
			workersDev: true,
			observability: { enabled: true },
			env,
			migrations: [{ tag: "v1", newSqliteClasses: ["LicenseOrder"] }],
		},
	};
});
