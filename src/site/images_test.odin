package tk_site

import "core:testing"

// A page pointed at its pictures in WebP: an <img> of a picture made gets its WebP and a srcset of its widths (its sizes are the
// page's), a link that opens it whole its WebP; a picture kept as a PNG, one with a srcset of its own, and a folder whose name only
// ends like the pictures' are left as they are.
@(test)
a_page_takes_its_pictures_in_webp :: proc(t: ^testing.T) {
	made := make(map[string]Picture, allocator = context.temp_allocator)
	made["palette"] = Picture{[]int{720, 1100, 1459}}
	made["small"] = Picture{[]int{600}}
	html := `<a class="frame" href="img/palette.png"><img src="img/palette.png" alt="The palette" sizes="(max-width: 1100px) 100vw, 1100px" loading="lazy"></a>` +
		`<img src="../img/small.png" alt="">` +
		`<img src="img/logo.png" alt="">` +
		`<img src="img/palette.png" srcset="mine.webp 1x">` +
		`<img src="bigimg/palette.png">`
	want := `<a class="frame" href="img/palette.webp"><img src="img/palette.webp" srcset="img/palette-720.webp 720w, img/palette-1100.webp 1100w, img/palette.webp 1459w" alt="The palette" sizes="(max-width: 1100px) 100vw, 1100px" loading="lazy"></a>` +
		`<img src="../img/small.webp" srcset="../img/small.webp 600w" alt="">` +
		`<img src="img/logo.png" alt="">` +
		`<img src="img/palette.webp" srcset="mine.webp 1x">` +
		`<img src="bigimg/palette.png">`
	testing.expect_value(t, images_html(html, "img", made), want)
}
