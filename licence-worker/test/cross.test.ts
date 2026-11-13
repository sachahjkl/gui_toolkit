// The licences of the Worker against the toolkit's licence package: the texts its tests sign for the same fields
// (src/licence/licence_test.odin), and, when Odin is there, the sample product's tool (test/sample_tool, the toolkit's
// toolbox.licence_commands) run on what the Worker made.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { handle } from "../src/handler.ts";
import { b64urlEncode } from "../src/encoding.ts";
import type { Env } from "../src/env.ts";
import { loadSigner, normalize, productOf } from "../src/licence.ts";
import type { Fields } from "../src/licence.ts";
import { DEV_PUBLIC_KEY, DEV_SEED, OTHER_DEV_SEED, PRICE_PATRON, SAMPLE, TXN, fakeNetwork, fixture, jsonResponse, makeEnv, publicKeyOf, repoRoot, waiter, webhookRequest } from "./helpers.ts";

const odinTest = readFileSync(join(repoRoot, "src", "licence", "licence_test.odin"), "utf8");
function odinConstant(name: string): string {
	// (a constant's line may start with its attribute: `@(private = "file") NAME :: "..."`)
	const m = odinTest.match(new RegExp(`(?:^|\\s)${name}\\s*::\\s*"([^"]+)"`, "m"));
	if (!m) throw new Error(`${name} not found in src/licence/licence_test.odin`);
	return m[1];
}

test("the fixture's product is the Odin tests' product: the same pair, the same texts", () => {
	assert.equal(odinConstant("DEV_SEED"), SAMPLE.dev_seed);
	assert.equal(odinConstant("DEV_PUBLIC_KEY"), SAMPLE.dev_public_key);
	assert.equal(odinConstant("OTHER_SEED"), SAMPLE.other_seed);
	assert.equal(odinConstant("SAMPLE_VECTOR"), SAMPLE.vector.text);
	assert.equal(odinConstant("SAMPLE_VECTOR_UPDATES"), SAMPLE.vector.text_with_updates);
	assert.equal(odinConstant("WREN_VECTOR"), SAMPLE.wren.text);
	assert.equal(odinConstant("WREN_DEV_SEED"), SAMPLE.wren.dev_seed);
});

test("the development pair is the one the Worker signs with (independently derived)", () => {
	assert.equal(publicKeyOf(DEV_SEED), DEV_PUBLIC_KEY);
	assert.notEqual(publicKeyOf(OTHER_DEV_SEED), DEV_PUBLIC_KEY);
	assert.equal(publicKeyOf(Uint8Array.from(Buffer.from(SAMPLE.wren.dev_seed, "base64url"))), SAMPLE.wren.dev_public_key);
});

test("the Worker signs the very text the Odin package signs, with and without years of updates", async () => {
	const p = productOf(makeEnv());
	const signer = await loadSigner(b64urlEncode(DEV_SEED), DEV_PUBLIC_KEY, p);
	assert.equal(await signer.sign(SAMPLE.vector.fields), SAMPLE.vector.text);
	assert.equal(await signer.sign({ ...SAMPLE.vector.fields, updates_until: "2028-10-22" }), SAMPLE.vector.text_with_updates);
	// Wren's settings give the licences Wren's own worker made
	const w = productOf(SAMPLE.wren.vars as unknown as Env);
	const ws = await loadSigner(SAMPLE.wren.dev_seed, SAMPLE.wren.dev_public_key, w);
	assert.equal(await ws.sign(SAMPLE.wren.fields), SAMPLE.wren.text);
	assert.ok(await ws.verify(SAMPLE.wren.text));
	assert.ok(!(await signer.verify(SAMPLE.wren.text)), "another product's text");
});

// The sample product's tool: SAMPLE_TOOL names a built one, else it is built now if Odin is there.
function sampleTool(): string | null {
	const named = process.env.SAMPLE_TOOL;
	if (named) return existsSync(named) ? named : null;
	const out = join(repoRoot, "build", process.platform === "win32" ? "licence_sample_tool.exe" : "licence_sample_tool");
	mkdirSync(join(repoRoot, "build"), { recursive: true });
	const built = spawnSync("odin", ["build", join("licence-worker", "test", "sample_tool"), "-vet", `-out:${out}`], { cwd: repoRoot, encoding: "utf8" });
	return built.status === 0 && existsSync(out) ? out : null;
}

const exe = sampleTool();
const skip = exe ? false : "the sample tool is not available (no SAMPLE_TOOL, and Odin cannot build licence-worker/test/sample_tool)";
const tmp = mkdtempSync(join(process.env.TEMP ?? process.env.TMPDIR ?? ".", "licence-worker-"));

function tool(...args: string[]) {
	const r = spawnSync(exe!, args, { encoding: "utf8" });
	return { code: r.status, out: (r.stdout ?? "") + (r.stderr ?? "") };
}

// Runs the whole webhook, as Paddle would, and returns the licence the Worker made.
async function workerLicence(body: string, customerJson: string) {
	const env = makeEnv();
	const net = fakeNetwork({ "https://sandbox-api.paddle.com/customers/": () => jsonResponse(customerJson) });
	env._deps = net.deps;   // the Paddle customer is read inside the Durable Object, which uses env._deps
	const res = await handle(webhookRequest(body), env, waiter, net.deps);
	assert.equal(res.status, 200);
	return JSON.parse(env.LICENSES.data.get(`txn:${TXN}`)!) as { licence: string; file: string; name: string; order: string };
}

test("a licence made by the Worker verifies with the sample's tool, as a key and as a file", { skip }, async () => {
	const made = await workerLicence(fixture("transaction.completed.json"), fixture("customer.json"));

	const asKey = tool("licence", "verify", `-text:${made.licence}`, "-dev");
	assert.equal(asKey.code, 0, asKey.out);
	assert.match(asKey.out, /VALID: Supporter licence of Jeanne Dupont <jeanne@example\.org>, order SAMPLE-EEP4-4CYR-EWP9, 2026-10-22/);

	const file = join(tmp, "worker.samplelicence");
	writeFileSync(file, made.file);
	const asFile = tool("licence", "verify", file, "-dev");
	assert.equal(asFile.code, 0, asFile.out);
	assert.match(asFile.out, /VALID: Supporter licence of Jeanne Dupont/);
});

test("patron licences and names with accents verify too", { skip }, async () => {
	const body = fixture("transaction.completed.json").replace("pri_01hsxyh9a1fnwv3xbg2zykm4sj", PRICE_PATRON);
	const customer = JSON.stringify({ data: { name: "Zoé Müller-Åkesson 山田", email: "zoe@example.org" } });
	const made = await workerLicence(body, customer);
	const r = tool("licence", "verify", `-text:${made.licence}`, "-dev");
	assert.equal(r.code, 0, r.out);
	assert.match(r.out, /VALID: Patron licence of Zoé Müller-Åkesson 山田 <zoe@example\.org>/u);
});

test("what the sample's tool rejects is rejected: altered, other key, no product key", { skip }, async () => {
	const made = await workerLicence(fixture("transaction.completed.json"), fixture("customer.json"));
	const [tag, payload, sig] = made.licence.split(".");

	const otherPayload = Buffer.from(payload, "base64url").toString().replace("supporter", "patron");
	const altered = `${tag}.${Buffer.from(otherPayload).toString("base64url")}.${sig}`;
	assert.notEqual(tool("licence", "verify", `-text:${altered}`, "-dev").code, 0, "payload altered");

	const badSig = `${tag}.${payload}.${(sig[0] === "A" ? "B" : "A") + sig.slice(1)}`;
	assert.notEqual(tool("licence", "verify", `-text:${badSig}`, "-dev").code, 0, "signature altered");

	assert.notEqual(tool("licence", "verify", `-text:${made.licence}`, `-public:${publicKeyOf(OTHER_DEV_SEED)}`).code, 0, "another public key");
	assert.equal(tool("licence", "verify", `-text:${made.licence}`, `-public:${DEV_PUBLIC_KEY}`).code, 0, "the dev key given by hand");
	assert.notEqual(tool("licence", "verify", `-text:${made.licence}`).code, 0, "the product's key (none in the sample)");
});

// (ASCII names only: on Windows the tool reads its command line in the ANSI code page, so an accent given as an argument
// is not what was typed. The licences of accented names are checked above, from the Worker to the tool.)
test("the Worker and the sample's tool sign the same fields into the very same text", { skip }, async () => {
	const signer = await loadSigner(b64urlEncode(DEV_SEED), DEV_PUBLIC_KEY, productOf(makeEnv()));
	const cases: Fields[] = [
		{ edition: "supporter", name: "Jeanne Dupont", email: "jeanne@example.org", date: "2026-10-22", order: "SAMPLE-0001" },
		{ edition: "patron", name: "Zo \"Zo\" O'Brien \\ <&>", email: "zoe+sample@example.org", date: "2027-01-02", order: "SAMPLE-ABCD-EFGH-JKLM" },
		{ edition: "supporter", name: "x".repeat(256), email: "a@b.co", date: "2026-12-31", order: "o" },
	];
	for (const f of cases) {
		const file = join(tmp, "issued.samplelicence");
		const r = tool("licence", "issue", "-dev", `-name:${f.name}`, `-email:${f.email}`, `-edition:${f.edition}`, `-order:${f.order}`, `-date:${f.date}`, `-out:${file}`);
		assert.equal(r.code, 0, r.out);
		const theirs = normalize(readFileSync(file, "utf8"));
		assert.equal(await signer.sign(f), theirs, `fields: ${JSON.stringify(f)}`);
	}
});

test("the tool's public key for the dev seed is the one the Worker checks against", { skip }, () => {
	const r = tool("licence", "pubkey", "-dev");
	assert.equal(r.code, 0, r.out);
	assert.equal(r.out.split(/\r?\n/)[0].trim(), DEV_PUBLIC_KEY);
});
