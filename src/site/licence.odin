package tk_site

// The pages of a program's shop (docs/licence.md): the buy block of its pricing page (Paddle's checkout, its overlay) and the
// thank-you block that asks the licence Worker for the licence just bought. A program's page holds the marks; with_licence
// puts the blocks there. The template pages (licence_pages/*.html: pricing, thanks, terms, refunds, privacy, imprint) are
// whole pages in neutral words that a program copies into its site, or that licence_pages fills for it.
//
//   <!-- licence-buy -->      the offer, its button(s), and the script that opens the checkout
//   <!-- licence-thanks -->   the licence of the purchase: who, the order, the key, a download, a copy button
//
// While Paddle's client token, a price id or the Worker's address is missing, the button says "Coming soon" and does
// nothing: a site can be published before the shop is open.

import "core:fmt"
import "core:strings"

LICENCE_BUY_MARK    :: "<!-- licence-buy -->"
LICENCE_THANKS_MARK :: "<!-- licence-thanks -->"

// One thing to buy: an edition of the licence and its Paddle price.
Shop_Price :: struct {
	edition:  string,   // the edition's id ("standard"), as in the program's licence.Product
	price_id: string,   // Paddle's price ("pri_..."): "" until it is made (`<tool> paddle -apply`)
	label:    string,   // the button's words ("Buy the licence")
}

// What a program's shop is, for its pages. HTML fields say so; the others are text, escaped where they go.
Shop :: struct {
	name:           string,         // the program ("App")
	product_title:  string,         // what is sold ("App User Licence")
	price:          string,         // HTML, as shown ("29&nbsp;&euro;")
	price_note:     string,         // under the price ("Once. Taxes included.")
	environment:    string,         // Paddle's: "sandbox" or "production"
	client_token:   string,         // Paddle's client-side token (test_... or live_...); "": coming soon
	prices:         []Shop_Price,   // the buttons, in their order
	worker:         string,         // the licence Worker's address, no final "/" ("https://app-licence.<account>.workers.dev")
	thanks:         string,         // the absolute address of the thank-you page
	help:           string,         // where a buyer asks for help (an address)
	register:       string,         // HTML: how to register a licence in the program (the thank-you page says it)
	extension:      string,         // the licence file's extension (".applicence")
	seller:         string,         // who sells, through Paddle ("Example Software")
	seller_url:     string,
	seller_address: string,         // HTML: the imprint's address lines
	seller_email:   string,
	seller_vat:     string,         // the VAT number ("": none said)
	code_licence:   string,         // the licence of the program's source code ("MIT"), which a purchase does not change
	update_years:   int,            // 0: every version; N: the versions released in the N years after the purchase
	refund_days:    int,            // the seller's refund window (0: 14)
	retention_days: int,            // the days the Worker keeps a buyer's name and address (0: 90, its PII_RETENTION_DAYS)
	stylesheet:     string,         // the site's stylesheet from a template page ("../style.css")
	home:           string,         // the site's home from a template page ("../")
	updated:        string,         // the day the terms last changed ("2026-11-13")
}

// The buy block: the offer and its buttons, with what the script needs in data-* attributes, then the script.
licence_buy_block :: proc(s: Shop) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, `<div class="offer" id="buy" data-environment="`, esc(s.environment), `" data-client-token="`, esc(s.client_token),
		`" data-worker="`, esc(strings.trim_right(s.worker, "/")), `" data-thanks="`, esc(s.thanks), `">`, "\n")
	put(&b, `  <h2 id="buy-title">`, esc(s.product_title), "</h2>\n")
	put(&b, `  <p class="price">`, s.price, "</p>\n")
	if s.price_note != "" { put(&b, `  <p class="terms-line">`, esc(s.price_note), "</p>\n") }
	for p in s.prices {
		put(&b, `  <button class="btn primary" type="button" data-edition="`, esc(p.edition), `" data-price="`, esc(p.price_id),
			`" data-label="`, esc(p.label), `" disabled>Coming soon</button>`, "\n")
	}
	put(&b, `  <p class="fine" id="buy-note">Nothing to buy yet.</p>`, "\n")
	put(&b, `  <p class="fine">By placing your order you accept the <a href="../terms/">licence terms</a>. Sold by Paddle.com as Merchant of Record and reseller: <a href="https://www.paddle.com/legal/buyer-terms">buyer terms</a>, <a href="https://www.paddle.com/legal/privacy">privacy</a>, <a href="https://www.paddle.com/legal/refund-policy">refunds</a>.</p>`, "\n")
	put(&b, "</div>\n<script>\n", LICENCE_BUY_SCRIPT, "</script>")
	return strings.to_string(b)
}

// The thank-you block: the status while the Worker makes the licence, then the licence, from GET /licence?txn=.
licence_thanks_block :: proc(s: Shop) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, `<div id="licence-thanks" data-worker="`, esc(strings.trim_right(s.worker, "/")), `" data-poll-seconds="3" data-give-up-seconds="150" data-help="`, esc(s.help), `">`, "\n")
	put(&b, `  <p class="intro"><span id="status" role="status">Making your licence&hellip;</span></p>`, "\n")
	put(&b, `  <div id="licence" hidden>`, "\n")
	put(&b, `    <div class="card">`, "\n")
	put(&b, `      <h3 id="who"></h3>`, "\n")
	put(&b, `      <dl class="facts"><div><dt>Order</dt><dd id="order"></dd></div><div><dt>Date</dt><dd id="date"></dd></div><div><dt>Edition</dt><dd id="edition"></dd></div><div id="updates-row" hidden><dt>Updates until</dt><dd id="updates"></dd></div></dl>`, "\n")
	put(&b, `      <p class="keylabel">Your key</p>`, "\n")
	put(&b, `      <div class="key" id="key" tabindex="0"></div>`, "\n")
	put(&b, `      <div class="actions"><button class="btn primary" type="button" id="download">Download the `, esc(s.extension), ` file</button> <button class="btn" type="button" id="copy">Copy the key</button></div>`, "\n")
	put(&b, "    </div>\n")
	put(&b, `    <h2>Registering it</h2>`, "\n")
	put(&b, `    <p>`, s.register, "</p>\n")
	put(&b, `    <p class="fine">The same key is sent to the e-mail address you gave at the checkout, with the file attached. Keep it. `, esc(s.name), ` checks it on your computer, without any network access.</p>`, "\n")
	put(&b, "  </div>\n")
	put(&b, `  <p class="fine">A problem with your licence? <a id="help-link" href="`, esc(s.help), `">Ask for help</a> with your order number (never the key itself).</p>`, "\n")
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

// Whether the shop can sell: a client token, the Worker, and every price made. (The page's script decides the same.)
shop_open :: proc(s: Shop) -> bool {
	if s.client_token == "" || s.worker == "" || len(s.prices) == 0 { return false }
	for p in s.prices { if p.price_id == "" { return false } }
	return true
}

// The values of the template pages' {{placeholders}}: the HTML each puts there.
licence_values :: proc(s: Shop) -> [][2]string {
	years := s.update_years
	updates := years > 0 ? fmt.tprintf("every version released in the %d years after your purchase", years) : "every version"
	refund := s.refund_days > 0 ? s.refund_days : 14
	retention := s.retention_days > 0 ? s.retention_days : 90
	vat := s.seller_vat != "" ? cat("VAT number: ", esc(s.seller_vat)) : ""
	out := make([dynamic][2]string, context.temp_allocator)
	append(&out,
		[2]string{"name", esc(s.name)},
		[2]string{"product_title", esc(s.product_title)},
		[2]string{"price", s.price},
		[2]string{"updates", updates},
		[2]string{"extension", esc(s.extension)},
		[2]string{"seller", esc(s.seller)},
		[2]string{"seller_url", esc(s.seller_url)},
		[2]string{"seller_address", s.seller_address},
		[2]string{"seller_email", esc(s.seller_email)},
		[2]string{"seller_vat", vat},
		[2]string{"help", esc(s.help)},
		[2]string{"code_licence", esc(s.code_licence)},
		[2]string{"refund_days", fmt.tprint(refund)},
		[2]string{"retention_days", fmt.tprint(retention)},
		[2]string{"stylesheet", esc(s.stylesheet)},
		[2]string{"home", esc(s.home)},
		[2]string{"updated", esc(s.updated)},
	)
	return out[:]
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
	values := licence_values(s)
	templates := LICENCE_TEMPLATES
	out := make([]Page, len(templates), context.temp_allocator)
	for t, i in templates { out[i] = {path = t[0], text = with_licence(fill_placeholders(t[1], values), s)} }
	return out
}

// The pricing page's script: the buttons wake up only when the shop is configured; Paddle.js is loaded at the first
// press; the checkout's end goes to the thank-you page with the transaction id.
LICENCE_BUY_SCRIPT :: `(function () {
  var box = document.getElementById("buy");
  if (!box) return;
  var d = box.dataset;
  var buttons = box.querySelectorAll("button[data-price]");
  var note = document.getElementById("buy-note");
  var ready = d.clientToken && d.worker && d.thanks && buttons.length > 0;
  for (var i = 0; i < buttons.length; i++) if (!buttons[i].dataset.price) ready = false;
  if (!ready) return;   // "Coming soon" stays

  if (note) note.textContent = "One payment, no subscription.";
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
  for (var j = 0; j < buttons.length; j++) {
    (function (button) {
      button.textContent = button.dataset.label || "Buy";
      button.disabled = false;
      button.addEventListener("click", function () {
        paddle().then(function (P) {
          P.Checkout.open({ items: [{ priceId: button.dataset.price, quantity: 1 }], settings: { displayMode: "overlay", variant: "one-page" } });
        }, function () {
          if (note) note.textContent = "The payment page could not be loaded. Check your connection, or an ad blocker, and try again.";
        });
      });
    })(buttons[j]);
  }
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
  function set(id, text) { document.getElementById(id).textContent = text; }

  if (!/^txn_[0-9a-z]{20,40}$/.test(txn)) {
    say("This page shows the licence of a purchase: it needs the transaction number that the checkout passes on. If you have just paid, your licence is also on its way to your e-mail address.");
    return;
  }
  if (!worker) { say("The licence service is not set up yet."); return; }

  function show(j) {
    set("who", (j.product ? j.product + " licence" : "Licence") + " for " + j.name);
    set("order", j.order);
    set("date", j.date);
    set("edition", j.edition);
    if (j.updates_until) { set("updates", j.updates_until); document.getElementById("updates-row").hidden = false; }
    set("key", j.licence);
    document.getElementById("licence").hidden = false;
    say("Your licence is ready. Thank you!");
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
    say("The licence is not ready yet, or the service could not be reached. Nothing is lost: it is sent by e-mail to the address you gave at the checkout, within a few minutes. If nothing arrives, reload this page later or ask for help with your order number.");
  }
  function poll() {
    fetch(worker + "/licence?txn=" + encodeURIComponent(txn), { cache: "no-store" }).then(function (res) {
      if (res.status === 200) return res.json().then(show);
      if (res.status === 202 && Date.now() - started < giveUp) { say("Making your licence (this takes a few seconds)"); setTimeout(poll, every); return; }
      fail();
    }, function () {
      if (Date.now() - started < giveUp) setTimeout(poll, every * 2); else fail();
    });
  }
  say("Making your licence");
  poll();
})();
`
