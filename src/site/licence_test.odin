package tk_site

import "core:strings"
import "core:testing"

@(private = "file")
shop_sample :: proc() -> Shop {
	prices := make([]Shop_Price, 1, context.temp_allocator)
	prices[0] = {edition = "standard", price_id = "pri_01", label = "Buy the licence"}
	return {
		name = "Sample <&>", product_title = "Sample User Licence", price = "29&nbsp;&euro;", price_note = "Once. Taxes included.",
		environment = "sandbox", client_token = "test_abc", prices = prices, worker = "https://sample-licence.example.workers.dev/",
		thanks = "https://sample.example.org/thanks/", help = "https://example.org/help?a=1&b=2", register = "Open <em>About</em>, paste the key.",
		extension = ".samplelicence", seller = "Example Software", seller_url = "https://example.org", seller_address = "1 Road<br>Town",
		seller_email = "shop@example.org", code_licence = "MIT", update_years = 2, stylesheet = "../style.css", home = "../",
		updated = "2026-11-13",
	}
}

@(test)
licence_buy_block_waits_for_its_settings :: proc(t: ^testing.T) {
	s := shop_sample()
	testing.expect(t, shop_open(s))
	block := licence_buy_block(s)
	testing.expect(t, strings.contains(block, `data-client-token="test_abc"`))
	testing.expect(t, strings.contains(block, `data-worker="https://sample-licence.example.workers.dev"`), "no final slash")
	testing.expect(t, strings.contains(block, `data-price="pri_01"`))
	testing.expect(t, strings.contains(block, `data-label="Buy the licence" disabled>Coming soon</button>`), "the script wakes it up")
	testing.expect(t, strings.contains(block, "<script>") && strings.contains(block, "Paddle.Initialize"))

	closed := s
	closed.client_token = ""
	testing.expect(t, !shop_open(closed))
	closed = s
	closed.prices = {{edition = "standard", label = "Buy"}}
	testing.expect(t, !shop_open(closed), "a price not made yet")
}

@(test)
licence_thanks_block_escapes :: proc(t: ^testing.T) {
	s := shop_sample()
	block := licence_thanks_block(s)
	testing.expect(t, strings.contains(block, `data-help="https://example.org/help?a=1&amp;b=2"`))
	testing.expect(t, strings.contains(block, "Sample &lt;&amp;&gt; checks it"))
	testing.expect(t, strings.contains(block, "Open <em>About</em>, paste the key."), "register is HTML")
	testing.expect(t, strings.contains(block, "Download the .samplelicence file"))
	testing.expect(t, strings.contains(block, "/licence?txn="))
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
	testing.expect(t, strings.contains(pages[0].text, `id="buy"`))
	testing.expect(t, strings.contains(pages[0].text, "every version released in the 2 years after your purchase"))
	testing.expect(t, strings.contains(pages[1].text, `id="licence-thanks"`))
	testing.expect(t, strings.contains(pages[1].text, `name="robots" content="noindex"`))
	testing.expect(t, strings.contains(pages[5].text, "1 Road<br>Town"))
}
