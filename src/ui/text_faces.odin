package ui

// The program's three text faces (docs/text-faces in docs/font-picker.md; their reasons: src/md/features/font-picker.md,
// "Who applies the families"): the interface's, the monospace one and the reading one. Each is the program's own face
// until a family is chosen for it (use_text_family, which the standard settings call: prefs_page.standard_watch); the
// chosen family's face is loaded on a chore and swapped in when it comes, for every window: a view's window reads its
// owner's (style_root).
//
// Its machine, per face (Family_Face):
//   the program's -> (a family asked) -> loading -> (the chore's answer) -> the family's | missing (the program's)
//   any -> (Default, "") -> the program's, at once
// A newer ask drops the answer of an older one.

import "base:runtime"
import "core:log"
import "core:strings"
import "core:sync"
import "../ascii"
import "../font"

Text_Face :: enum u8 { Interface, Mono, Prose }
Text_Faces :: [Text_Face]font.Font_Id

// A face of a family named by the person, loaded on a chore. The caller's (the State's for the text faces), kept as long
// as the State it is loaded in: the chore's answer comes in that State's builds. family_face_destroy frees it.
Family_Face :: struct {
	family:  string,         // the family asked ("": none; heap)
	face:    font.Font_Id,   // its face once loaded (0: none asked, not loaded yet, or missing)
	loading: bool,           // a chore loads `family`
	missing: bool,           // the source has no face for `family`
	serial:  u64,            // counts the changes of `face`
	asked:   u64,            // counts the asks: an answer to an older one is dropped
}

family_face_destroy :: proc(ff: ^Family_Face) {
	delete(ff.family, runtime.heap_allocator())
	// (an answer still on its way finds `asked` changed: it is dropped)
	ff^ = {asked = ff.asked + 1}
}

// Asks for the face of `family` in `s`'s builds ("": none, at once). The same family asked again (by ASCII fold) changes
// nothing. The face is loaded by `source.face` on a chore (zero source: the system's, font_system_source), with its bold
// and italic faces when they come from the system: a bold word drawn then reads them from gt:font's cache, not the disk.
family_face_set :: proc(s: ^State, ff: ^Family_Face, family: string, source := Font_Source{}) {
	a := runtime.heap_allocator()
	if ascii.equal_fold(family, ff.family) && (family == "" || ff.face != 0 || ff.loading || ff.missing) { return }
	ff.asked += 1
	delete(ff.family, a)
	ff.family = strings.clone(family, a)
	ff.missing = false
	if family == "" {
		ff.loading = false
		if ff.face != 0 { ff.face = 0; ff.serial += 1 }
		s.anim_busy = true   // (the next build draws in the program's face)
		return
	}
	src := source
	if src.face == nil { src = font_system_source(s.fonts) }
	ff.loading = true
	job := new(Family_Face_Job, a)
	job^ = {ff = ff, s = s, source = src, fonts = s.fonts, family = strings.clone(family, a), asked = ff.asked}
	sync.atomic_add(&s.font_jobs, 1)
	task(s, family_face_work, family_face_done, job, family_face_lost)
}

@(private = "file")
Family_Face_Job :: struct {
	ff:     ^Family_Face,
	s:      ^State,
	source: Font_Source,
	fonts:  ^font.State,
	family: string,   // (the job's: the Family_Face may ask another meanwhile)
	asked:  u64,
	id:     font.Font_Id,
	worked: bool,   // its work ran (and counted itself out of State.font_jobs)
}

@(private = "file")
family_face_work :: proc(d: rawptr) {
	job := (^Family_Face_Job)(d)
	// (the last read of fonts and of the State's counter: once it drops, destroy may return and the owner free both)
	job.worked = true
	defer sync.atomic_sub(&job.s.font_jobs, 1)
	job.id = job.source.face(job.source.user, job.family)
	if job.id == 0 || job.fonts == nil { return }
	// (warmed here, off the interface's thread: font.styled_face loads a system face's bold from the disk)
	_ = font.styled_face(job.fonts, job.id, true, false)
	_ = font.styled_face(job.fonts, job.id, false, true)
	_ = font.styled_face(job.fonts, job.id, true, true)
}

@(private = "file")
family_face_done :: proc(d: rawptr, _: u64) {
	job := (^Family_Face_Job)(d)
	defer family_face_lost(d)
	ff := job.ff
	if ff.asked != job.asked { return }
	ff.loading = false
	ff.missing = job.id == 0
	if ff.missing { log.warnf("no font %q on this system: the program's own face stays", job.family) }
	if ff.face != job.id { ff.face = job.id; ff.serial += 1 }
	job.s.anim_busy = true   // (its views' windows follow at their next build)
}

@(private = "file")
family_face_lost :: proc(d: rawptr) {
	a := runtime.heap_allocator()
	job := (^Family_Face_Job)(d)
	// (refused before it ran: its work never counted itself out)
	if !job.worked { sync.atomic_sub(&job.s.font_jobs, 1) }
	delete(job.family, a)
	free(job, a)
}

////////////////////////////////
// The State's text faces

// The program's own faces (0: the interface's is Build_Params.base.font, the monospace one State.mono_font, the reading
// one the interface's), and where the chosen families' faces come from (zero: the system's). Once, at the start
// (prefs_page.standard_watch does it with its Standard_Targets). begin_build puts the interface face in use in the place
// of Build_Params.base.font, which must then stay the program's own face when `own` gives no interface face.
set_text_faces :: proc(s: ^State, own: Text_Faces, source := Font_Source{}) {
	if s.text_own != own { s.text_own = own; s.text_serial += 1 }
	s.text_source = source
}

// The family `family` for the face `which` ("": the program's own, at once). Its face replaces the program's when the
// chore that loads it answers; a family the source does not have leaves the program's (logged).
use_text_family :: proc(s: ^State, which: Text_Face, family: string) {
	family_face_set(s, &s.text_chosen[which], family, s.text_source)
}

// Where the families' faces of `s` come from: the program's source (set_text_faces), else the system's.
text_font_source :: proc(s: ^State) -> Font_Source {
	r := style_root(s)
	if r.text_source.face != nil || r.text_source.families != nil { return r.text_source }
	return font_system_source(r.fonts)
}

// The face `which` of `s` draws in: the chosen family's once loaded, else the program's own (0: none of its own: the
// monospace and reading faces then follow the interface's, which the caller takes).
state_text_face :: proc(s: ^State, which: Text_Face) -> font.Font_Id {
	r := style_root(s)
	if f := r.text_chosen[which].face; f != 0 { return f }
	// (the theme's family is the interface's alone, and only while the person asked none: the person's word wins, even
	// while their family loads or is missing)
	if which == .Interface && r.text_chosen[which].family == "" {
		if f := r.text_themed.face; f != 0 { return f }
	}
	return text_own_face(r, which)
}

// Asks the interface family of the theme shown (Theme_Font.family; "": none), once per change of it: begin_build calls
// it. A view's window reads its owner's (style_root), so only the owner asks.
@(private)
text_theme_follow :: proc(s: ^State) {
	if style_root(s) != s { return }
	family := s.theme != nil ? s.theme.look.font.family : ""
	family_face_set(s, &s.text_themed, family, s.text_source)
}

text_face :: proc(which: Text_Face) -> font.Font_Id { return state_text_face(gs(), which) }

// The face the program gives `which` (what Default draws in), the interface's for the others when it gives none.
program_text_face :: proc(s: ^State, which: Text_Face) -> font.Font_Id {
	r := style_root(s)
	if f := text_own_face(r, which); f != 0 { return f }
	return text_own_face(r, .Interface)
}

// The family asked for `which` ("": the program's), and whether its face is still on its way.
text_family :: proc(s: ^State, which: Text_Face) -> (family: string, loading: bool) {
	ff := &style_root(s).text_chosen[which]
	return ff.family, ff.loading
}

// Counts the changes of the text faces of `s` (and of the window it follows): a program that keeps what it laid out
// with them (its own cache of measured text, a face of its own derived from them) makes it again when this moves.
text_faces_serial :: proc(s: ^State) -> u64 {
	r := style_root(s)
	n := r.text_serial + r.text_themed.serial
	for ff in r.text_chosen { n += ff.serial }
	return n
}

// The reading face: the chosen family's, the program's, else the interface's.
prose_font :: proc() -> font.Font_Id {
	if f := text_face(.Prose); f != 0 { return f }
	if f := text_face(.Interface); f != 0 { return f }
	return top_style().font
}

@(private)
text_own_face :: proc(r: ^State, which: Text_Face) -> font.Font_Id {
	if f := r.text_own[which]; f != 0 { return f }
	switch which {
	case .Interface: return r.base_style.font
	case .Mono:      return r.mono_font
	case .Prose:     return 0
	}
	return 0
}

@(private)
text_faces_destroy :: proc(s: ^State) {
	for &ff in s.text_chosen { family_face_destroy(&ff) }
	family_face_destroy(&s.text_themed)
}
