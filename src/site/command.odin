package tk_site

// The site command of a project's tool: the steps are this package's, the project says what its site is.
//   site build <site> <out>       the changelog's pages and the classic ones from <site> (build_changelog), then what a page
//                                 says when it is shared (build_meta): <out> is what is published
//   site check [--site folder] [--shot file.png] [--browser program]
//                                 the pages made of the site in a real browser, served on this machine (check)
//   site card                     draws the sharing card in a local Chromium (draw_card), once, by hand

import "core:fmt"
import toolbox "../toolbox"

// What a project's site is.
Project_Site :: struct {
	meta:  Meta,                // its address, names and colours (Meta.changes: its CHANGELOG.md)
	dir:   string,              // its sources in the repository ("": "site")
	pages: Changelog_Options,   // the home page's version mark and downloads (changes "": Meta.changes; meta: `meta`)
	extra: proc(s: ^Check),     // the project's own checks of `site check` (nil: none); s.user is the ^Project_Site
	// its pictures made light at `site build` (build_images: WebP at their widths, the pages pointed at them; dir "": as they
	// are). The encoder is found then (toolbox.webp_encoder): the publishing machine needs cwebp (Ubuntu's `webp`).
	images: Images_Options,
}

// The light pictures most sites want: the folder img, two narrower copies, the PNGs other sites read kept.
@(rodata) IMAGES_KEEP_DEFAULT := [?]string{"logo.png", "card.png", "froment-software-64.png"}
@(rodata) IMAGES_WIDTHS_DEFAULT := [?]int{720, 1100}

images_default :: proc() -> Images_Options {
	return {dir = "img", widths = IMAGES_WIDTHS_DEFAULT[:], keep = IMAGES_KEEP_DEFAULT[:]}
}

// The usage of the command, as its help says it.
COMMAND_USAGE :: "build <site> <out> | check [--site folder] [--shot file.png] [--browser program] | card: the site's pages from its folder and the changelog"

// The `site` command of a project's tool (`s` copied; its slices, Meta.ld_fields and the downloads, must live as long as
// the tool).
command :: proc(s: Project_Site) -> toolbox.Command {
	return {name = "site", usage = COMMAND_USAGE, run_with = command_run, user = new_clone(s)}
}

// The pages of the site `site` into `out`, then what each says when shared: what `site build` makes.
project_build :: proc(s: ^Project_Site, site, out: string) -> bool {
	return project_pages(site, out, s) && build_meta(s.meta, out, out)
}

@(private = "file")
project_pages :: proc(site, out: string, user: rawptr) -> bool {
	s := (^Project_Site)(user)
	o := s.pages
	if o.changes == "" { o.changes = s.meta.changes }
	o.meta = s.meta   // (its name, nav, footer and shop)
	return build_changelog(site, out, o)
}

@(private = "file")
command_run :: proc(args: []string, user: rawptr) -> int {
	s := (^Project_Site)(user)
	dir := s.dir != "" ? s.dir : "site"
	what := len(args) > 0 ? args[0] : ""
	switch what {
	case "build":
		if len(args) != 3 { break }
		if !project_build(s, args[1], args[2]) { return toolbox.EXIT_FAILED }
		if s.images.dir == "" { return toolbox.EXIT_DONE }
		o := s.images
		why: string
		if o.encoder, why = toolbox.webp_encoder("build"); why != "" { fmt.eprintfln("site: no WebP encoder: %s", why); return toolbox.EXIT_FAILED }
		return build_images(args[2], o) ? toolbox.EXIT_DONE : toolbox.EXIT_FAILED
	case "check":
		o := Check_Options{site = dir, generate = project_pages, extra = s.extra, user = s}
		if why := check_arguments(args[1:], &o); why != "" { fmt.eprintfln("site check: %s", why); return toolbox.EXIT_USAGE }
		return check(o) ? toolbox.EXIT_DONE : toolbox.EXIT_FAILED
	case "card":
		if len(args) != 1 { break }
		return draw_card(s.meta, dir) ? toolbox.EXIT_DONE : toolbox.EXIT_FAILED
	}
	fmt.eprintfln("site %s", COMMAND_USAGE)
	return toolbox.EXIT_USAGE
}
