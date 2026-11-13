package tk_site

// The pages of a program's shop (docs/licence.md): the buy block of its pricing page (Paddle's checkout, its overlay) and the
// thank-you block that asks the licence Worker for the licence just bought. A program's page holds the marks; with_licence
// puts the blocks there. The template pages (licence_pages/*.html: pricing, thanks, terms, refunds, privacy, imprint) are
// whole pages in neutral words that a program copies into its site, or that licence_pages fills for it. Their style is
// LICENCE_CSS (licence_css.odin), drawn from the site's own colours, so a program writes no CSS for them.
//
// A program sells one licence at one price: the pages are made for one offer and one button.
//
//   <!-- licence-buy -->      the offer: the price, what the licence gives, the button and the script that opens the checkout
//   <!-- licence-thanks -->   the licence of the purchase: who, the order, the key, a download, a copy button
//
// While Paddle's client token, the price id or the Worker's address is missing, the button says "Coming soon" and does
// nothing: a site can be published before the shop is open.

import "core:fmt"
import "core:strings"

LICENCE_BUY_MARK    :: "<!-- licence-buy -->"
LICENCE_THANKS_MARK :: "<!-- licence-thanks -->"

// The words of the buy button and of the nav's shop entry (frame.odin), as Wren says them.
BUY_LABEL :: "Buy license"

// What a program's shop is, for its pages. HTML fields say so; the others are text, escaped where they go.
Shop :: struct {
	name:           string,         // the program, as it writes its name ("app"): the pages show it as it is
	icon:           string,         // the program's icon from a template page ("../img/logo.png"); "": none shown
	product_title:  string,         // what Paddle sells ("App User License": the name capitalised, as Wren's "Wren User License"): the legal pages name it, never a heading
	price:          string,         // HTML, as shown ("29&nbsp;&euro;"); the page says "once, taxes included" beside it
	price_note:     string,         // HTML, an extra line under the price ("Launch price until 1.0."); "": none
	environment:    string,         // Paddle's: "sandbox" or "production"
	client_token:   string,         // Paddle's client-side token (test_... or live_...); "": coming soon
	edition:        string,         // the licence's edition id ("standard"), as in the program's licence.Product
	price_id:       string,         // Paddle's price ("pri_..."): "" until it is made (`<tool> paddle -apply`)
	buy_label:      string,         // the button's words ("": "Buy license")
	worker:         string,         // the licence Worker's address, no final "/" ("https://app-licence.<account>.workers.dev")
	thanks:         string,         // the absolute address of the thank-you page
	help:           string,         // where a buyer asks for help (an address)
	register:       string,         // HTML: how to register a licence in the program (the thank-you page says it)
	extension:      string,         // the licence file's extension (".applicence")
	repository:     string,         // the program's source, linked in the footer and the imprint ("": not linked)
	seller:         Seller,         // who sells, through Paddle: the imprint's facts
	code_licence:   string,         // the licence of the program's source code, its whole name ("MIT License"); a purchase does not change it
	platform:       string,         // HTML: the systems the program runs on ("Windows 10 or 11, x64, and Linux, x64")
	network:        string,         // HTML: what the program connects to, for the privacy policy ("": nothing but what the user opens)
	update_years:   int,            // 0: every version; N: the versions released in the N years after the purchase
	retention_days: int,            // the days the Worker keeps a buyer's name and address (0: 90, its PII_RETENTION_DAYS)
	stylesheet:     string,         // the site's stylesheet from a template page ("../style.css")
	home:           string,         // the site's home from a template page ("../")
	updated:        string,         // the day the terms last changed ("2026-11-13")
}

// The seller, as its imprint names it: the same block in every program of one seller.
Seller :: struct {
	name:       string,   // the trade name ("Example Software")
	owner:      string,   // the person who trades under it ("Jane Doe"; "": the name is a company's)
	status:     string,   // HTML: the owner's legal form ("sole proprietor (<em>entrepreneur individuel</em>)")
	address:    string,   // HTML: the address, its lines joined by ", " or "<br>"
	email:      string,   // the contact address
	url:        string,   // the seller's site ("https://example.org"): the imprint shows it without "https://"
	siren:      string,   // the French company numbers ("": not said)
	siret:      string,
	ape:        string,   // the activity code and its words ("6201Z, computer programming")
	registry:   string,   // HTML: the register the seller is in ("the French national register of companies (RNE)")
	registered: string,   // the day of the registration, as the imprint says it ("23 October 2026")
	vat:        string,   // HTML: what the imprint says after "VAT: ", a number or why there is none
}

// The buy block: a card with the price, what the licence gives, one button and the fine print, with what the script needs
// in data-* attributes, then the script. The button says "Coming soon" until the script finds the shop open.
licence_buy_block :: proc(s: Shop) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, `<div class="shop-offer" id="buy" data-environment="`, esc(s.environment), `" data-client-token="`, esc(s.client_token),
		`" data-worker="`, esc(strings.trim_right(s.worker, "/")), `" data-thanks="`, esc(s.thanks), `">`, "\n")
	put(&b, `  <h2 class="shop-offer-label" id="buy-title">Personal license</h2>`, "\n")
	put(&b, `  <p class="shop-price"><span class="shop-amount">`, s.price, `</span><span class="shop-once">once,<br>taxes included</span></p>`, "\n")
	if s.price_note != "" { put(&b, `  <p class="shop-price-note">`, s.price_note, "</p>\n") }
	put(&b, `  <ul class="shop-gets">`, "\n")
	for line in licence_gets(s) { put(&b, `    <li>`, SHOP_CHECK_SVG, `<span>`, line, "</span></li>\n") }
	put(&b, "  </ul>\n")
	label := s.buy_label != "" ? s.buy_label : BUY_LABEL
	put(&b, `  <button class="shop-buy" type="button" data-edition="`, esc(s.edition), `" data-price="`, esc(s.price_id),
		`" data-label="`, esc(label), `" disabled>Coming soon</button>`, "\n")
	put(&b, `  <p class="shop-status" id="buy-note" role="status" hidden></p>`, "\n")
	put(&b, `  <p class="shop-fine">By placing your order you accept the <a href="../terms/">license terms</a>. Sold by Paddle.com as Merchant of Record and reseller: <a href="https://www.paddle.com/legal/buyer-terms">buyer terms</a>, <a href="https://www.paddle.com/legal/privacy">privacy</a>, <a href="https://www.paddle.com/legal/refund-policy">refunds</a>.</p>`, "\n")
	put(&b, "</div>\n<script>\n", LICENCE_BUY_SCRIPT, "</script>")
	return strings.to_string(b)
}

// What the licence gives, as the offer's list says it (HTML, each line short enough for a phone). Each line links the
// question of the pricing page that tells more (licence_pages/pricing.html: #q-once, #q-versions, #q-offline).
@(private = "file")
licence_gets :: proc(s: Shop) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out, cat("No subscription, no renewal, no expiry", info_link("q-once", "More about the one payment")))
	switch {
	case s.update_years == 1: append(&out, cat("A year of updates: every version released in it", info_link("q-versions", "More about the versions it covers")))
	case s.update_years > 1:  append(&out, cat(fmt.tprintf("%d years of updates: every version released in them", s.update_years), info_link("q-versions", "More about the versions it covers")))
	case:                     append(&out, cat("Every future version, at no extra cost", info_link("q-versions", "More about the versions it covers")))
	}
	append(&out, cat("Checked offline, on your computer", info_link("q-offline", "More about the offline check")))
	return out[:]
}

// The small "i" after a line of the offer: a link to the question that tells more.
@(private = "file")
info_link :: proc(question, label: string) -> string {
	return cat(` <a class="shop-info" href="#`, question, `" aria-label="`, label, `" title="`, label, `">i</a>`)
}

// The check mark of the offer's list: a disc and a tick in the accent's colour (currentColor), drawn without a file.
@(private = "file")
SHOP_CHECK_SVG :: `<svg class="shop-check" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="10" fill="currentColor" opacity="0.16"/><path d="M5.8 10.4l2.8 2.8 5.6-6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`

// The thank-you block: the status while the Worker makes the licence, then the licence card, from GET /licence?txn=.
// data-state ("waiting", "ready", "failed") lets the style show a spinner only while the script waits.
licence_thanks_block :: proc(s: Shop) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, `<div class="shop-thanks" id="licence-thanks" data-state="waiting" data-worker="`, esc(strings.trim_right(s.worker, "/")), `" data-poll-seconds="3" data-give-up-seconds="150" data-help="`, esc(s.help), `">`, "\n")
	put(&b, `  <p class="shop-wait"><span class="shop-spinner" aria-hidden="true"></span><span id="status" role="status">Making your license&hellip;</span></p>`, "\n")
	put(&b, `  <div id="licence" hidden>`, "\n")
	put(&b, `    <div class="shop-card">`, "\n")
	put(&b, `      <h2 class="shop-who" id="who"></h2>`, "\n")
	put(&b, `      <dl class="shop-meta"><div><dt>Order</dt><dd id="order"></dd></div><div><dt>Date</dt><dd id="date"></dd></div><div id="updates-row" hidden><dt>Updates until</dt><dd id="updates"></dd></div></dl>`, "\n")
	put(&b, `      <p class="shop-key-label">Your key</p>`, "\n")
	put(&b, `      <div class="shop-key" id="key" tabindex="0"></div>`, "\n")
	put(&b, `      <div class="shop-actions"><button class="shop-buy" type="button" id="download">Download the `, esc(s.extension), ` file</button><button class="shop-quiet" type="button" id="copy">Copy the key</button></div>`, "\n")
	put(&b, "    </div>\n")
	put(&b, `    <h2 class="shop-h2">Registering it</h2>`, "\n")
	put(&b, `    <p>`, s.register, "</p>\n")
	put(&b, `    <p class="shop-fine">The same key is sent to the e-mail address you gave at the checkout, with the file attached. Keep it: it covers `, updates_words(s), `, on every computer you use. `, esc(s.name), ` checks it on your computer, without any network access.</p>`, "\n")
	put(&b, "  </div>\n")
	put(&b, `  <aside class="shop-help" id="questions">`, "\n")
	put(&b, `    <h2 class="shop-h2">A problem with your license? We are here.</h2>`, "\n")
	put(&b, `    <p>No key, a key that is refused, a wrong name: write to us with your <strong>order number</strong> (never the key itself) and we will sort it out.</p>`, "\n")
	put(&b, `    <p class="shop-help-links"><a class="shop-buy" id="help-link" href="`, esc(s.help), `">Ask for help</a><a href="../pricing/">Back to the pricing page</a></p>`, "\n")
	put(&b, "  </aside>\n")
	put(&b, "</div>\n<script>\n", LICENCE_THANKS_SCRIPT, "</script>")
	return strings.to_string(b)
}

// `page` with its licence marks replaced by the blocks of `s`. A page without the marks stays as it is.
with_licence :: proc(page: string, s: Shop) -> string {
	out := page
	if strings.contains(out, LICENCE_BUY_MARK) { out, _ = strings.replace_all(out, LICENCE_BUY_MARK, licence_buy_block(s), context.temp_allocator) }
	if strings.contains(out, LICENCE_THANKS_MARK) { out, _ = strings.replace_all(out, LICENCE_THANKS_MARK, licence_thanks_block(s), context.temp_allocator) }
	return out
}

// Whether the shop can sell: a client token, the Worker, the thank-you page and the price made. (The page's script
// decides the same.)
shop_open :: proc(s: Shop) -> bool {
	return s.client_token != "" && s.worker != "" && s.thanks != "" && s.price_id != ""
}

// The values of the template pages' {{placeholders}}: the HTML each puts there.
licence_values :: proc(s: Shop) -> [][2]string {
	retention := s.retention_days > 0 ? s.retention_days : 90
	icon, icon_small := "", ""
	if s.icon != "" {
		icon = cat(`<img class="shop-icon" src="`, esc(s.icon), `" alt="" width="88" height="88">`)
		icon_small = cat(`<img src="`, esc(s.icon), `" alt="" width="26" height="26">`)
	}
	out := make([dynamic][2]string, context.temp_allocator)
	append(&out,
		[2]string{"name", esc(s.name)},
		[2]string{"icon", icon},
		[2]string{"icon_small", icon_small},
		[2]string{"shop_css", LICENCE_CSS},
		[2]string{"product_title", esc(s.product_title)},
		[2]string{"price", s.price},
		[2]string{"updates", updates_words(s)},
		[2]string{"updates_terms", updates_terms(s)},
		[2]string{"updates_answer", updates_answer(s)},
		[2]string{"extension", esc(s.extension)},
		[2]string{"register", s.register},
		[2]string{"seller", esc(s.seller.name)},
		[2]string{"seller_url", esc(s.seller.url)},
		[2]string{"seller_web", esc(web_name(s.seller.url))},
		[2]string{"seller_domain", esc(domain_of(s.seller.url))},
		[2]string{"seller_address", s.seller.address},
		[2]string{"seller_email", esc(s.seller.email)},
		[2]string{"publisher", publisher_html(s.seller)},
		[2]string{"seller_ids", seller_ids_html(s.seller)},
		[2]string{"responsible", esc(s.seller.owner != "" ? s.seller.owner : s.seller.name)},
		[2]string{"help", esc(s.help)},
		[2]string{"repository", esc(s.repository)},
		[2]string{"code_licence", esc(s.code_licence)},
		[2]string{"code_source", code_source_html(s)},
		[2]string{"platform", s.platform},
		[2]string{"network", s.network != "" ? s.network : cat(esc(s.name), " connects to nothing by itself.")},
		[2]string{"retention_days", fmt.tprint(retention)},
		[2]string{"stylesheet", esc(s.stylesheet)},
		[2]string{"home", esc(s.home)},
		[2]string{"updated", esc(s.updated)},
	)
	return out[:]
}

// The versions a licence covers, in words: "every version", or those of its years of updates.
@(private = "file")
updates_words :: proc(s: Shop) -> string {
	switch {
	case s.update_years == 1: return "every version released in the year after your purchase"
	case s.update_years > 1:  return fmt.tprintf("every version released in the %d years after your purchase", s.update_years)
	}
	return "every version"
}

// The terms' paragraph on updates (HTML).
@(private = "file")
updates_terms :: proc(s: Shop) -> string {
	name := esc(s.name)
	if s.update_years <= 0 {
		return cat("<p>The license covers <strong>every version</strong> of ", name, ", the future ones included, at no extra cost.</p>")
	}
	years := s.update_years == 1 ? "one year" : fmt.tprintf("%d years", s.update_years)
	return cat("<p>The license includes <strong>", years, " of updates</strong>, counted from the date of purchase. Every version ",
		"released during that time is covered. After it, you can keep using the last version covered, for as long as it works on ",
		"your computer; newer versions need a license whose updates cover their release.</p>")
}

// The pricing page's answer to "Which versions does it cover?" (HTML).
@(private = "file")
updates_answer :: proc(s: Shop) -> string {
	if s.update_years <= 0 {
		return cat("<p><strong>Every version</strong>: the ones released today and the future ones, at no extra cost. The license ",
			"never expires, and ", esc(s.name), " never contacts a server about it.</p>")
	}
	years := s.update_years == 1 ? "one year" : fmt.tprintf("%d years", s.update_years)
	return cat("<p><strong>", years, " of updates</strong>, counted from your purchase. After them nothing stops: the license ",
		"is perpetual, and you keep using the last version released during your ", years, ", for as long as it works on your ",
		"computer. Newer versions need a license whose updates cover their release.</p>")
}

// The imprint's publisher: the trade name, and who trades under it.
@(private = "file")
publisher_html :: proc(seller: Seller) -> string {
	out := cat("<strong>", esc(seller.name), "</strong>")
	if seller.owner != "" { out = cat(out, ", the trade name of <strong>", esc(seller.owner), "</strong>") }
	if seller.status != "" { out = cat(out, ", ", seller.status) }
	return out
}

// The imprint's paragraph of the seller's numbers, register and VAT ("": none of them said).
@(private = "file")
seller_ids_html :: proc(seller: Seller) -> string {
	ids := make([dynamic]string, context.temp_allocator)
	if seller.siren != "" { append(&ids, cat("SIREN ", esc(seller.siren))) }
	if seller.siret != "" { append(&ids, cat("SIRET ", esc(seller.siret))) }
	if seller.ape != "" { append(&ids, cat("activity code (APE) ", esc(seller.ape))) }
	lines := make([dynamic]string, context.temp_allocator)
	if len(ids) > 0 { append(&lines, cat(strings.join(ids[:], " &middot; ", context.temp_allocator), ".")) }
	if seller.registry != "" {
		on := seller.registered != "" ? cat(" on ", esc(seller.registered)) : ""
		append(&lines, cat("Registered with ", seller.registry, on, "."))
	}
	if seller.vat != "" { append(&lines, cat("VAT: ", seller.vat, ".")) }
	if len(lines) == 0 { return "" }
	return cat("<p>", strings.join(lines[:], "<br>\n      ", context.temp_allocator), "</p>")
}

// The imprint's sentence on the source code: its licence and where it is published.
@(private = "file")
code_source_html :: proc(s: Shop) -> string {
	out := cat(esc(s.name), "'s source code is published")
	if s.code_licence != "" { out = cat(out, " under the ", esc(s.code_licence)) }
	if s.repository != "" { out = cat(out, ` on <a href="`, esc(s.repository), `">GitHub</a>`) }
	return cat(out, ".")
}

// An address as a reader writes it: no scheme, no final "/" ("https://example.org/" gives "example.org").
@(private = "file")
web_name :: proc(url: string) -> string {
	out := url
	if i := strings.index(out, "://"); i >= 0 { out = out[i + 3:] }
	return strings.trim_right(out, "/")
}

// The domain of an address, without its path ("https://example.org/shop" gives "example.org").
@(private = "file")
domain_of :: proc(url: string) -> string {
	out := web_name(url)
	if i := strings.index_byte(out, '/'); i >= 0 { out = out[:i] }
	return out
}

// `text` with each {{name}} of `values` replaced, in one pass: a value that holds "{{name}}" stays as it is, and an
// unknown placeholder stays too.
fill_placeholders :: proc(text: string, values: [][2]string) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := text
	for {
		open := strings.index(rest, "{{")
		if open < 0 { break }
		close := strings.index(rest[open + 2:], "}}")
		if close < 0 { break }
		name := rest[open + 2:][:close]
		strings.write_string(&b, rest[:open])
		found := false
		for v in values {
			if v[0] == name { strings.write_string(&b, v[1]); found = true; break }
		}
		if !found { strings.write_string(&b, rest[open:][:close + 4]) }
		rest = rest[open + close + 4:]
	}
	strings.write_string(&b, rest)
	return strings.to_string(b)
}

// The template pages, in the folders a site has them (pricing/index.html...).
LICENCE_TEMPLATES :: [?][2]string{
	{"pricing/index.html", #load("licence_pages/pricing.html", string)},
	{"thanks/index.html",  #load("licence_pages/thanks.html", string)},
	{"terms/index.html",   #load("licence_pages/terms.html", string)},
	{"refunds/index.html", #load("licence_pages/refunds.html", string)},
	{"privacy/index.html", #load("licence_pages/privacy.html", string)},
	{"imprint/index.html", #load("licence_pages/imprint.html", string)},
}

// The six pages of the shop for `s`: the placeholders filled, the marks replaced. A program that keeps its own pages
// calls with_licence on them instead.
licence_pages :: proc(s: Shop) -> []Page {
	values := make([dynamic][2]string, context.temp_allocator)
	append(&values, ..licence_values(s))
	append(&values, [2]string{"footer_nav", ""})
	templates := LICENCE_TEMPLATES
	out := make([]Page, len(templates), context.temp_allocator)
	for t, i in templates {
		values[len(values) - 1][1] = shop_footer_nav(s, t[0])
		out[i] = {path = t[0], text = with_licence(fill_placeholders(t[1], values[:]), s)}
	}
	return out
}

// The footer's links of a shop page (`page`: its file, "terms/index.html"): the home, the shop's pages in the order of the
// home page's footer (SHOP_LINKS), the source and the seller. The page's own is marked current.
@(private = "file")
shop_footer_nav :: proc(s: Shop, page: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, "<nav>\n      <a href=\"", esc(s.home), "\">", esc(s.name), "</a>\n")
	links := SHOP_LINKS
	for link in links {
		current := cat(link.href, HOME_PAGE) == page ? ` aria-current="page"` : ""
		put(&b, "      <a href=\"../", link.href, "\"", current, ">", link.label, "</a>\n")
	}
	if s.repository != "" { put(&b, "      <a href=\"", esc(s.repository), "\">", SOURCE_LABEL, "</a>\n") }
	if s.seller.url != "" { put(&b, "      <a href=\"", esc(s.seller.url), "\">", esc(s.seller.name), "</a>\n") }
	put(&b, "    </nav>")
	return strings.to_string(b)
}

// The pricing page's script: the button wakes up only when the shop is configured; Paddle.js is loaded at the first
// press; the checkout's end goes to the thank-you page with the transaction id.
LICENCE_BUY_SCRIPT :: `(function () {
  var box = document.getElementById("buy");
  if (!box) return;
  var d = box.dataset;
  var button = box.querySelector("button[data-price]");
  var note = document.getElementById("buy-note");
  if (!button || !d.clientToken || !d.worker || !d.thanks || !button.dataset.price) return;   // "Coming soon" stays

  function say(text) { if (note) { note.textContent = text; note.hidden = false; } }
  var loading = null;
  function paddle() {
    if (loading) return loading;
    loading = new Promise(function (resolve, reject) {
      var s = document.createElement("script");
      s.src = "https://cdn.paddle.com/paddle/v2/paddle.js";
      s.onload = function () {
        if (d.environment === "sandbox") Paddle.Environment.set("sandbox");
        Paddle.Initialize({
          token: d.clientToken,
          eventCallback: function (e) {
            // Paddle gives the transaction id here; the thank-you page asks the Worker for its licence
            if (e.name === "checkout.completed" && e.data && e.data.transaction_id) {
              location.href = d.thanks + "?txn=" + encodeURIComponent(e.data.transaction_id);
            }
          }
        });
        resolve(Paddle);
      };
      s.onerror = function () { loading = null; reject(new Error("Paddle.js did not load")); };
      document.head.appendChild(s);
    });
    return loading;
  }
  button.textContent = button.dataset.label || "Buy license";
  button.disabled = false;
  button.addEventListener("click", function () {
    if (note) note.hidden = true;
    paddle().then(function (P) {
      P.Checkout.open({ items: [{ priceId: button.dataset.price, quantity: 1 }], settings: { displayMode: "overlay", variant: "one-page" } });
    }, function () {
      say("The payment page could not be loaded. Check your connection, or an ad blocker, and try again.");
    });
  });
})();
`

// The thank-you page's script: polls the Worker for the licence of the transaction in the address, then shows it; every
// value is put as text.
LICENCE_THANKS_SCRIPT :: `(function () {
  var box = document.getElementById("licence-thanks");
  if (!box) return;
  var status = document.getElementById("status");
  var worker = (box.dataset.worker || "").replace(/\/+$/, "");
  var every = (parseInt(box.dataset.pollSeconds, 10) || 3) * 1000;
  var giveUp = (parseInt(box.dataset.giveUpSeconds, 10) || 150) * 1000;
  // Paddle's checkout leads here with the transaction id (the pricing page passes txn; _ptxn is Paddle's own name for it)
  var params = new URLSearchParams(location.search);
  var txn = params.get("txn") || params.get("_ptxn") || "";
  var started = Date.now();
  function say(text) { status.textContent = text; }
  function state(name) { box.setAttribute("data-state", name); }
  function set(id, text) { document.getElementById(id).textContent = text; }

  if (!/^txn_[0-9a-z]{20,40}$/.test(txn)) {
    state("failed");
    say("This page shows the license of a purchase: it needs the transaction number that the checkout passes on. If you have just paid, your license is also on its way to your e-mail address.");
    return;
  }
  if (!worker) { state("failed"); say("The license service is not set up yet."); return; }

  function show(j) {
    set("who", (j.product ? j.product + " license" : "License") + " for " + j.name);
    set("order", j.order);
    set("date", j.date);
    if (j.updates_until) { set("updates", j.updates_until); document.getElementById("updates-row").hidden = false; }
    set("key", j.licence);
    document.getElementById("licence").hidden = false;
    state("ready");
    say("Your license is ready. Thank you!");
    document.getElementById("download").addEventListener("click", function () {
      var url = URL.createObjectURL(new Blob([j.file], { type: "application/octet-stream" }));
      var a = document.createElement("a");
      a.href = url;
      a.download = j.filename;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 10000);
    });
    document.getElementById("copy").addEventListener("click", function () {
      var b = this;
      var done = function () { b.textContent = "Copied"; setTimeout(function () { b.textContent = "Copy the key"; }, 2200); };
      if (navigator.clipboard) navigator.clipboard.writeText(j.licence).then(done, selectKey); else selectKey();
    });
  }
  function selectKey() {
    var r = document.createRange();
    r.selectNodeContents(document.getElementById("key"));
    var s = getSelection();
    s.removeAllRanges();
    s.addRange(r);
    say("Press Ctrl+C to copy the selected key.");
  }
  function fail() {
    state("failed");
    say("The license is not ready yet, or the service could not be reached. Nothing is lost: it is sent by e-mail to the address you gave at the checkout, within a few minutes. If nothing arrives, reload this page later or ask for help with your order number.");
  }
  function poll() {
    fetch(worker + "/licence?txn=" + encodeURIComponent(txn), { cache: "no-store" }).then(function (res) {
      if (res.status === 200) return res.json().then(show);
      if (res.status === 202 && Date.now() - started < giveUp) { say("Making your license (this takes a few seconds)"); setTimeout(poll, every); return; }
      fail();
    }, function () {
      if (Date.now() - started < giveUp) setTimeout(poll, every * 2); else fail();
    });
  }
  say("Making your license");
  poll();
})();
`
