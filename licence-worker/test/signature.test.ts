import assert from "node:assert/strict";
import { test } from "node:test";
import type { Env } from "../src/env.ts";
import { addYears, productOf, updatesUntil } from "../src/licence.ts";
import { editionOf, orderNumber, parseSignatureHeader, verifySignature } from "../src/paddle.ts";
import { NOW, SAMPLE, WEBHOOK_SECRET, fixture, paddleSignature } from "./helpers.ts";

const body = fixture("transaction.completed.json");
const check = (b: string, header: string | null, opts: { secret?: string; now?: number; tolerance?: number } = {}) =>
	verifySignature(new TextEncoder().encode(b), header, opts.secret ?? WEBHOOK_SECRET, opts.now ?? NOW, opts.tolerance ?? 300);

test("a valid Paddle-Signature is accepted", async () => {
	assert.equal(await check(body, paddleSignature(body)), "ok");
});

test("a body altered by one byte is rejected", async () => {
	assert.equal(await check(body.replace("2900", "0290"), paddleSignature(body)), "mismatch");
});

test("a signature made with another secret is rejected", async () => {
	assert.equal(await check(body, paddleSignature(body, "pdl_ntfset_other")), "mismatch");
});

test("a signature whose timestamp was changed is rejected", async () => {
	const sig = paddleSignature(body);
	assert.equal(await check(body, sig.replace(/ts=\d+/, `ts=${Math.floor(NOW / 1000) + 1}`)), "mismatch");
});

test("a signature that is too old (or from the future) is rejected, whatever its validity", async () => {
	const old = paddleSignature(body, WEBHOOK_SECRET, Math.floor(NOW / 1000) - 301);
	assert.equal(await check(body, old), "stale");
	assert.equal(await check(body, paddleSignature(body, WEBHOOK_SECRET, Math.floor(NOW / 1000) - 299)), "ok");
	assert.equal(await check(body, paddleSignature(body, WEBHOOK_SECRET, Math.floor(NOW / 1000) + 400)), "stale");
	assert.equal(await check(body, old, { tolerance: 600 }), "ok");
});

test("a missing or malformed header is rejected", async () => {
	assert.equal(await check(body, null), "missing");
	for (const bad of ["", "garbage", "ts=abc;h1=00", "h1=" + "0".repeat(64), `ts=${Math.floor(NOW / 1000)}`, "ts=1;h1="]) {
		assert.notEqual(await check(body, bad), "ok", bad);
	}
	assert.equal(await check(body, `ts=${Math.floor(NOW / 1000)};h1=nothex`), "mismatch");
	assert.equal(await check(body, `ts=${Math.floor(NOW / 1000)};h1=abcd`), "mismatch");
});

test("an empty secret never validates anything", async () => {
	assert.equal(await check(body, paddleSignature(body, ""), { secret: "" }), "malformed");
});

test("during a secret rotation, any of the h1 values may match", async () => {
	const good = paddleSignature(body);
	const header = `ts=${good.match(/ts=(\d+)/)![1]};h1=${"0".repeat(64)};${good.split(";")[1]}`;
	assert.equal(await check(body, header), "ok");
});

test("the header is parsed leniently around its separators", () => {
	assert.deepEqual(parseSignatureHeader(" ts=12 ; h1=ab "), { ts: "12", h1: ["ab"] });
	assert.equal(parseSignatureHeader("h1=ab"), null);
});

test("editions come from the price ids, the highest rank first", () => {
	const p = { prices: { pri_a: "supporter", pri_b: "supporter", pri_p: "patron" }, editions: [{ id: "supporter", title: "Supporter" }, { id: "patron", title: "Patron" }] };
	assert.equal(editionOf([{ price_id: "pri_a" }], p), "supporter");
	assert.equal(editionOf([{ price: { id: "pri_b" } }], p), "supporter");
	assert.equal(editionOf([{ price_id: "pri_a" }, { price_id: "pri_p" }], p), "patron");
	assert.equal(editionOf([{ price_id: "pri_p" }, { price_id: "pri_a" }], p), "patron");
	assert.equal(editionOf([{ price_id: "pri_x" }], p), null);
	assert.equal(editionOf([], p), null);
	assert.equal(editionOf([{ price_id: "" }], { prices: {}, editions: [] }), null);
});

test("the order number is readable, follows the transaction and starts with the product's prefix", () => {
	assert.equal(orderNumber("SAMPLE", "txn_01hv8wptq8987qeep44cyrewp9"), "SAMPLE-EEP4-4CYR-EWP9");
});

test("the product comes from the settings; editions default to those of PRICES", () => {
	const p = productOf({ ...SAMPLE.vars, UPDATE_YEARS: "2", UPDATES_FROM: "2027-03-01" } as unknown as Env);
	assert.equal(p.name, "sample");
	assert.equal(p.signContext, "sample-licence-v1\n");
	assert.deepEqual(p.editions.map((e) => e.id), ["supporter", "patron"]);
	assert.equal(updatesUntil(p, "2026-10-22"), "2029-03-01", "bought before UPDATES_FROM");
	assert.equal(updatesUntil(p, "2027-06-30"), "2029-06-30");
	assert.equal(addYears("2028-02-29", 2), "2030-02-28");
	assert.equal(addYears("2028-02-29", 4), "2032-02-29");
	const bare = productOf({ PRODUCT: "app", PRICES: '{"pri_1":"basic","pri_2":"pro"}' } as unknown as Env);
	assert.deepEqual(bare.editions, [{ id: "basic", title: "basic" }, { id: "pro", title: "pro" }]);
	assert.equal(bare.orderPrefix, "APP");
	assert.equal(bare.title, "app");
	assert.equal(updatesUntil(bare, "2026-10-22"), "", "no UPDATE_YEARS: every version");
});
