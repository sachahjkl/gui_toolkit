// A program's licences, as the toolkit's licence package reads them (src/licence/licence.odin):
//
//     <VERSION_TAG>.<payload>.<signature>
//
// payload: base64url (no padding) of the JSON {"product":..,"edition":..,"name":..,"email":..,"date":..,"order":..} and,
// for a product that counts its years of updates, "updates_until".
// signature: base64url (no padding) of the Ed25519 signature over SIGN_CONTEXT followed by the payload's bytes exactly
// as they are in the text.
//
// What the product is comes from the Worker's settings (products/<program>.jsonc): one codebase, one deploy per product.

import { b64urlDecode, b64urlEncode, concat, utf8 } from "./encoding.ts";
import type { Env } from "./env.ts";

export const MAX_FIELD = 256;   // bytes, per field: the program refuses a longer one

export type Edition = string;

export interface EditionDef {
	id: string;
	title: string;
}

// The Odin Product's fields, and what the shop adds.
export interface Product {
	name: string;            // PRODUCT: the payload's "product"
	title: string;           // PRODUCT_TITLE: the program's name, in the file's comments and the mail
	versionTag: string;      // VERSION_TAG
	signContext: string;     // SIGN_CONTEXT
	fileExtension: string;   // FILE_EXTENSION: the file, and the suffix of its download route
	orderPrefix: string;     // ORDER_PREFIX: the order numbers' start ("APP": APP-XXXX-XXXX-XXXX)
	editions: EditionDef[];  // EDITIONS, lowest rank first; else the editions of PRICES
	prices: Record<string, Edition>;   // PRICES: Paddle price id -> edition
	updateYears: number;     // UPDATE_YEARS: 0 = every version
	updatesFrom: string;     // UPDATES_FROM: a licence bought before this day counts its years from it
	fileHint: string;        // FILE_HINT: a comment line of the file (how to register it)
}

export interface Fields {
	edition: Edition;
	name: string;
	email: string;
	date: string;    // YYYY-MM-DD
	order: string;
	updates_until?: string;
}

function parseJson<T>(text: string | undefined, fallback: T): T {
	if (!text) return fallback;
	try {
		return JSON.parse(text) as T;
	} catch {
		return fallback;
	}
}

// The product of this deploy, from its settings. Missing names are reported by GET /health (missingSettings).
export function productOf(env: Env): Product {
	const prices = parseJson<Record<string, string>>(env.PRICES, {});
	const cleanPrices: Record<string, string> = {};
	for (const [k, v] of Object.entries(prices ?? {})) if (typeof v === "string" && k.trim()) cleanPrices[k.trim()] = v;
	let editions = parseJson<EditionDef[]>(env.EDITIONS, []).filter((e) => e && typeof e.id === "string" && e.id);
	if (editions.length === 0) editions = [...new Set(Object.values(cleanPrices))].map((id) => ({ id, title: id }));
	const years = Number.parseInt(env.UPDATE_YEARS ?? "0", 10);
	return {
		name: env.PRODUCT ?? "",
		title: env.PRODUCT_TITLE || env.PRODUCT || "",
		versionTag: env.VERSION_TAG ?? "",
		signContext: env.SIGN_CONTEXT ?? "",
		fileExtension: env.FILE_EXTENSION ?? "",
		orderPrefix: env.ORDER_PREFIX || (env.PRODUCT ?? "").toUpperCase(),
		editions,
		prices: cleanPrices,
		updateYears: Number.isFinite(years) && years > 0 && years <= 100 ? years : 0,
		updatesFrom: /^\d{4}-\d{2}-\d{2}$/.test(env.UPDATES_FROM ?? "") ? env.UPDATES_FROM! : "",
		fileHint: env.FILE_HINT ?? "",
	};
}

export function editionTitle(p: Product, e: Edition): string {
	return p.editions.find((x) => x.id === e)?.title || e;
}

// A value as a licence can carry it: well-formed text on one line, at most MAX_FIELD bytes (cut between characters).
export function cleanField(s: string): string {
	const one = s.toWellFormed().normalize("NFC").replace(/[\p{Cc}\u2028\u2029\u200e\u200f\u061c\u202a-\u202e\u2066-\u2069]+/gu, " ").replace(/\s+/g, " ").trim();
	let out = "";
	let bytes = 0;
	for (const ch of one) {
		const n = utf8(ch).length;
		if (bytes + n > MAX_FIELD) break;
		out += ch;
		bytes += n;
	}
	return out.trimEnd();
}

// `day` (YYYY-MM-DD) `years` later; the 29th of February becomes the 28th in a year that has none (as the Odin package).
export function addYears(day: string, years: number): string {
	const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day);
	if (!m) return "";
	const y = Number(m[1]) + years;
	let d = Number(m[3]);
	const leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
	if (m[2] === "02" && d === 29 && !leap) d = 28;
	return `${String(y).padStart(4, "0")}-${m[2]}-${String(d).padStart(2, "0")}`;
}

// The last release day a licence bought on `date` covers ("": every version).
export function updatesUntil(p: Product, date: string): string {
	if (p.updateYears <= 0) return "";
	const start = p.updatesFrom && p.updatesFrom > date ? p.updatesFrom : date;
	return addYears(start, p.updateYears);
}

// The same text Odin's payload_of makes (same field order; updates_until only when set).
export function payloadOf(p: Product, f: Fields): string {
	const o: Record<string, string> = { product: p.name, edition: f.edition, name: f.name, email: f.email, date: f.date, order: f.order };
	if (f.updates_until) o.updates_until = f.updates_until;
	return JSON.stringify(o);
}

// The key text of `key`: white space, '#' comment lines and quotes dropped, as Odin's `normalize` does.
export function normalize(text: string): string {
	return text.split(/\r?\n/).map((l) => l.trim()).filter((l) => !l.startsWith("#")).join("").replace(/[ \t"']/g, "");
}

function seedBytes(text: string): Uint8Array {
	const b = b64urlDecode(normalize(text));
	if (!b || b.length !== 32) throw new Error("LICENSE_PRIVATE_KEY is not a 32-byte base64url seed (the line of private.key without its # comments)");
	return b;
}

const PKCS8_ED25519_PREFIX = Uint8Array.from([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]);

export interface Signer {
	sign(f: Fields): Promise<string>;
	verify(text: string): Promise<boolean>;
}

let cached: { id: string; signer: Promise<Signer> } | undefined;

// Imports the keys once per isolate. The private key is given as the seed (what keygen writes), wrapped in PKCS#8 for
// WebCrypto, so the public key is not needed to sign; it is used to check the pair and every licence before it is used.
export function loadSigner(privateKey: string, publicKey: string, p: Product): Promise<Signer> {
	const id = [privateKey, publicKey, p.name, p.versionTag, p.signContext].join("|");
	if (cached?.id === id) return cached.signer;
	const signer = makeSigner(privateKey, publicKey, p);
	cached = { id, signer };
	signer.catch(() => { if (cached?.id === id) cached = undefined; });
	return signer;
}

async function makeSigner(privateKey: string, publicKey: string, p: Product): Promise<Signer> {
	if (!p.name || !p.versionTag || !p.signContext) throw new Error("PRODUCT, VERSION_TAG and SIGN_CONTEXT must be set");
	const seed = seedBytes(privateKey);
	const pubBytes = b64urlDecode(normalize(publicKey));
	if (!pubBytes || pubBytes.length !== 32) throw new Error("LICENSE_PUBLIC_KEY is not a 32-byte base64url key");
	const priv = await crypto.subtle.importKey("pkcs8", concat(PKCS8_ED25519_PREFIX, seed), { name: "Ed25519" }, false, ["sign"]);
	const pub = await crypto.subtle.importKey("raw", pubBytes, { name: "Ed25519" }, false, ["verify"]);

	const verifyPayload = async (payload: Uint8Array, sig: Uint8Array) =>
		crypto.subtle.verify({ name: "Ed25519" }, pub, sig, concat(utf8(p.signContext), payload));

	const signer: Signer = {
		async sign(f) {
			const payload = utf8(payloadOf(p, f));
			const sig = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, priv, concat(utf8(p.signContext), payload)));
			if (!(await verifyPayload(payload, sig))) throw new Error("the signature does not check out with LICENSE_PUBLIC_KEY");
			return `${p.versionTag}.${b64urlEncode(payload)}.${b64urlEncode(sig)}`;
		},
		async verify(text) {
			const parts = normalize(text).split(".");
			if (parts.length !== 3 || parts[0] !== p.versionTag) return false;
			const payload = b64urlDecode(parts[1]);
			const sig = b64urlDecode(parts[2]);
			return !!payload && !!sig && verifyPayload(payload, sig);
		},
	};
	// the pair must match: otherwise every licence made would be refused by the program
	await signer.sign({ edition: p.editions[0]?.id ?? "check", name: "check", email: "check@example.org", date: "2026-01-01", order: "CHECK" });
	return signer;
}

// The key wrapped at 76 columns under comment lines: the file the toolkit's licence.file_text writes.
export function licenceFile(p: Product, key: string, f: Fields): string {
	const lines = key.match(/.{1,76}/g) ?? [];
	// (the edition is in the signed key whatever this line says; it is named here only when the product sells several)
	const edition = p.editions.length > 1 ? ` (${editionTitle(p, f.edition)})` : "";
	let head = `# ${p.title} licence${edition} for ${f.name}\n# Order ${f.order}, ${f.date}.\n`;
	if (f.updates_until) head += `# Updates until ${f.updates_until}.\n`;
	if (p.fileHint) head += `# ${cleanField(p.fileHint)}\n`;
	return `${head}${lines.join("\n")}\n`;
}

export function licenceFileName(p: Product, order: string): string {
	return order.replace(/[^A-Za-z0-9_-]/g, "_") + p.fileExtension;
}
