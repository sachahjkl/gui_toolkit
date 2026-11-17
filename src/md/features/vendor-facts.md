# The vendor's facts, said once

Every program of Froment Software sells under one imprint, publishes its site under one author and one publisher, and
installs under one vendor's folder and keys. Five programs copied these facts field by field: a change of address or of
VAT status was five edits in five repositories, and one forgotten copy was a wrong imprint. The facts now have one place
each, and a program gives only what is its own.

## The site (`gt:site`)

- **`SELLER_FROMENT`** is the imprint's `Seller`. The five copies (papier, classeur, inspecteur, cliche, opencode native)
  were the same twelve fields, byte for byte, when they moved here.
- **`meta_default(name, url, repository, tagline, theme, accent, card)`** is a program's `Meta` with the vendor's fields
  filled: the author, the author's site and the publisher (from `SELLER_FROMENT`, so the footer and the imprint cannot
  disagree), the publisher's mark, the code's licence, the schema.org type, the files every site keeps at the same place
  (`CHANGELOG.md`, `img/logo.png`, `site/img/logo.png`) and `root_domain` off. A program changes a field after the call
  when its site differs (opencode native's card title, its footer note).
- **`NETWORK_UPDATES_ONLY`** is the privacy page's sentence for a program whose only connection is its updates. It says
  "It", not the program's name: the paragraph before it on the privacy page names the program, and a sentence without
  the name stays a constant, so a program's `Shop` can stay a constant too.

The vendor's values are constants of the package, not a configuration file: they change with a release of the toolkit,
as every program follows the toolkit's versions.

## The install (`gt:desktop`)

- **`identity_of(vendor, title, slug)`** derives the names and the marks of an `Identity` by the rule the five programs
  followed by hand: the key is the title in PascalCase ("opencode native": "OpencodeNative"), the vendor's key the
  vendor's ("FromentSoftware"), by the same rule as the AppUserModelID (`platform.app_user_model_id`), so the three can
  never disagree. From the key, the marks `X-<key>-Integration` and `<key>Integration`; from the slug, the manifest
  `<slug>_install.txt` and the environment's prefix `<SLUG>_DESKTOP_` (upper case, hyphens as underscores).
- A program then sets only its own lines: the description, the categories, the generic name, the keywords, the actions.
- The marks are what an installed copy already carries on users' machines. A program whose marks were made by another
  rule (opencode native's manifest `opencode-native-install.txt`) sets that field after the call: changing it would leave
  the installed files behind, unrecognised.
- The derived strings are allocated (a key in PascalCase is no constant expression). The identity is the program's for its
  life: `options_clone` shares its strings with a job on another thread, so they are made in the allocator given
  (`context.allocator` by default), never in the temporary one.

## Refused

- **A vendor's record in the toolkit that every package reads** (one `Vendor` struct passed around): the site and the
  install read different facts of the vendor, and each package already has its own type for them (`Seller`, `Identity`).
- **Empty marks derived where they are read** (as `Identity.aumid`): a dozen places in the backends read the marks, and
  each would need the derivation; a mark is derived once, where the identity is made.
