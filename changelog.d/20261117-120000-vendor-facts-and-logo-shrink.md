type: Changed

**The vendor's facts and the logo's shrink, once in the toolkit**: a program no longer copies them.
  - `site.SELLER_FROMENT` is the imprint's seller, `site.meta_default(name, url, repository, tagline, theme, accent, card)` a site's `Meta` with the vendor's fields filled, and `site.NETWORK_UPDATES_ONLY` the privacy sentence of a program that only connects for its updates.
  - `desktop.identity_of(vendor, title, slug)` derives an `Identity`'s key, vendor key, marks, manifest and environment prefix; a program sets only its own lines after it.
  - `toolbox.Logo.render(size, user)` is replaced by `draw(pixels, size, user)`: `write_logo` draws each size at `draw_size` (0: `master`) or more and shrinks it by `LOGO_SHRINK_STEP` at most per step. `logo_picture` and `logo_shrink` are public.
