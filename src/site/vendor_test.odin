package tk_site

import "core:strings"
import "core:testing"

// A program's Meta from its own fields: the vendor's are the imprint's, and the pages built from it say them.
@(test)
a_default_meta_has_the_vendors_fields :: proc(t: ^testing.T) {
	m := meta_default(name = "App", url = "https://app.example/", repository = "https://github.com/x/app",
		tagline = "What it does", theme = "#111111", accent = "#ff8800")
	testing.expect_value(t, m.name, "App")
	testing.expect_value(t, m.url, "https://app.example/")
	testing.expect_value(t, m.card, "img/main.png")
	testing.expect_value(t, m.publisher, SELLER_FROMENT.name)
	testing.expect_value(t, m.author, SELLER_FROMENT.owner)
	testing.expect_value(t, m.author_url, SELLER_FROMENT.url)
	testing.expect_value(t, m.changes, "CHANGELOG.md")
	testing.expect(t, !m.root_domain, "github.io answers for the root files")
	testing.expect(t, strings.contains(structured_data(m), `"name": "Froment Software"`), "the publisher in the home's data")
	other := meta_default("App", "https://app.example/", "", "", "#111111", "#ff8800", card = "img/card.png")
	testing.expect_value(t, other.card, "img/card.png")
}

// The imprint and the privacy page of a shop read the shared seller and the shared sentence.
@(test)
a_shop_says_the_shared_seller :: proc(t: ^testing.T) {
	testing.expect(t, SELLER_FROMENT.name != "" && SELLER_FROMENT.email != "" && SELLER_FROMENT.vat != "", "the imprint's facts")
	testing.expect(t, strings.has_prefix(NETWORK_UPDATES_ONLY, "It "), "no program's name in the shared sentence")
	s := Shop{
		name = "App", icon = "../img/logo.png", product_title = "App User License", price = "15&nbsp;&euro;",
		environment = "production", edition = "supporter", thanks = "https://app.example/thanks/",
		help = "https://github.com/x/app/issues/new", extension = ".applicence", repository = "https://github.com/x/app",
		seller = SELLER_FROMENT, code_licence = "MIT License", platform = "Linux, x64.", network = NETWORK_UPDATES_ONLY,
		stylesheet = "../style.css", home = "../", updated = "2026-11-13",
	}
	found := false
	for p in licence_pages(s) {
		if !strings.contains(p.path, "privacy") { continue }
		found = true
		testing.expect(t, strings.contains(p.text, NETWORK_UPDATES_ONLY), "the privacy page says it")
	}
	testing.expect(t, found, "a privacy page")
}
