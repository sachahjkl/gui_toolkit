# licence: a program's paid licence

A program of the toolkit can sell a licence. The licence is a signed key: the program checks the signature itself, on the
user's computer, with no network. The program's source code stays public under its own licence; a purchase changes
nothing about it.

The pieces, one per concern:

| Piece | Where | What it does |
|---|---|---|
| `gt:licence` (package `tk_licence`) | `src/licence` | the key's format, its check, its store in the user's folder (the program) |
| the tool's commands | `src/toolbox/licence.odin` | the key pair, a licence issued by hand, a check, the Paddle catalogue, the Worker's secrets |
| the Worker | `licence-worker/` | a Cloudflare Worker: Paddle's webhook to a signed licence, kept, mailed, shown. One deploy per product |
| the pages | `src/site/licence.odin` | the pricing page's buy block, the thank-you page, six template pages |
| the secrets | the program's `secrets/` | the private key and Paddle's keys, encrypted with sops |

The flow of a purchase: the pricing page opens Paddle's checkout; Paddle reports the paid transaction to the Worker; the
Worker signs the licence, mails it and keeps it; the thank-you page asks the Worker for it and shows it; the user pastes
the key in the program, or opens the file.

## The key

```
<VERSION_TAG>.<payload>.<signature>
```

- `payload`: base64url, no padding, of the JSON `{"product":..,"edition":..,"name":..,"email":..,"date":..,"order":..}`, in
  this order with no space, and `"updates_until"` for a product that counts its years of updates. A field the program does
  not know is ignored.
- `signature`: base64url, no padding, of the Ed25519 signature over the product's `sign_context` followed by the payload's
  bytes exactly as they are in the text. Nothing is canonicalized; a signature made for another use (an update manifest)
  cannot pass for a licence.
- White space, quotes and lines that start with `#` are ignored (`normalize`): a key wrapped in a mail, or the file with
  its comment lines, reads as the key.

`verify(product, text, public_key = "")` checks the format, the signature (with `public_key`, or the product's), then reads
the payload and refuses a licence of another product. `sign(product, seed, licence)` makes a key (the tool and the tests);
`sign_payload` signs any payload (the tests' damaged ones). The keys are text of the package `signing`
([signing.md](signing.md)): `signing.public_key_of(seed)`, `signing.key_decode`, `signing.key_encode`. `file_text(product,
licence, key, hint)` is the text of a licence file: comment lines that say whose it is, then the key wrapped at 76 columns. `payload_of` is the payload's JSON: the Worker makes the same bytes. `signed_bytes(product,
payload)` is what the signature covers. A `Licence` that `verify` returns is owned by its allocator: `licence_destroy` frees it.

`Error` names what is wrong: `Empty`, `Too_Long`, `Bad_Format`, `Bad_Encoding`, `Bad_Payload`, `Wrong_Product`,
`Bad_Signature`, `No_Public_Key`, `Bad_Public_Key`, and for the store `Not_Read` and `Not_Written`. `error_text(e)` gives
neutral words that name no product; a program can word its own.

## The program's side

The program describes its licence once, as a constant:

```odin
import licence "gt:licence"

LICENCE :: licence.Product{
	name           = "app",                    // the payload's "product"
	title          = "App",                    // the program's name in the file's comment lines
	version_tag    = "APP1",
	sign_context   = "app-licence-v1\n",
	file_extension = ".applicence",
	public_key     = "",                       // `<tool> licence pubkey`: empty until the pair is made
	dev_public_key = "…",                      // the development pair's: public on purpose
	editions       = {0 = {id = "standard", title = "Standard"}},
	update_years   = 2,                        // 0: every version
}
```

`editions` lists the editions in the order of their rank, the highest last; `edition_known`, `edition_rank` and
`edition_title` read it. A licence of an edition the build does not know is still read: an older build keeps working with a
newer licence.

### The store

A `Store` keeps the licence in a small file: `licence<ext>` in `platform.user_dir(.Config, program)`. Every procedure of
the store that touches the file blocks on the disk: call it in a task (`ui.task`, docs/tasks.md), never on the interface's
thread. The store's own lock keeps one operation at a time, so the interface and its tasks can share it.

```odin
app.licences = new(licence.Store)
licence.store_init(app.licences, {product = LICENCE, released = APP_RELEASED, accept_dev = ODIN_DEBUG})

// the status, read in a task; the interface shows the last one it got
ui.task(&app.ui, proc(d: rawptr) {
	a := (^App)(d)
	a.next = licence.store_read(a.licences, runtime.heap_allocator())
}, proc(d: rawptr, _: u64) {
	a := (^App)(d)
	licence.status_destroy(&a.status, runtime.heap_allocator())
	a.status = a.next
}, app)
```

| Procedure | What it does |
|---|---|
| `store_init(s, o)`, `store_destroy(s)` | the store; it copies the options' strings |
| `store_read(s, allocator)` | the `Status`: `stored`, `registered`, `covered`, `err`, the `licence` (`status_destroy` frees it) |
| `store_install(s, text)` | checks the key and keeps it, normalized; nothing is written when it does not check out |
| `store_install_file(s, path)` | reads a licence file (dropped, given on the command line, chosen in a dialog) and installs it |
| `store_remove(s)` | removes the licence |
| `store_path(s, allocator)` | the file (`""`: memory only) |
| `store_check(s, text, allocator)` | the check of the store (its key, the development pair when accepted): no file, any thread |
| `is_licence_file(product, path)` | the path ends with the product's extension: install it instead of opening it |
| `file_dialog(product, title, filter_name)` | the Open dialog of a licence file, for `ui.file_dialog` |

`Store_Options`:

| Field | What it is |
|---|---|
| `product` | the `Product` |
| `program` | the folder in the user's configuration folder (`""`: the product's name) |
| `path` | the file (`""`: `licence<ext>` in that folder) |
| `memory` | kept in memory only: a profile that is not kept |
| `public_key` | checks with this key instead of the product's: a fork that sells its own, a test |
| `accept_dev` | the product's `dev_public_key` is accepted too: a development build, never a release |
| `seed` | the licence a build is handed out with (`#config`), put in place once |
| `released` | the day this version was released, for `Status.covered` |

The seed is put in place once: only when nothing is stored and it was never put there. A marker beside the file
(`SEED_MARKER`) says it was, so a user who removes it keeps it removed, and a licence the user installs replaces it. A
store that holds a licence keeps its own. A seed the store does not accept goes nowhere.

The file dialog of the program, then the install, both off the interface's thread:

```odin
ui.file_dialog(&app.ui, .Open, licence.file_dialog(LICENCE, "Choose a licence file", "App licence"), proc(r: platform.Dialog_Result, user: rawptr) {
	if r.status != .Chosen || len(r.paths) == 0 { return }
	install_file_in_a_task((^App)(user), r.paths[0])   // (copy the path: it is freed after the call)
}, app)
```

### Years of updates

A product whose terms promise N years of updates sets `update_years`. Its licences then carry `updates_until`, the last
release day they cover: the date of the purchase plus N years, or `updates_from` plus N years for a licence bought before
that day. The day is signed: what a licence covers does not change when the product's constant changes later.

- `updates_until_of(product, licence)`: the licence's own day, else the one the product counts (`""`: every version).
- `covers(product, licence, released)`: the updates cover a version released on that day.
- `date_valid`, `date_add_years`: ISO days; the 29th of February becomes the 28th in a year that has none.

The store says it as `Status.covered`, from `Store_Options.released`. What a program does with a licence that does not
cover its version is the program's choice.

## The tool's side

A program's tool has the commands `licence` and `paddle` (docs/toolbox.md, "A project's tool"):

```odin
LICENCE_TOOL :: toolbox.Licence_Tool{
	product  = LICENCE,
	dev_seed = "…",   // the development pair's private key: public on purpose (tests, screenshots, the sandbox)
	hint     = "Open this file with App, or paste the key in Help > Licence.",
	paddle   = {name = "App User License", description = "A personal, perpetual licence of App.", amounts = "standard=2900", currency = "EUR"},
}

main :: proc() {
	l := toolbox.licence_commands(LICENCE_TOOL)
	toolbox.tool_main("apptool", {/* the project's commands */ l[0], l[1]}, toolbox.ROOT_MARK_DEFAULT)
}
```

```
apptool licence keygen [-private:FILE] [-force]
apptool licence pubkey [-private:FILE | -dev]
apptool licence issue -name:N -email:E -edition:ID -order:ID [-date:YYYY-MM-DD] [-private:FILE | -dev] [-out:FILE]
apptool licence verify FILE | -text:KEY [-public:KEY | -dev]
apptool licence secrets <secrets.yaml> <out.env> [-keys:A,B]
apptool paddle [-apply] [-environment:sandbox|live] [-name:N] [-description:D] [-amounts:ID=CENTS,...] [-currency:C]
```

- `keygen` writes the private key in `licence_key_dir(tool)`: `Licence_Tool.key_dir`, else `<product>-licence` in the
  user's configuration folder (Linux `~/.config/<product>-licence`, Windows `%APPDATA%\<product>-licence`). It refuses a
  path in a git work tree, and an existing key without `-force` (a new key makes every issued licence invalid). It prints
  the public key: put it in the program's `Product.public_key` and in the Worker's `LICENSE_PUBLIC_KEY`. Keep a backup of
  the private key outside the computer, and put it in the program's `secrets/production.yaml`.
- `issue` signs a licence by hand (a gift, a replacement), checks it as the program would, writes its file
  (`<key dir>/issued/<order><ext>` by default) and prints the key.
- `verify` checks a key or a file with the product's key, `-public:KEY` or the development pair.
- `-dev` uses `Licence_Tool.dev_seed`, never the production key.
- `secrets` is described in "Secrets" below; `paddle` in "The Paddle catalogue".

The procedures behind them: `licence_keygen`, `licence_pubkey`, `licence_issue`, `licence_verify`, `sops_dotenv`,
`dotenv_keep`, `paddle_amounts`, `paddle_product_body`, `paddle_price_body`, `paddle_prices_setting`.

## The Paddle catalogue

`paddle` makes the product and one price per edition in Paddle's catalogue, over `gt:http`: one payment (no billing cycle,
no trial), the tax in the price, a quantity of one, the edition in the price's custom data. Without `-apply` it prints
what it would send and sends nothing. With `-apply` it needs `PADDLE_API_KEY` (`PADDLE_KEY_ENV`): a server-side key with
the product and price rights, never saved. It is safe to run again: a product of this name, and a price of this edition,
amount and currency, are reused. It prints the Worker's `PRICES` setting and the price ids of the site's buy block. Revoke
the key in Paddle once the ids are noted: the Worker has its own key.

## The Worker

`licence-worker/` is one codebase for every product: each product has its file `products/<program>.jsonc` and its own
deploy (`licence-worker/README.md`). Its settings that name the product are the values of the program's `Product`:

| Setting | From |
|---|---|
| `PRODUCT`, `PRODUCT_TITLE`, `VERSION_TAG`, `SIGN_CONTEXT`, `FILE_EXTENSION` | `name`, `title`, `version_tag`, `sign_context`, `file_extension` |
| `EDITIONS` | `editions`, as JSON, lowest rank first |
| `UPDATE_YEARS`, `UPDATES_FROM` | `update_years`, `updates_from` |
| `LICENSE_PUBLIC_KEY` | `public_key` (the sandbox: `dev_public_key`) |
| `PRICES` | what `paddle -apply` prints: Paddle's price ids and their edition |
| `ORDER_PREFIX` | the order numbers' start (`APP-XXXX-XXXX-XXXX`) |
| `MAIL_FROM`, `MAIL_SUBJECT`, `MAIL_TEXT`, `FILE_HINT`, `ALLOWED_ORIGIN` | the mail and the site |

Its routes: `POST /paddle/webhook`, `GET /licence?txn=` (the thank-you page), `GET /licence/<txn><ext>` (the file),
`POST /resend`, `GET /health` (the settings that are missing), and the admin and bounce routes. Each purchase is handled by
one Durable Object: a webhook delivered twice issues one licence and sends one mail. The buyer's name and address are
removed after `PII_RETENTION_DAYS`.

Its tests run with a sample product whose constants are those of `src/licence/licence_test.odin`: the Worker signs the very
texts the Odin package signs for the same fields, with and without years of updates, and Wren's settings give Wren's
licences.

## The site

The pricing and thank-you pages hold marks (`LICENCE_BUY_MARK`, `LICENCE_THANKS_MARK`); `with_licence(page, shop)` puts the
blocks there, in the site's build. A program sells one licence at one price, so the pages are made for one offer.
`licence_buy_block(shop)` is the offer's card: the price large with "once, taxes included" beside it, what the licence
gives as Wren's list with check marks (no subscription, the versions that `update_years` covers, the offline check), each
line with a small "i" that links the pricing page's question about it (`#q-once`, `#q-versions`, `#q-offline`), one
button (`data-edition`, `data-price`, `data-label`), the fine print, and the script
that opens Paddle's checkout (an overlay; Paddle.js is loaded at the first press) and goes to the thank-you page with the
transaction id. `licence_thanks_block(shop)` asks the Worker for the licence until it is ready, then shows who it is for, the
order, the key, a download of the file and a copy button; every value is put as text. Its `data-state` (`waiting`,
`ready`, `failed`) shows a spinner only while it waits. Under it, Wren's help block: "A problem with your license? We are
here.", an "Ask for help" button (`help`) and the way back to the pricing page.

While the client token, the price id, the Worker's address or the thank-you page is missing, the button says "Coming soon"
and does nothing (`shop_open` says the same): a site can be published before the shop is open.

`Shop` holds the words and addresses:

| Field | What it is |
|---|---|
| `name` | the program, as it writes its name (`"cliche"`): the pages show it as it is, never mixed into a Title Case heading |
| `icon` | the program's icon from a template page (`"../img/logo.png"`): the hero and the bar show it; `""`: none |
| `product_title` | what Paddle sells (`"Cliche User License"`: the name capitalised, each word of it): the legal pages name it, no heading does |
| `price` | HTML, as shown (`"15&nbsp;&euro;"`) |
| `price_note` | HTML, an extra line under the price (`"Launch price until 1.0."`); `""`: none |
| `environment`, `client_token` | Paddle's (`"sandbox"` or `"production"`; `test_...` or `live_...`) |
| `edition`, `price_id` | the licence's edition id and its Paddle price (`pri_...`, `""` until `paddle -apply` makes it) |
| `buy_label` | the button's words (`""`: `BUY_LABEL`, "Buy license") |
| `worker`, `thanks`, `help` | the licence Worker, the thank-you page (absolute), where a buyer asks for help |
| `register` | HTML: how to register a licence in the program (the thank-you page says it) |
| `extension` | the licence file's extension |
| `repository` | the program's source: the footer and the imprint link it |
| `seller` | a `Seller`, below: the imprint's facts |
| `code_licence` | the licence of the program's source, its whole name (`"MIT License"`) |
| `platform` | HTML: the systems the program runs on, the pricing page's "Platform" |
| `network` | HTML: what the program connects to, for the privacy policy (`""`: "name connects to nothing by itself.") |
| `update_years`, `retention_days` | the years of updates (0: every version), the days the Worker keeps a buyer's name and address (0: 90) |
| `stylesheet`, `home`, `updated` | from a template page: the site's stylesheet, its home; the day the terms last changed |

`Seller` is the same block in every program of one seller (Froment Software's programs copy Wren's imprint):

| Field | What it is |
|---|---|
| `name` | the trade name (`"Froment Software"`) |
| `owner`, `status` (HTML) | the person who trades under it and the legal form (`"sole proprietor (<em>entrepreneur individuel</em>)"`); `""`: a company |
| `address` (HTML), `email`, `url` | the address, the contact, the seller's site (the imprint shows it without `https://`, and names its domain as the one Cloudflare manages) |
| `siren`, `siret`, `ape` | the French company numbers and the activity code with its words (`"6201Z, computer programming"`); `""`: not said |
| `registry` (HTML), `registered` | the register the seller is in and the day ("Registered with ... on ...") |
| `vat` (HTML) | what follows "VAT: ", a number or why there is none (`"not applicable, article 293 B of the French General Tax Code (<em>franchise en base de TVA</em>)"`) |

`src/site/licence_pages/` holds six template pages in neutral words: pricing, thanks, terms, refunds, privacy, imprint,
with `{{placeholders}}` (`licence_values` lists them). A program copies them into its site and adapts them, or
`licence_pages(shop)` fills them (`fill_placeholders`, one pass) and gives the six `Page`s. Their legal words are a starting
point: have them checked for your situation.

Their words are Wren's, the reference for every shop page: what a reader sees writes "license" (US English), the code
keeps its names. The pricing page is a hero (the icon, a quiet "Pricing" label, the program's name large, one line), the
offer's card, "Before you buy" (the seller, the platform, the license, the delivery, the withdrawal, the checkout, the
code, the terms, questions), then the questions (the versions, work, subscription, the offline check, the code, how to
register). The thank-you page thanks the buyer for supporting the program. The four legal pages are Wren's, with a "Legal"
label and "Last updated" (`updated`): the license terms (what you buy, delivery, the key, seller and payment, warranty,
questions), the refunds (Paddle handles them, the statutory withdrawal, the effect on the license), the privacy policy
(the program, the site, the purchase, the rights) and the imprint (publisher, responsible for the content, hosting,
payments, software and licenses, consumer disputes). Every page has
a bar with the program's name and a foot with the home, the shop's pages in the order of the site's footer (`SHOP_LINKS`),
GitHub (`Shop.repository`) and the seller. Its title is "Pricing · name": the nav's word ([site.md](site.md), "The nav and
the footer"). A program gives its `Shop` as `Meta.shop`, and `build_changelog` writes the pages. Their style is `LICENCE_CSS` (`src/site/licence_css.odin`),
put in each page's head by `{{shop_css}}`: it brings no colour of its own and reads the site's custom properties (`--text`,
`--muted` or `--weak`, `--soft` or `--faint`, `--surface` or `--bg2`, `--surface-2` or `--bg3`, `--line-2` or `--line`,
`--accent`, `--accent-ink`), so each program keeps its accent and its light theme, and writes no CSS for these pages. A site
whose accent is dark sets `--accent-ink`, the text on the button (near black otherwise). Its classes start with `shop-`. A
program that keeps its own pages puts `LICENCE_CSS` in its stylesheet and `class="shop-page"` on their body.

## Secrets

Each program keeps its secrets in its repository, encrypted with sops for the maintainer's age key:

```
<program>/.sops.yaml              licence-worker/templates/sops.yaml: the maintainer's age recipient (a public key)
<program>/secrets/README.md       licence-worker/templates/secrets/README.md
<program>/secrets/development.yaml  the development pair, the sandbox's Paddle keys
<program>/secrets/production.yaml   LICENSE_PRIVATE_KEY, PADDLE_WEBHOOK_SECRET, PADDLE_API_KEY (live)
```

The age identity stays outside every repository (`~/.config/sops/age/keys.txt`). `licence secrets` feeds the Worker's
deploy:

```sh
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
apptool licence secrets secrets/production.yaml <toolkit>/licence-worker/secrets.env
```

It runs `sops --decrypt --output-type dotenv`, keeps the Worker's secrets only (`WORKER_SECRETS`, or `-keys:A,B`), writes a
file readable by its user only, and refuses a path that git does not ignore. It prints the names it wrote, never a value.

## What the maintainer does at the end

Everything above is ready; these steps need the maintainer's accounts:

1. The keys: `apptool licence keygen`; put the public key in the program's `Product.public_key`; put the private key's line
   in `secrets/production.yaml` (`LICENSE_PRIVATE_KEY`), the development pair's in `secrets/development.yaml`.
2. Paddle: `PADDLE_API_KEY=… apptool paddle -apply` (the sandbox), then `-environment:live`. Note the price ids.
3. Paddle: a client-side token (Developer tools > Authentication), a notification destination for
   `transaction.completed` at `https://<program>-licence.<account>.workers.dev/paddle/webhook`; its secret and a server-side
   key with `customer.read` go in the sops file.
4. The Worker: `apptool licence worker <toolkit>/licence-worker/products/<program>.jsonc -origin:https://<site>
   -mail:"App <licence@mail.<domain>>"` writes its file from the program's `Product` (make it again rather than edit
   the product's values), then the price ids and the public key where it says SET; `apptool licence secrets`; deploy
   the sandbox, then production (`licence-worker/README.md`); `GET /health` says what is missing.
5. The site: `Shop` with the client token, the price id (`price_id`), the Worker's address; the pages built and published.
6. A purchase in the sandbox, from the pricing page to the key in the program.
