package tk_site

// The vendor's facts, said once (src/md/features/vendor-facts.md): every program of Froment Software sells under this
// imprint and publishes its site under this author, so a change of address or of VAT status is one edit here.

// The seller of every program of Froment Software: its imprint, as Wren's names it.
SELLER_FROMENT :: Seller{
	name       = "Froment Software",
	owner      = "Sacha Froment",
	status     = "sole proprietor (<em>entrepreneur individuel</em>)",
	address    = "7 Lieu-dit les Renardi&egrave;res, 72220 Marign&eacute;-Laill&eacute;, France",
	email      = "contact@froment.software",
	url        = "https://froment.software",
	siren      = "131 941 718",
	siret      = "131 941 718 00010",
	ape        = "6201Z, computer programming",
	registry   = "the French national register of companies (RNE)",
	registered = "23 October 2026",
	vat        = "not applicable, article 293 B of the French General Tax Code (<em>franchise en base de TVA</em>)",
}

// Shop.network of a program whose only connection is its updates. It says "It": the privacy page names the program in
// the paragraph before, and a sentence without the name stays a constant (a program's Shop can be one).
NETWORK_UPDATES_ONLY :: "It connects to the network for its updates only: the installed copy asks GitHub for the latest release a while after it starts and then once a day, and puts an update in place only if it is signed by Froment Software. Another copy asks only when you press <em>Check now</em> in the settings."

// A program's Meta: its own fields given, the vendor's filled (the author and the publisher from SELLER_FROMENT, so the
// footer and the imprint say the same). `card`: the sharing picture in the site. A site that differs changes a field after.
meta_default :: proc(name, url, repository, tagline, theme, accent: string, card := "img/main.png") -> Meta {
	return Meta{
		url            = url,
		name           = name,
		repository     = repository,
		tagline        = tagline,
		changes        = "CHANGELOG.md",
		card           = card,
		logo           = "img/logo.png",
		logo_file      = "site/img/logo.png",
		theme          = theme,
		accent         = accent,
		author         = SELLER_FROMENT.owner,
		author_url     = SELLER_FROMENT.url,
		publisher      = SELLER_FROMENT.name,
		ld_type        = "SoftwareApplication",
		root_domain    = false,   // (github.io answers for /robots.txt and /favicon.ico, not the site)
		publisher_logo = "img/froment-software-64.png",
		licence        = "MIT",
	}
}
