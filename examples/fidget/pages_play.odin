package fidget

// Playground: physics balls (gravity, collisions, mouse repel), confetti, a fidget spinner, the live accent
// color picker and draggable sticky notes. Ball/note positions are stored in logical pixels so they survive
// DPI and zoom changes.

import "core:fmt"
import "core:math"
import "../../draw"
import "../../platform"
import "../../ui"

spawn_ball :: proc(app: ^App, p, v: [2]f32) {
	slot := -1
	for b, i in app.balls { if !b.alive { slot = i; break } }
	if slot < 0 { slot = int(rand_u64() % BALL_MAX) }
	app.balls[slot] = {alive = true, p = p, v = v, r = rand_range(7, 17), c = draw.hsv(rand01(), 0.65, 1)}
}

spawn_balls :: proc(app: ^App, count: int) {
	dim := app.arena_size
	if dim.x < 50 { return }
	for _ in 0 ..< count {
		spawn_ball(app, {rand_range(dim.x * 0.1, dim.x * 0.9), rand_range(dim.y * 0.05, dim.y * 0.4)}, {rand_range(-300, 300), rand_range(-200, 100)})
	}
	app.phys_run = true
}

spawn_confetti :: proc(app: ^App, origin: [2]f32, count: int) {
	spawned := 0
	for &p in app.parts {
		if spawned >= count { break }
		if p.alive { continue }
		ang := rand_range(-math.PI * 0.95, -math.PI * 0.05)
		spd := rand_range(250, 900)
		p = {alive = true, p = origin, v = {math.cos(ang) * spd, math.sin(ang) * spd}, size = rand_range(4, 9), c = draw.hsv(rand01(), 0.75, 1)}
		p.max_life = rand_range(1.1, 2.3)
		p.life = p.max_life
		spawned += 1
	}
}

@(private)
physics_active :: proc(app: ^App) -> bool {
	if app.phys_run { for b in app.balls { if b.alive { return true } } }
	for p in app.parts { if p.alive { return true } }
	return false
}

@(private)
physics_step :: proc(app: ^App, dim, mouse: [2]f32, mouse_in: bool, dt: f32) {
	grav := app.gravity * 900
	repel_r: f32 = 130
	if app.phys_run {
		for &b in app.balls {
			if !b.alive { continue }
			b.v.y += grav * dt
			if app.repel && mouse_in {
				d := b.p - mouse
				dist := math.sqrt(d.x * d.x + d.y * d.y)
				if dist < repel_r && dist > 0.01 {
					k := (1 - dist / repel_r) * 5200 * dt / dist
					b.v += d * k
				}
			}
			b.v *= 1 - 0.15 * dt
			b.p += b.v * dt
			if b.p.x < b.r { b.p.x = b.r; b.v.x = -b.v.x * app.bounce }
			if b.p.x > dim.x - b.r { b.p.x = dim.x - b.r; b.v.x = -b.v.x * app.bounce }
			if b.p.y < b.r { b.p.y = b.r; b.v.y = -b.v.y * app.bounce }
			if b.p.y > dim.y - b.r {
				b.p.y = dim.y - b.r
				b.v.y = -b.v.y * app.bounce
				b.v.x *= 1 - 2 * dt
				if abs(b.v.y) < 14 { b.v.y = 0 }
			}
		}
		for i in 0 ..< BALL_MAX {
			a := &app.balls[i]
			if !a.alive { continue }
			for j in i + 1 ..< BALL_MAX {
				b := &app.balls[j]
				if !b.alive { continue }
				d := b.p - a.p
				min_d := a.r + b.r
				dd := d.x * d.x + d.y * d.y
				if dd >= min_d * min_d || dd < 0.0001 { continue }
				dist := math.sqrt(dd)
				n := d / dist
				overlap := (min_d - dist) * 0.5
				a.p -= n * overlap
				b.p += n * overlap
				rel := (b.v.x - a.v.x) * n.x + (b.v.y - a.v.y) * n.y
				if rel < 0 {
					imp := -(1 + app.bounce) * rel * 0.5
					a.v -= n * imp
					b.v += n * imp
				}
			}
		}
	}
	for &p in app.parts {
		if !p.alive { continue }
		p.life -= dt
		if p.life <= 0 { p.alive = false; continue }
		p.v.y += 1500 * dt
		p.v *= 1 - 1.4 * dt
		p.p += p.v * dt
	}
}

Arena_Draw :: struct { app: ^App, scale: f32 }

@(private)
arena_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Arena_Draw)(user)
	app := d.app
	s := d.scale
	o := b.rect.min
	for ball in app.balls {
		if !ball.alive { continue }
		c := o + ball.p * s
		r := ball.r * s
		glow := ball.c
		glow.a = 0.16
		draw.rect(dc, {{c.x - r * 1.9, c.y - r * 1.9}, {c.x + r * 1.9, c.y + r * 1.9}}, glow, r * 1.9, 0, r * 0.9)
		draw.rect(dc, {{c.x - r, c.y - r}, {c.x + r, c.y + r}}, ball.c, r)
		draw.rect(dc, {{c.x - r * 0.55, c.y - r * 0.7}, {c.x - r * 0.05, c.y - r * 0.2}}, {1, 1, 1, 0.45}, r * 0.25)
	}
	for p in app.parts {
		if !p.alive { continue }
		c := o + p.p * s
		col := p.c
		col.a = clamp(p.life / p.max_life * 1.6, 0, 1)
		sz := p.size * s * 0.5
		draw.rect(dc, {{c.x - sz, c.y - sz}, {c.x + sz, c.y + sz}}, col, sz * 0.4)
	}
}

Spin_Draw :: struct { angle, omega: f32, accent, track, text: draw.Color, mono: int }

@(private)
spinner_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Spin_Draw)(user)
	c := draw.rect_center(b.rect)
	dim := b.rect.max - b.rect.min
	radius := min(dim.x, dim.y) * 0.34
	for k in 0 ..< 3 {
		th := (d.angle + f32(k) / 3) * math.TAU
		dir := [2]f32{math.cos(th), math.sin(th)}
		col := d.accent
		if k == 1 { col = draw.mix(d.accent, {1, 1, 1, 1}, 0.25) }
		if k == 2 { col = draw.mix(d.accent, {0, 0, 0, 1}, 0.2) }
		for pass in 0 ..< 2 {
			for j in 0 ..= 10 {
				t := f32(j) / 10
				rr := math.lerp(radius * 0.30, radius * 0.20, t)
				p := c + dir * radius * t
				if pass == 0 {
					draw.rect(dc, {{p.x - rr, p.y - rr + 3}, {p.x + rr, p.y + rr + 3}}, {0, 0, 0, 0.18}, rr, 0, 6)
				} else {
					draw.rect(dc, {{p.x - rr, p.y - rr}, {p.x + rr, p.y + rr}}, col, rr)
				}
			}
		}
		e := c + dir * radius
		lr := radius * 0.36
		draw.rect(dc, {{e.x - lr, e.y - lr}, {e.x + lr, e.y + lr}}, col, lr)
		hr := radius * 0.22
		draw.rect(dc, {{e.x - hr, e.y - hr}, {e.x + hr, e.y + hr}}, d.track, hr)
	}
	hub := radius * 0.30
	draw.rect(dc, {{c.x - hub, c.y - hub}, {c.x + hub, c.y + hub}}, d.track, hub)
	pin := radius * 0.12
	draw.rect(dc, {{c.x - pin, c.y - pin}, {c.x + pin, c.y + pin}}, d.text, pin)
}

page_playground :: proc(app: ^App) {
	em := ui.font_size()
	s := ui.scale()
	if page_begin("###pg_play") {
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(id = "###cols") {
			if half("###left", 0.56) {
				if ui.card("Physics arena", ICON_DOT) {
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.5))})
					if ui.row(.Center, id = "###physrow") {
						ui.next({width = ui.pct(0.5), height = ui.pct(1)})
						ui.toggle("###ph_run", "Simulate", &app.phys_run)
						ui.spacer(ui.px(em * 0.6))
						ui.next({width = ui.pct(0.5), height = ui.pct(1)})
						ui.toggle("###ph_rep", "Mouse repels", &app.repel)
					}
					if ui.form_row("Gravity") { ui.slider("###ph_g", &app.gravity, 0, 2, 0, "%.2f") }
					if ui.form_row("Bounce") { ui.slider("###ph_b", &app.bounce, 0.1, 1, 0, "%.2f") }
					ui.spacer(ui.px(em * 0.3))
					if ui.flow({em * 0.5, em * 0.5}, "###spawnrow") {
						if ui.tags("accent_button") {
							if ui.button_icon("###ph_add", ui.ICON_ADD, "25 balls").clicked { spawn_balls(app, 25) }
						}
						if ui.button_icon("###ph_shake", "", "Shake").clicked {
							for &b in app.balls { if b.alive { b.v += {rand_range(-900, 900), -rand_range(300, 1400)} } }
						}
						if ui.button_icon("###ph_conf", ICON_TARGET, "Confetti").clicked { run_cmd(app, .Confetti) }
						if ui.tags("ghost_button") {
							if ui.button_icon("###ph_clear", ICON_TRASH, "Clear").clicked { run_cmd(app, .Clear_Balls) }
						}
					}
					ui.spacer(ui.px(em * 0.3))

					// the arena (positions are logical pixels relative to the box)
					if ui.tags("input") {
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 21)), radius = em * 0.6})
						arena := ui.build_box({.Clickable, .Draw_Background, .Draw_Border, .Clip}, "###ball_arena")
						arena.cursor = .Arrow
						ad := ui.frame_new(Arena_Draw)
						ad.app, ad.scale = app, s
						arena.custom, arena.custom_user = arena_draw, ad
						if arena.size.x > 10 { app.arena_size = (arena.rect.max - arena.rect.min) / s }
						sig := ui.signal(arena)
						local := (ui.mouse_pos() - arena.rect.min) / s
						inside := sig.hovering || sig.dragging
						if !app.balls_seeded && app.arena_size.x > 50 { app.balls_seeded = true; spawn_balls(app, 16) }
						now := ui.now_ms()
						if sig.pressed || (sig.dragging && now >= app.spawn_next_ms) {
							spawn_ball(app, local, {rand_range(-200, 200), rand_range(-400, -100)})
							app.phys_run = true
							app.spawn_next_ms = now + 35
						}
						if sig.right_clicked { spawn_confetti(app, local, 90) }
						if physics_active(app) || sig.dragging {
							physics_step(app, app.arena_size, local, inside, clamp(app.real_dt, 0.001, 0.033))
							app.frames_requested = 4
						}
					}
					alive := 0
					for b in app.balls { if b.alive { alive += 1 } }
					if ui.tags("weak") {
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2)), font_size = math.round(em * 0.85)})
						ui.label(fmt.tprintf("%d balls  |  click / drag to spawn  |  right-click for confetti", alive))
					}
				}
			}
			ui.spacer(ui.px(em))
			if half("###right", 0.44) {
				if ui.card("Fidget spinner", ICON_REFRESH) {
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 15)), cursor = platform.Cursor.Hand})
					sp := ui.build_box({.Clickable}, "###spinner")
					sig := ui.signal(sp)
					c := draw.rect_center(sp.rect)
					m := ui.mouse_pos() - c
					ang := math.atan2(m.y, m.x) / math.TAU
					dt := clamp(app.real_dt, 0.001, 0.05)
					if sig.pressed { app.spin_prev = ang }
					if sig.dragging {
						delta := ang - app.spin_prev
						if delta > 0.5 { delta -= 1 }
						if delta < -0.5 { delta += 1 }
						app.spin_angle += delta
						app.spin_omega = math.lerp(app.spin_omega, delta / dt, f32(0.45))
						app.spin_prev = ang
						app.frames_requested = 4
					} else {
						app.spin_angle += app.spin_omega * dt
						app.spin_omega *= math.exp(-0.55 * dt)
						if abs(app.spin_omega) < 0.004 { app.spin_omega = 0 } else { app.frames_requested = 4 }
					}
					d := ui.frame_new(Spin_Draw)
					d.angle, d.omega = app.spin_angle, app.spin_omega
					d.accent, d.track, d.text = ui.color("accent"), ui.color("track"), ui.color("text")
					sp.custom, sp.custom_user = spinner_draw, d
					if ui.tags("weak") {
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.9)), font_size = math.round(em * 0.85)})
						ui.label(fmt.tprintf("Grab and flick it: %d rpm, friction slows it down.", int(abs(app.spin_omega) * 60)))
					}
				}
				if ui.card("Accent color (live theme edit)", ICON_PALETTE) {
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 9.5))})
					if ui.row(id = "###pickrow") {
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 9)), radius = em * 0.4})
						if ui.sat_val_picker("###sv", app.hue, &app.sat, &app.val) { app.accent_override = true }
						ui.spacer(ui.px(em * 0.7))
						ui.next({width = ui.px(em * 1.9), height = ui.px(em * 9), radius = em * 0.4})
						if ui.hue_picker("###hue", &app.hue) { app.accent_override = true }
					}
					ui.spacer(ui.px(em * 0.5))
					ui.spacer(ui.px(em * 0.3))
					if ui.flow({em * 0.35, em * 0.35}, "###swatchrow") {
						hues := [?]f32{0.62, 0.08, 0.40, 0.83, 0.52, 0.02, 0.13}
						for h, i in hues {
							ui.next({width = ui.px(em * 2.1), height = ui.px(em * 2.1), radius = em, bg = draw.hsv(h, 0.65, 0.95)})
							sw := ui.build_box({.Clickable, .Draw_Background, .Draw_Border, .Fixed_Radius}, fmt.tprintf("###swatch_%d", i))
							sw.cursor = .Hand
							if ui.signal(sw).clicked { app.hue, app.sat, app.val = h, 0.65, 0.95; app.accent_override = true }
						}
					}
					ui.spacer(ui.px(em * 0.3))
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.8))})
					if ui.row(.Center, id = "###accresetrow") {
						if ui.button_icon("###acc_reset", ICON_UNDO, "Reset to palette accent", disabled = !app.accent_override).clicked {
							set_palette(app, app.palette_idx)
						}
					}
				}
				if ui.card("Sticky notes (drag them)", ICON_PIN) {
					build_notes(app, em)
				}
			}
		}
	}
}

@(private)
build_notes :: proc(app: ^App, em: f32) {
	s := ui.scale()
	if ui.tags("input") {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 19)), radius = em * 0.6, axis = .Y})
		area := ui.build_box({.Draw_Background, .Draw_Border, .Clip}, "###notes_area")
		adim := (area.rect.max - area.rect.min) / s
		bring_front := -1
		if ui.parent(area) {
			for oi in 0 ..< len(app.note_order) {
				ni := app.note_order[oi]
				n := &app.notes[ni]
				nw := min(n.size.x, max(adim.x - 4, 50)) * s
				nh := n.size.y * s
				if ui.tags("card") {
					ui.next({fixed_x = n.pos.x * s, fixed_y = n.pos.y * s, fixed_w = nw, fixed_h = nh, radius = em * 0.6, axis = .Y})
					nb := ui.build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Clip}, fmt.tprintf("###note_%d", ni))
					nb.cursor = .Arrow
					if ui.parent(nb) {
						if ui.tags("bar") {
							ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.9)), cursor = platform.Cursor.Move})
							hd := ui.row_box({.Clickable, .Draw_Background, .Draw_Side_Bottom}, fmt.tprintf("###note_hd_%d", ni))
							if ui.parent(hd) {
								ui.spacer(ui.px(em * 0.6))
								if ui.tags("weak") { ui.icon(ICON_PIN, em * 1.5) }
								ui.next({width = ui.fill(), height = ui.pct(1)})
								ui.label(n.title)
							}
							hs := ui.signal(hd)
							if hs.pressed { ui.drag_store({n.pos.x, n.pos.y, 0, 0}); bring_front = oi }
							if hs.dragging {
								start := ui.drag_load()
								n.pos.x = clamp(start[0] + hs.drag_delta.x / s, 0, max(0, adim.x - nw / s))
								n.pos.y = clamp(start[1] + hs.drag_delta.y / s, 0, max(0, adim.y - nh / s))
								app.frames_requested = 4
							}
						}
						ui.spacer(ui.px(em * 0.3))
						note_body(app, n, em)
					}
					if ui.signal(nb).pressed { bring_front = oi }
				}
			}
		}
		// later siblings draw on top (and win hit testing): the front note is the last one
		last := len(app.note_order) - 1
		if bring_front >= 0 && bring_front < last {
			v := app.note_order[bring_front]
			for j := bring_front; j < last; j += 1 { app.note_order[j] = app.note_order[j + 1] }
			app.note_order[last] = v
		}
	}
}

@(private)
note_body :: proc(app: ^App, n: ^Note, em: f32) {
	switch n.kind {
	case 0:
		if ui.tags("weak") {
			if ui.style({width = ui.fill(), height = ui.px(ui.dense(em * 1.6)), font_size = math.round(em * 0.9)}) {
				ui.label("Drag my title bar.")
				ui.label("Click to bring me to front.")
			}
		}
	case 1:
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
		if ui.row(.Center, id = "###note_cnt") {
			ui.spacer(ui.px(em * 0.5))
			ui.stepper("###note_step", &app.note_counter, -99, 999)
		}
	case 2:
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.1))})
		ui.toggle("###note_sw", " Repel", &app.repel)
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.1))})
		ui.slider("###note_sl", &app.slider[1], 0, 1, 0, "%.2f")
	}
}
