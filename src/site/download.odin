package tk_site

// The download of the home page, for the reader's system: one button per system the program has, the first shown when
// nothing is known (no JavaScript, a phone: whoever reads it there installs it on a computer), and a line that offers the
// others. A script of the page shows the button of the system the browser says it runs on.
//
//   <div class="actions"><!-- download --> <a class="btn" href="...">Source on GitHub</a></div>
//   <p class="small"><!-- download-others --> &nbsp;·&nbsp; MIT</p>

import "core:strings"

DOWNLOAD_MARK        :: "<!-- download -->"
DOWNLOAD_OTHERS_MARK :: "<!-- download-others -->"

// A system the program is published for.
Download :: struct {
	os:     string,   // what the page's script detects: "windows", "linux" or "macos"
	label:  string,   // "Windows": "Download for Windows", "Also for Windows"
	href:   string,   // the file (the version mark is replaced after)
	detail: string,   // under the label: "v{{version}} · Windows 10 / 11 · x64 · .zip"
}

// The marks of `index` replaced by the buttons and the line of the others, and the script put before </body>. A page
// without the marks is left as it is. why: a mark without systems to put there.
with_downloads :: proc(index: string, downloads: []Download) -> (page: string, why: string) {
	has_button, has_others := strings.contains(index, DOWNLOAD_MARK), strings.contains(index, DOWNLOAD_OTHERS_MARK)
	if !has_button && !has_others { return index, "" }
	if len(downloads) == 0 { return index, "a download mark, and no system to download for (Changelog_Options.downloads)" }
	b := strings.builder_make(context.temp_allocator)
	for d, i in downloads {
		put(&b, `<a class="btn accent get" data-download-os="`, esc(d.os), `"`, i > 0 ? " hidden" : "", ` href="`, esc(d.href), `">`)
		if icon := os_icon(d.os); icon != "" { put(&b, `<span class="get-icon" aria-hidden="true">`, icon, `</span> `) }
		put(&b, `<span class="get-text"><span class="get-main">Download for `, esc(d.label), `</span> <span class="get-sub">`, esc(d.detail), `</span></span></a>`)
	}
	button := strings.to_string(b)
	o := strings.builder_make(context.temp_allocator)
	for d, i in downloads {
		put(&o, `<span data-download-others="`, esc(d.os), `"`, i > 0 ? " hidden" : "", `>Also for `)
		first := true
		for other in downloads {
			if other.os == d.os { continue }
			put(&o, first ? "" : ", ", `<a href="`, esc(other.href), `">`, esc(other.label), `</a>`)
			first = false
		}
		put(&o, `</span>`)
	}
	others := strings.to_string(o)
	page, _ = strings.replace_all(index, DOWNLOAD_MARK, button, context.temp_allocator)
	page, _ = strings.replace_all(page, DOWNLOAD_OTHERS_MARK, others, context.temp_allocator)
	if at := strings.last_index(page, "</body>"); at >= 0 { page = cat(page[:at], DOWNLOAD_SCRIPT, page[at:]) }
	return page, ""
}

// The reader's system, from what the browser says; a system the program has no button for keeps the first one.
@(private = "file")
DOWNLOAD_SCRIPT :: `<script>
  // the download for this system (tk_site: download.odin)
  {
    const ua = navigator.userAgent, platform = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || '';
    const seen = (platform + ' ' + ua).toLowerCase();
    const os = /android|iphone|ipad|ipod/.test(seen) ? '' : /win/.test(seen) ? 'windows' : /mac/.test(seen) ? 'macos' : /linux|x11|bsd|cros/.test(seen) ? 'linux' : '';
    if (os && document.querySelector('[data-download-os="' + os + '"]')) {
      for (const kind of ['data-download-os', 'data-download-others']) {
        document.querySelectorAll('[' + kind + ']').forEach(e => { e.toggleAttribute('hidden', e.getAttribute(kind) !== os); });
      }
    }
  }
</script>
`

// The mark of a system, as an inline SVG of the text's colour ("": none for it).
@(private = "file")
os_icon :: proc(os: string) -> string {
	switch os {
	case "windows": return `<svg width="1em" height="1em" viewBox="0 0 24 24"><path fill="currentColor" d="M3 12V6.75l6-1.32v6.48zm17-9v8.75l-10 .15V5.21zM3 13l6 .09v6.81l-6-1.15zm17 .25V22l-10-1.91V13.1z"/></svg>`
	case "linux":   return `<svg width="1em" height="1em" viewBox="0 0 24 24"><path fill="currentColor" d="M14.62 8.35c-.42.28-1.75 1.04-1.95 1.19c-.39.31-.75.29-1.14-.01c-.2-.16-1.53-.92-1.95-1.19c-.48-.31-.45-.7.08-.92c1.64-.69 3.28-.64 4.91.03c.49.21.51.6.05.9m7.22 7.28c-.93-2.09-2.2-3.99-3.84-5.66a4.3 4.3 0 0 1-1.06-1.88c-.1-.33-.17-.67-.24-1.01c-.2-.88-.29-1.78-.7-2.61c-.73-1.58-2-2.4-3.84-2.47c-1.81.05-3.16.81-3.95 2.4c-.21.43-.36.88-.46 1.34c-.17.76-.32 1.55-.5 2.32c-.15.65-.45 1.21-.96 1.71c-1.61 1.57-2.9 3.37-3.88 5.35c-.14.29-.28.58-.37.88c-.19.66.29 1.12.99.96c.44-.09.88-.18 1.3-.31c.41-.15.57-.05.67.35c.65 2.15 2.07 3.66 4.24 4.5c4.12 1.56 8.93-.66 9.97-4.58c.07-.27.17-.37.47-.27c.46.14.93.24 1.4.35c.49.09.85-.16.92-.64c.03-.26-.06-.49-.16-.73"/></svg>`
	}
	return ""
}
