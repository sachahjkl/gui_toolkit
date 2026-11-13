# The licence Worker

A Cloudflare Worker (TypeScript, no runtime dependency) that turns a paid Paddle transaction into a program's licence: it
verifies the `Paddle-Signature` of the webhook, reads the customer from the Paddle API, signs the licence (Ed25519, the
format of the toolkit's `src/licence/licence.odin`), keeps it in KV, mails it with Cloudflare Email Service (the
`send_email` binding) and serves it to the thank-you page.

One codebase, **one deploy per product**: everything that names a program is a setting of its file
`products/<program>.jsonc`. The whole flow (keys, the program's side, the site, the secrets) is in
[docs/licence.md](../docs/licence.md).

Each purchase is handled by **one `LicenseOrder` Durable Object** (`env.ORDERS.idFromName(txn)`), whose input gate
serialises everything done for that transaction: a webhook delivered twice at the same instant issues one licence and
sends one mail. The object owns the **mail retry queue** (its alarm, exponential backoff, an attempt cap, then a
dead-letter), reports **bounces** (`POST /mail/bounce`) and **purges the buyer's name and address** after
`PII_RETENTION_DAYS`. KV stays as the globally-replicated copy the thank-you page reads.

## Routes

| Route | What it does |
|---|---|
| `POST /paddle/webhook` | Paddle Billing notifications (signed); `transaction.completed` issues the licence |
| `GET /licence?txn=txn_…` | the licence of a transaction as JSON, for the thank-you page (202 until it exists) |
| `GET /licence/txn_…<FILE_EXTENSION>` | the same as a file to download |
| `POST /resend` | `{"email": …}` mails the licences bought with that address again (off unless `RESEND_ENABLED`) |
| `GET /admin/dead-letter`, `POST /admin/dead-letter/retry` | the mails that gave up (`Bearer ADMIN_TOKEN`) |
| `POST /mail/bounce` | the mail provider's delivery webhook (`MAIL_BOUNCE_SECRET`) |
| `GET /health` | `{"ok": bool, "missing": [settings not set]}` |

## A product

1. Write `products/<program>.jsonc` with the program's tool: `<tool> licence worker products/<program>.jsonc
   -origin:URL -mail:"Name <address>"` (from its `licence.Product`), or copy `products/example.jsonc`. Set every value marked `SET`: the product's values are
   the program's `licence.Product` (`PRODUCT`, `VERSION_TAG`, `SIGN_CONTEXT`, `FILE_EXTENSION`, `EDITIONS`,
   `UPDATE_YEARS`, `LICENSE_PUBLIC_KEY`), the shop's are `PRICES` (what `<tool> paddle -apply` prints), `ALLOWED_ORIGIN`
   (the site), `MAIL_FROM`. The sandbox block takes the development pair's public key and the sandbox's price ids.
2. The mail: `MAIL_SUBJECT` and `MAIL_TEXT` take placeholders, replaced in one pass: `{hello}`, `{name}`,
   `{licensed_to}`, `{title}`, `{edition}`, `{edition_title}`, `{key}`, `{order}`, `{date}`, `{updates_until}`,
   `{updates}` (a line, or nothing), `{file_name}`. Empty: the neutral text of `licence-worker/src/mail.ts`.
3. The secrets, decrypted from the program's sops file (the program's tool, docs/licence.md):

   ```sh
   <tool> licence secrets secrets/production.yaml <toolkit>/licence-worker/secrets.env
   <tool> licence secrets secrets/development.yaml <toolkit>/licence-worker/secrets.sandbox.env
   ```

4. Deploy, from this folder (`pnpm install` once). With `cf`:

   ```sh
   LICENCE_PRODUCT=<program> cf deploy --mode sandbox --secrets-file secrets.sandbox.env
   LICENCE_PRODUCT=<program> cf deploy --secrets-file secrets.env
   ```

   Or with `wrangler`, which reads the product's file as it is:

   ```sh
   npx wrangler secret bulk secrets.sandbox.env -c products/<program>.jsonc --env sandbox
   npx wrangler deploy -c products/<program>.jsonc --env sandbox
   npx wrangler secret bulk secrets.env -c products/<program>.jsonc
   npx wrangler deploy -c products/<program>.jsonc
   ```

5. Remove the `secrets*.env` files. `GET https://<program>-licence.<account>.workers.dev/health` says what is missing.

The first deploy runs the `v1` migration of the Durable Object (SQLite-backed class): it needs the **Workers Paid** plan.
The names `LICENSES`, `ORDERS`, `LicenseOrder` and `LICENSE_*` are those of the deploys made so far: a new name would need
a migration of their stored orders.

## Tests

```sh
node --test "test/*.test.ts"        # no network
```

They run with a sample product (`test/fixtures/sample-product.json`), whose constants are those of the Odin package's
tests (`src/licence/licence_test.odin`): `cross.test.ts` checks that the Worker signs the very texts the Odin package
signs, and, when Odin is there, runs the sample product's tool (`test/sample_tool`) on what the Worker made
(`SAMPLE_TOOL=<built tool>` names one already built).

- `src/`: `handler.ts` (routes), `order.ts` (the `LicenseOrder` Durable Object: idempotence, the retry queue, the purge),
  `issue.ts` (transaction to signed record), `paddle.ts`, `licence.ts` (the product, the format), `mail.ts`, `store.ts` (KV).
- `cloudflare.config.ts` is what `cf` reads: it builds its configuration from `products/<LICENCE_PRODUCT>.jsonc`.
