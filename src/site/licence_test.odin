package tk_site

import "core:strings"
import "core:testing"

@(private = "file")
shop_sample :: proc() -> Shop {
	return {
		name = "Sample <&>", icon = "../img/logo.png", product_title = "Sample User License", price = "29&nbsp;&euro;",
		price_note = "Launch price: 45&nbsp;&euro; after 1.0.", environment = "sandbox", client_token = "test_abc",
		edition = "standard", price_id = "pri_01", buy_label = "Buy it", worker = "https://sample-licence.example.workers.dev/",
		thanks = "https://sample.example.org/thanks/", help = "https://example.org/help?a=1&b=2", register = "Open <em>About</em>, paste the key.",
		extension = ".samplelicence", repository = "https://example.org/repo", seller = sample_seller(),
		code_licence = "MIT License", platform = "Windows <em>and</em> Linux", network = "It asks <em>example.org</em> for updates.",
		update_years = 2, stylesheet = "../style.css", home = "../", updated = "2026-11-13",
	}
}

@(private = "file")
sample_seller :: proc() -> Seller {
	return {
		name = "Example Software", owner = "Jane Doe", status = "sole proprietor (<em>entrepreneur individuel</em>)",
		address = "1 Road<br>Town", email = "shop@example.org", url = "https://example.org", siren = "123 456 789",
		siret = "123 456 789 00010", ape = "6201Z, computer programming", registry = "the <abbr>RNE</abbr>",
		registered = "1 May 2026", vat = "not applicable, article 293 B of the French General Tax Code",
	}
}

@(test)
licence_buy_block_waits_for_its_settings :: proc(t: ^testing.T) {
	s := shop_sample()
	testing.expect(t, shop_open(s))
	block := licence_buy_block(s)
	testing.expect(t, strings.contains(block, `data-client-token="test_abc"`))
	testing.expect(t, strings.contains(block, `data-worker="https://sample-licence.example.workers.dev"`), "no final slash")
	testing.expect(t, strings.contains(block, `data-edition="standard" data-price="pri_01"`))
	testing.expect(t, strings.contains(block, `data-label="Buy it" disabled>Coming soon</button>`), "the script wakes it up")
	testing.expect_value(t, strings.count(block, "<button"), 1)
	testing.expect(t, !strings.contains(block, "Nothing to buy"), "the button alone says the shop is closed")
	testing.expect(t, strings.contains(block, `<p class="shop-status" id="buy-note" role="status" hidden></p>`), "the note waits for an error")
	testing.expect(t, strings.contains(block, "<script>") && strings.contains(block, "Paddle.Initialize"))
	testing.expect(t, strings.contains(block, `<span class="shop-amount">29&nbsp;&euro;</span>`), "price is HTML")
	testing.expect(t, strings.contains(block, `<p class="shop-price-note">Launch price: 45&nbsp;&euro; after 1.0.</p>`), "price_note is HTML")
	testing.expect(t, strings.contains(block, "2 years of updates"))
	testing.expect(t, strings.contains(block, "No subscription, no renewal, no expiry"))
	testing.expect(t, strings.contains(block, "Checked offline, on your computer"))
	testing.expect(t, strings.contains(block, `href="#q-offline"`), "each line links the question that tells more")
	testing.expect(t, strings.contains(block, `accept the <a href="../terms/">license terms</a>`), "Wren's spelling")
	testing.expect(t, !strings.contains(block, "Sample User License"), "the product's title is no heading")

	plain := s
	plain.price_note, plain.buy_label, plain.update_years, plain.code_licence = "", "", 0, ""
	block = licence_buy_block(plain)
	testing.expect(t, !strings.contains(block, "shop-price-note"), "no note, no line")
	testing.expect(t, strings.contains(block, `data-label="Buy license"`), "the default label, Wren's")
	testing.expect(t, strings.contains(block, "Every future version"))

	closed := s
	closed.client_token = ""
	testing.expect(t, !shop_open(closed))
	closed = s
	closed.price_id = ""
	testing.expect(t, !shop_open(closed), "a price not made yet")
	closed = s
	closed.thanks = ""
	testing.expect(t, !shop_open(closed), "nowhere to go after the checkout")
}

@(test)
licence_thanks_block_escapes :: proc(t: ^testing.T) {
	s := shop_sample()
	block := licence_thanks_block(s)
	testing.expect(t, strings.contains(block, `data-help="https://example.org/help?a=1&amp;b=2"`))
	testing.expect(t, strings.contains(block, "Sample &lt;&amp;&gt; checks it"))
	testing.expect(t, strings.contains(block, "it covers every version released in the 2 years after your purchase"))
	testing.expect(t, strings.contains(block, `<a class="shop-buy" id="help-link" href="https://example.org/help?a=1&amp;b=2">Ask for help</a>`), "the help, a button")
	testing.expect(t, strings.contains(block, `<a href="../pricing/">Back to the pricing page</a>`))
	testing.expect(t, strings.contains(block, "Open <em>About</em>, paste the key."), "register is HTML")
	testing.expect(t, strings.contains(block, "Download the .samplelicence file"))
	testing.expect(t, strings.contains(block, "/licence?txn="))
	testing.expect(t, strings.contains(block, `data-state="waiting"`), "the spinner shows until the script decides")
	testing.expect(t, !strings.contains(block, `id="edition"`), "one licence: no edition shown")
}

@(test)
licence_marks_are_replaced :: proc(t: ^testing.T) {
	s := shop_sample()
	page := "<main>\n<!-- licence-buy -->\n</main>"
	out := with_licence(page, s)
	testing.expect(t, !strings.contains(out, LICENCE_BUY_MARK))
	testing.expect(t, strings.contains(out, `id="buy"`))
	testing.expect_value(t, with_licence("<p>nothing</p>", s), "<p>nothing</p>")
}

@(test)
placeholders_in_one_pass :: proc(t: ^testing.T) {
	values := [][2]string{{"name", "{{price}}"}, {"price", "9"}}
	testing.expect_value(t, fill_placeholders("a {{name}} b {{price}} {{other}} {{", values), "a {{price}} b 9 {{other}} {{")
}

@(test)
licence_pages_are_whole :: proc(t: ^testing.T) {
	pages := licence_pages(shop_sample())
	testing.expect_value(t, len(pages), 6)
	for p in pages {
		testing.expectf(t, !strings.contains(p.text, "{{"), "%s keeps a placeholder", p.path)
		testing.expectf(t, !strings.contains(p.text, "<!-- licence-"), "%s keeps a mark", p.path)
		testing.expectf(t, strings.contains(p.text, "Sample &lt;&amp;&gt;"), "%s names the program", p.path)
		testing.expectf(t, strings.has_suffix(p.path, "/index.html"), "%s", p.path)
	}
	for p in pages {
		testing.expectf(t, strings.contains(p.text, ".shop-offer {"), "%s carries the shop's style", p.path)
		testing.expectf(t, strings.contains(p.text, `<body class="shop-page">`), "%s", p.path)
		testing.expectf(t, strings.contains(p.text, `<img src="../img/logo.png" alt="" width="26" height="26">`), "%s shows the icon in its bar", p.path)
	}
	testing.expect(t, strings.contains(pages[0].text, `id="buy"`))
	testing.expect(t, strings.contains(pages[0].text, `<h1 class="shop-name">Sample &lt;&amp;&gt;</h1>`), "the name as it is, the heading")
	testing.expect(t, strings.contains(pages[0].text, `<img class="shop-icon" src="../img/logo.png"`))
	testing.expect(t, strings.contains(pages[0].text, `<a href="../pricing/" aria-current="page">Pricing</a>`))
	testing.expect(t, strings.contains(pages[0].text, "<title>Pricing · Sample &lt;&amp;&gt;</title>"), "the nav's word, in the title")
	testing.expect(t, strings.contains(pages[2].text, `<a href="../terms/" aria-current="page">Terms</a>`), "each page marks its own")
	testing.expect(t, !strings.contains(pages[1].text, `aria-current="page"`), "the thank-you page is in no list")
	for p in pages {
		testing.expectf(t, strings.contains(p.text, `<a href="../imprint/"`) && strings.contains(p.text, `<a href="https://example.org/repo">GitHub</a>`) && strings.contains(p.text, `<a href="https://example.org">Example Software</a>`), "%s: the footer of every site", p.path)
	}
	testing.expect(t, strings.contains(pages[0].text, "every version released in the 2 years after your purchase"))
	testing.expect(t, strings.contains(pages[1].text, `id="licence-thanks"`))
	testing.expect(t, strings.contains(pages[1].text, `name="robots" content="noindex"`))
	testing.expect(t, strings.contains(pages[5].text, "1 Road<br>Town"))
}

// The imprint says what Wren's says, from the Seller: who publishes, the numbers, the register, the VAT, who answers for
// the content, the code's licence.
@(test)
licence_imprint_names_the_seller :: proc(t: ^testing.T) {
	imprint := licence_pages(shop_sample())[5].text
	testing.expect(t, strings.contains(imprint, "is published by <strong>Example Software</strong>, the trade name of <strong>Jane Doe</strong>, sole proprietor (<em>entrepreneur individuel</em>)."))
	testing.expect(t, strings.contains(imprint, `Web: <a href="https://example.org">example.org</a>`), "the address as a reader writes it")
	testing.expect(t, strings.contains(imprint, "SIREN 123 456 789 &middot; SIRET 123 456 789 00010 &middot; activity code (APE) 6201Z, computer programming."))
	testing.expect(t, strings.contains(imprint, "Registered with the <abbr>RNE</abbr> on 1 May 2026."), "the registry is HTML")
	testing.expect(t, strings.contains(imprint, "VAT: not applicable, article 293 B of the French General Tax Code."))
	testing.expect(t, strings.contains(imprint, "<p>Jane Doe, at the address above.</p>"), "the owner answers for the content")
	testing.expect(t, strings.contains(imprint, "The domain example.org is managed through Cloudflare"))
	testing.expect(t, strings.contains(imprint, `source code is published under the MIT License on <a href="https://example.org/repo">GitHub</a>.`))
	testing.expect(t, strings.contains(imprint, "<title>Imprint · Sample &lt;&amp;&gt;</title>"))

	company := shop_sample()
	company.seller = {name = "Some Ltd", email = "a@b.org", url = "https://b.org"}
	imprint = licence_pages(company)[5].text
	testing.expect(t, strings.contains(imprint, "is published by <strong>Some Ltd</strong>.<br>"), "no owner, no status")
	testing.expect(t, !strings.contains(imprint, "SIREN") && !strings.contains(imprint, "VAT:"), "no numbers, no paragraph")
	testing.expect(t, strings.contains(imprint, "<p>Some Ltd, at the address above.</p>"))
}

// The other pages take Wren's words, with the program's facts.
@(test)
licence_pages_say_what_wren_says :: proc(t: ^testing.T) {
	pages := licence_pages(shop_sample())
	pricing, thanks, terms, refunds, privacy := pages[0].text, pages[1].text, pages[2].text, pages[3].text, pages[4].text
	testing.expect(t, strings.contains(pricing, "<dt>Platform</dt><dd>Windows <em>and</em> Linux</dd>"), "the platform is HTML")
	testing.expect(t, strings.contains(pricing, `<details id="q-once">`) && strings.contains(pricing, `<details id="q-offline">`) && strings.contains(pricing, `<details id="q-versions">`), "the offer's links lead somewhere")
	testing.expect(t, strings.contains(pricing, "<p>Open <em>About</em>, paste the key.</p>"), "how to register, in the questions")
	testing.expect(t, strings.contains(pricing, "<strong>2 years of updates</strong>, counted from your purchase"))
	testing.expect(t, strings.contains(thanks, "Thank you for supporting Sample &lt;&amp;&gt;"))
	testing.expect(t, strings.contains(terms, "<title>License terms · Sample &lt;&amp;&gt;</title>"))
	testing.expect(t, strings.contains(terms, "<strong>2 years of updates</strong>, counted from the date of purchase"))
	testing.expect(t, strings.contains(terms, "public under the MIT License"))
	testing.expect(t, strings.contains(terms, "<strong>Example Software</strong>"))
	testing.expect(t, strings.contains(refunds, "The Sample User License is sold through"))
	testing.expect(t, strings.contains(privacy, "<p>It asks <em>example.org</em> for updates.</p>"), "the program's network is HTML")
	testing.expect(t, strings.contains(privacy, "your e-mail address 90 days after"), "the Worker's default retention")
	for p in pages[2:] {
		body := p.text[strings.index(p.text, "<main"):strings.index(p.text, "</main>")]
		// (the key's file extension is the program's name for it, not the page's words)
		body, _ = strings.remove_all(body, shop_sample().extension, context.temp_allocator)
		testing.expectf(t, !strings.contains(body, "licence") && !strings.contains(body, "Licence"), "%s: Wren's spelling", p.path)
	}

	every := shop_sample()
	every.update_years, every.network = 0, ""
	pages = licence_pages(every)
	testing.expect(t, strings.contains(pages[2].text, "covers <strong>every version</strong> of Sample &lt;&amp;&gt;"))
	testing.expect(t, strings.contains(pages[4].text, "<p>Sample &lt;&amp;&gt; connects to nothing by itself.</p>"))
}
