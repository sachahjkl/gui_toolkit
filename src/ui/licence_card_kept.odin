package ui

import "base:runtime"
import img "../image"
import "../render"

// The licence card's textures and its shader, kept with the renderer (licence_card.odin). Every texture is made on a chore
// (ui.task: the relief is tens of milliseconds), uploaded at the next draw, and kept: a card shown again, another card of the
// same program, the page opened again, cost nothing. An entry is known by what it is made of (its kind and a hash of its
// inputs): a change of the lettering makes the lettering alone again.
//
// The renderer owns the GPU objects: a renderer replaced (another id) leaves its textures to it, freed when it is destroyed,
// and the entries start again; a device lost and recovered (device_generation) keeps the handles and loses their contents:
// the entries are made again on chores, the card drawn flat meanwhile. Nothing of the textures stays on the CPU.
//
// The states of an entry: Making (a chore works on it) -> Pending (its texels came, not uploaded) -> Ready (uploaded);
// Failed (it cannot be made: no outline of the face, a logo that is no picture); Lost (its contents went with the device:
// made again at its next ask).

// What a texture of the card holds.
@(private)
Licence_Texture :: enum u8 {
	Front_Relief,      // licence_card_relief.odin
	Front_Lettering,   // licence_card_engrave.odin
	Seal_Relief,       // licence_card_seal.odin
	Seal_Lettering,
	Back_Relief,       // licence_card_back.odin
	Back_Lettering,
	Logo,              // the program's logo as a picture (straight RGBA, sRGB): printed on the front
}

@(private)
Kept_State :: enum u8 { Making, Pending, Ready, Failed, Lost }

@(private)
Kept_Entry :: struct {
	kind:    Licence_Texture,
	key:     u64,             // a hash of what it is made of
	state:   Kept_State,
	texture: render.Texture,  // 0 until the first upload
	w, h:    int,
	bytes:   []u8,            // Pending: the heap's
	used:    u64,             // draw.Context.frame_no of the last draw that asked for it
}

// The shader's module, and its Direct3D 11 blob and hash (written on Windows by .github/workflows/shaders.yml; before it
// exists, or stale, create_app_shader refuses on Direct3D 11 and the card is drawn flat).
@(private) LICENCE_CARD_WGSL :: #load("licence_card.wgsl", string)
when #exists("shaders/licence_card.dxbc") && #exists("shaders/licence_card.sha256") {
	@(private) LICENCE_CARD_DXBC :: #load("shaders/licence_card.dxbc")
	@(private) LICENCE_CARD_HASH :: #load("shaders/licence_card.sha256", string)
} else {
	@(private) LICENCE_CARD_DXBC :: []u8{}
	@(private) LICENCE_CARD_HASH :: ""
}

@(private)
Kept :: struct {
	renderer: u64,               // render.renderer_id of the renderer the entries are of (0: none yet)
	device:   u64,               // its device_generation they were made on
	shader:   render.App_Shader, // 0: refused (not tried again on this renderer)
	entries:  [dynamic]Kept_Entry,   // the heap's
	epoch:    u64,               // bumps when the entries start again: a chore's answer of before is dropped
	// the engraved code's matrix packed for the shader (licence_card_back.odin): the same for every renderer, so it outlives
	// the entries; packed once, as encoding it at every draw of the back would be the same work each frame
	seal:      Seal_Bits,
	seal_made: bool,
}

// More entries than this: the one asked for least recently goes (its texture destroyed).
@(private = "file") KEPT_MOST :: 12

// The interface's thread's (the textures are its renderer's, the answers come on it).
@(private = "file", thread_local) kept: Kept

// The kept state for `r`: made again for another renderer, its entries marked Lost after a device loss. Returns the shader
// (0: it cannot be had here).
@(private)
kept_sync :: proc(r: ^render.Renderer) -> render.App_Shader {
	id := render.renderer_id(r)
	if kept.renderer != id {
		// (another renderer: its textures and shader are the old one's, which frees them; the texels on their way are dropped)
		for &e in kept.entries { delete(e.bytes, runtime.heap_allocator()) }
		clear(&kept.entries)
		if kept.entries == nil { kept.entries = make([dynamic]Kept_Entry, runtime.heap_allocator()) }
		kept.renderer, kept.device, kept.epoch = id, r.device_generation, kept.epoch + 1
		kept.shader = render.create_app_shader(r, {name = "licence-card", wgsl = LICENCE_CARD_WGSL, dxbc = LICENCE_CARD_DXBC, hash = LICENCE_CARD_HASH})
	}
	if kept.device != r.device_generation {
		// (the renderer made the shader and the textures again under the same handles: their contents are gone)
		kept.device = r.device_generation
		for &e in kept.entries { if e.state == .Ready { e.state = .Lost } }
	}
	if kept.shader != 0 && !render.app_shader_ready(r, kept.shader) { return 0 }
	return kept.shader
}

// The engraved code's packed matrix, packed at its first ask on this thread.
@(private)
kept_seal :: proc() -> ^Seal_Bits {
	if !kept.seal_made { kept.seal, kept.seal_made = seal_pack(), true }
	return &kept.seal
}

// What a chore makes an entry from (the inputs the interface's thread took).
@(private)
Kept_Input :: struct {
	word:    string,          // the relief's microprint (the heap's)
	logo:    []u8,            // the logo's picture file: the program's constant, not copied
	engrave: Engrave_Input,   // the lettering's glyphs
}

@(private = "file")
Kept_Job :: struct {
	state: ^State,
	epoch: u64,
	kind:  Licence_Texture,
	key:   u64,
	input: Kept_Input,
	out:   []u8,
	w, h:  int,
	ok:    bool,
}

// The entry of (kind, key), or nil.
@(private = "file")
kept_find :: proc(kind: Licence_Texture, key: u64) -> ^Kept_Entry {
	for &e in kept.entries { if e.kind == kind && e.key == key { return &e } }
	return nil
}

// The texture of (kind, key) on `r` when it is there, uploading what a chore made. An entry not there yet (or Lost) is made:
// `input` gives what it is made of (called then only: the lettering's glyphs are taken on this thread), and the chore's
// answer comes to `s`. settled: it is Ready or Failed (nothing more is coming). Call kept_sync first.
@(private)
kept_texture :: proc(r: ^render.Renderer, s: ^State, frame: u64, kind: Licence_Texture, key: u64, input: proc(kind: Licence_Texture, user: rawptr) -> (Kept_Input, bool), user: rawptr) -> (tex: render.Texture, settled: bool) {
	e := kept_find(kind, key)
	if e == nil {
		kept_evict(r)
		append(&kept.entries, Kept_Entry{kind = kind, key = key, state = .Lost})
		e = &kept.entries[len(kept.entries) - 1]
	}
	e.used = frame
	switch e.state {
	case .Lost:
		in_, ok := input(kind, user)
		if !ok { e.state = .Failed; return 0, true }
		e.state = .Making
		kept_launch(s, kind, key, in_)
		return 0, false
	case .Making:
		return 0, false
	case .Pending:
		kept_upload(r, e)
		return e.state == .Ready ? e.texture : 0, true
	case .Ready:
		return e.texture, true
	case .Failed:
		return 0, true
	}
	return 0, false
}

// The size and the format of an entry's texture.
@(private = "file")
kept_size :: proc(kind: Licence_Texture) -> (w, h: int) {
	switch kind {
	case .Front_Relief, .Back_Relief:        return LICENCE_RELIEF_W, LICENCE_RELIEF_H
	case .Front_Lettering, .Back_Lettering:  return LICENCE_ENGRAVE_W, LICENCE_ENGRAVE_H
	case .Seal_Relief, .Seal_Lettering:      return LICENCE_SEAL_TEX, LICENCE_SEAL_TEX
	case .Logo:                              return 0, 0
	}
	return 0, 0
}

@(private = "file")
kept_upload :: proc(r: ^render.Renderer, e: ^Kept_Entry) {
	heap := runtime.heap_allocator()
	defer { delete(e.bytes, heap); e.bytes = nil }
	most := render.max_texture_size(r)
	if e.w <= 0 || e.h <= 0 || e.w > most || e.h > most || len(e.bytes) < e.w * e.h * 4 { e.state = .Failed; return }
	if e.texture == 0 {
		e.texture = e.kind == .Logo ? render.create_texture_rgba(r, e.w, e.h) : render.create_texture_data(r, e.w, e.h, .RGBA8, mips = true)
		if e.texture == 0 { e.state = .Failed; return }
	}
	if e.kind == .Logo {
		render.update_texture_rgba(r, e.texture, 0, 0, e.w, e.h, e.bytes)
	} else {
		render.update_texture_data(r, e.texture, 0, 0, e.w, e.h, e.bytes)
	}
	e.state = .Ready
}

// Room for one more entry: the one asked for least recently goes, when there are KEPT_MOST (one a chore works on stays: its
// answer finds it).
@(private = "file")
kept_evict :: proc(r: ^render.Renderer) {
	if len(kept.entries) < KEPT_MOST { return }
	oldest := -1
	for e, i in kept.entries {
		if e.state == .Making { continue }
		if oldest < 0 || e.used < kept.entries[oldest].used { oldest = i }
	}
	if oldest < 0 { return }
	e := &kept.entries[oldest]
	if e.texture != 0 { render.destroy_texture(r, e.texture) }
	delete(e.bytes, runtime.heap_allocator())
	unordered_remove(&kept.entries, oldest)
}

@(private = "file")
kept_launch :: proc(s: ^State, kind: Licence_Texture, key: u64, in_: Kept_Input) {
	heap := runtime.heap_allocator()
	j := new(Kept_Job, heap)
	j^ = {state = s, epoch = kept.epoch, kind = kind, key = key, input = in_}
	work :: proc(d: rawptr) {
		context.allocator = runtime.heap_allocator()
		j := (^Kept_Job)(d)
		j.w, j.h = kept_size(j.kind)
		switch j.kind {
		case .Front_Relief:
			j.out = relief_map({word = j.input.word})
		case .Back_Relief:
			// (a logo that is no picture: the back without its figure)
			field: []f32
			if pic, _, ok := img.decode(j.input.logo); ok {
				field = logo_height_field(pic.pixels, pic.width, pic.height)
				delete(pic.pixels)
			} else {
				field = logo_height_field(nil, 0, 0)
			}
			j.out = relief_map({word = j.input.word, emboss = field})
			delete(field)
		case .Seal_Relief:
			j.out = seal_normal_map()
		case .Front_Lettering, .Seal_Lettering, .Back_Lettering:
			j.out = engrave_make(&j.input.engrave)
		case .Logo:
			pic, _, ok := img.decode(j.input.logo)
			if !ok { return }
			j.out, j.w, j.h = pic.pixels, pic.width, pic.height
		}
		j.ok = j.out != nil
	}
	done :: proc(d: rawptr, _: u64) {
		j := (^Kept_Job)(d)
		defer kept_job_free(j)
		if j.epoch != kept.epoch { return }
		e := kept_find(j.kind, j.key)
		if e == nil || e.state != .Making { return }
		if j.ok {
			e.state, e.bytes, e.w, e.h = .Pending, j.out, j.w, j.h
			j.out = nil
		} else {
			e.state = .Failed
		}
		// (the card that asked draws it: one frame more, even on a window at rest)
		j.state.anim_busy = true
	}
	task(s, work, done, j, proc(d: rawptr) { kept_job_free((^Kept_Job)(d)) })
}

@(private = "file")
kept_job_free :: proc(j: ^Kept_Job) {
	heap := runtime.heap_allocator()
	delete(j.input.word, heap)
	engrave_input_destroy(&j.input.engrave)
	delete(j.out, heap)
	free(j, heap)
}

// The state of an entry, for a test: Lost when there is none.
@(private)
kept_state :: proc(kind: Licence_Texture, key: u64) -> Kept_State {
	e := kept_find(kind, key)
	return e != nil ? e.state : .Lost
}

// A hash of strings and numbers (FNV-1a), what an entry is known by.
@(private)
Kept_Hash :: struct { h: u64 }

@(private)
kept_hash_begin :: proc(kind: Licence_Texture) -> Kept_Hash { return {0xcbf29ce484222325 ~ u64(kind)} }

@(private)
kept_hash_string :: proc(k: ^Kept_Hash, s: string) {
	for b in transmute([]u8)s { k.h = (k.h ~ u64(b)) * 0x100000001b3 }
	k.h = (k.h ~ 0xff) * 0x100000001b3   // (a separator: "ab" + "c" is not "a" + "bc")
}

@(private)
kept_hash_u64 :: proc(k: ^Kept_Hash, v: u64) {
	for i in 0 ..< 8 { k.h = (k.h ~ ((v >> (8 * uint(i))) & 0xff)) * 0x100000001b3 }
}
