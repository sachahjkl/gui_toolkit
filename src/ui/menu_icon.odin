package ui

// A picture beside a menu's item (Shell_Menu's items, Open_With's applications): pixels a worker read, made a texture
// at the first draw of its row (not before: a menu never opened uploads nothing), on the renderer that draws it.

import "core:math"
import draw "../draw"
import "../render"

@(private)
Menu_Icon :: struct {
	rgba:     []u8,   // straight RGBA8, borrowed: the owner keeps the pixels while the icon lives
	size:     [2]int,
	texture:  render.Texture,
	renderer: ^render.Renderer,
	failed:   bool,   // the renderer refused it: the row shows no picture
}

// The texture goes (the pixels stay the owner's).
@(private)
menu_icon_release :: proc(ic: ^Menu_Icon) {
	if ic.texture != 0 && ic.renderer != nil { render.destroy_texture(ic.renderer, ic.texture) }
	ic.texture, ic.renderer = 0, nil
}

// A Custom_Draw for menu_item_ex and menu_submenu_ex: `user` is the ^Menu_Icon. The picture fits the icon's box, at most
// a little over the font's size, on whole pixels.
@(private)
menu_icon_draw :: proc(box: ^Box, user: rawptr, dc: ^draw.Context) {
	ic := (^Menu_Icon)(user)
	if ic == nil || dc == nil || dc.renderer == nil || len(ic.rgba) == 0 { return }
	if ic.texture == 0 && !ic.failed {
		w, h := ic.size.x, ic.size.y
		most := render.max_texture_size(dc.renderer)
		if w <= 0 || h <= 0 || w > most || h > most || len(ic.rgba) < w * h * 4 {
			ic.failed = true
			return
		}
		ic.texture = render.create_texture_rgba(dc.renderer, w, h)
		if ic.texture == 0 {
			ic.failed = true
			return
		}
		ic.renderer = dc.renderer
		render.update_texture_rgba(dc.renderer, ic.texture, 0, 0, w, h, ic.rgba)
	}
	if ic.texture == 0 { return }
	r := box.rect
	side := math.floor(min(r.max.x - r.min.x, r.max.y - r.min.y, font_size() * 1.05))
	if side < 2 { return }
	ox := math.floor(r.min.x + ((r.max.x - r.min.x) - side) * 0.5)
	oy := math.floor(r.min.y + ((r.max.y - r.min.y) - side) * 0.5)
	draw.image(dc, ic.texture, {{ox, oy}, {ox + side, oy + side}})
}
