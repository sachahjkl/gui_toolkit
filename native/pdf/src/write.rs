//! The writer: a new PDF from a list of pages (src/md/features/pdf.md, Writing). It walks the object graph from the
//! roots it writes (the base's catalog, each page) and numbers each object reached anew; what is not reached is not
//! written. A reference to a page of a source resolves to that page's new object when the list has it, to `null`
//! otherwise; a node of a source's page tree is never copied (the list has a flat tree of its own).

use std::collections::{HashMap, HashSet};

use crate::stamp::Stamp;
use hayro::hayro_syntax::object::dict::keys::{
    COLORSPACE, CONTENTS, CROP_BOX, DECODE_PARMS, DP, EXT_G_STATE, FILTER, FONT, LENGTH, MEDIA_BOX, PAGES, PARENT,
    PATTERN, PROPERTIES, RESOURCES, ROTATE, SHADING, TYPE, XOBJECT,
};
use hayro::hayro_syntax::object::{self, Array, Dict, MaybeRef, Object, ObjectIdentifier, Stream};
use hayro::hayro_syntax::page::{Page, Rotation};
use hayro::hayro_syntax::{Filter, Pdf};
use hayro::vello_cpu::kurbo::Affine;
use pdf_writer::{Chunk, Content, Name, Obj, Rect, Ref, Str};

/// A page of the list: a page of source `source` (its id, its file), or a blank page of `size` points.
pub struct PageSpec<'a> {
    pub source: Option<(u32, &'a Pdf)>,
    pub index: usize,
    pub turns: u8,
    pub size: (f32, f32),
    pub stamps: Vec<Stamp>,
}

type Key = (u32, ObjectIdentifier);

struct Writer<'a> {
    sources: HashMap<u32, &'a Pdf>,
    map: HashMap<Key, Ref>,
    queue: Vec<Key>,
    /// Every page of every source: a reference to one not in the list writes `null`.
    pages: HashSet<Key>,
    /// What writes `null` when referenced: a node of a page tree, an object that does not exist.
    dropped: HashSet<Key>,
    next: i32,
}

impl<'a> Writer<'a> {
    fn alloc(&mut self) -> Ref {
        let r = Ref::new(self.next);
        self.next += 1;
        r
    }

    fn reference(&mut self, src: u32, id: ObjectIdentifier, out: Obj<'_>) {
        let key = (src, id);
        if let Some(r) = self.map.get(&key) {
            out.primitive(*r);
            return;
        }
        if self.pages.contains(&key) || self.dropped.contains(&key) {
            out.primitive(pdf_writer::Null);
            return;
        }
        let pdf = self.sources[&src];
        let Some(obj) = pdf.xref().get::<Object<'_>>(id) else {
            self.dropped.insert(key);
            out.primitive(pdf_writer::Null);
            return;
        };
        if let Object::Dict(d) = &obj {
            if d.get::<object::Name<'_>>(TYPE).is_some_and(|n| &*n == PAGES) {
                self.dropped.insert(key);
                out.primitive(pdf_writer::Null);
                return;
            }
        }
        let r = self.alloc();
        self.map.insert(key, r);
        self.queue.push(key);
        out.primitive(r);
    }

    fn direct(&mut self, src: u32, value: &MaybeRef<Object<'_>>, out: Obj<'_>) {
        match value {
            MaybeRef::Ref(r) => self.reference(src, (*r).into(), out),
            MaybeRef::NotRef(o) => self.object(src, o, out),
        }
    }

    fn object(&mut self, src: u32, value: &Object<'_>, out: Obj<'_>) {
        match value {
            Object::Null(_) => out.primitive(pdf_writer::Null),
            Object::Boolean(b) => out.primitive(*b),
            Object::Number(n) => {
                let v = n.as_f64();
                if v.fract() == 0.0 && v.abs() < i32::MAX as f64 {
                    out.primitive(v as i32)
                } else {
                    out.primitive(v as f32)
                }
            }
            Object::String(s) => out.primitive(Str(s.as_ref())),
            Object::Name(n) => out.primitive(Name(n)),
            Object::Array(a) => {
                let mut arr = out.array();
                for item in a.raw_iter() {
                    self.direct(src, &item, arr.push());
                }
            }
            Object::Dict(d) => {
                let mut dict = out.dict();
                self.entries(src, d, &mut dict, &[]);
            }
            // (a stream is never direct: it only comes through a reference, written by `indirect`)
            Object::Stream(_) => out.primitive(pdf_writer::Null),
        }
    }

    fn entries(&mut self, src: u32, d: &Dict<'_>, out: &mut pdf_writer::Dict<'_>, skip: &[&[u8]]) {
        for (name, value) in d.entries() {
            if skip.contains(&&*name) {
                continue;
            }
            self.direct(src, &value, out.insert(Name(&name)));
        }
    }

    fn indirect(&mut self, chunk: &mut Chunk, key: Key, r: Ref) {
        let pdf = self.sources[&key.0];
        let Some(obj) = pdf.xref().get::<Object<'_>>(key.1) else {
            chunk.indirect(r).primitive(pdf_writer::Null);
            return;
        };
        match &obj {
            Object::Stream(s) => self.stream(chunk, key.0, s, r),
            other => self.object(key.0, other, chunk.indirect(r)),
        }
    }

    // The stream's bytes as they are, decrypted, its filters kept. A first filter /Crypt was the encryption's own:
    // it goes with it (hayro-write's rule).
    fn stream(&mut self, chunk: &mut Chunk, src: u32, s: &Stream<'_>, r: Ref) {
        let data = s.raw_data();
        let mut out = chunk.stream(r, &data);
        let dict = s.dict();
        if s.filters().first() != Some(&Filter::Crypt) {
            self.entries(src, dict, &mut out, &[LENGTH]);
            return;
        }
        self.entries(src, dict, &mut out, &[LENGTH, FILTER, DECODE_PARMS, DP]);
        for (key, from) in [(FILTER, &[FILTER][..]), (DECODE_PARMS, &[DECODE_PARMS, DP][..])] {
            let rest: Vec<_> = from
                .iter()
                .find_map(|k| dict.get::<Array<'_>>(k))
                .map(|a| a.raw_iter().skip(1).collect())
                .unwrap_or_default();
            if !rest.is_empty() {
                let mut arr = out.insert(Name(key)).array();
                for item in rest {
                    self.direct(src, &item, arr.push());
                }
            }
        }
    }

    fn drain(&mut self, chunk: &mut Chunk) {
        while let Some(key) = self.queue.pop() {
            let r = self.map[&key];
            self.indirect(chunk, key, r);
        }
    }

    fn page(&mut self, chunk: &mut Chunk, spec: &PageSpec<'_>, r: Ref, tree: Ref) {
        let page: Option<(u32, &Page<'_>)> =
            spec.source.and_then(|(id, pdf)| pdf.pages().get(spec.index).map(|p| (id, p)));
        let stamped = !spec.stamps.is_empty();
        let (pre, post) = if stamped { (Some(self.alloc()), Some(self.alloc())) } else { (None, None) };
        let mut fonts: Vec<(String, &'static str)> = Vec::new();
        for st in &spec.stamps {
            let base = st.font.base_name();
            if !fonts.iter().any(|(_, b)| *b == base) {
                fonts.push((format!("GtStamp{}", fonts.len()), base));
            }
        }
        let to_user;
        {
            let mut d = chunk.indirect(r).dict();
            d.pair(Name(TYPE), Name(b"Page"));
            d.pair(Name(PARENT), tree);
            let own = match page {
                Some((src, p)) => {
                    let skip: &[&[u8]] = if stamped {
                        &[TYPE, PARENT, RESOURCES, MEDIA_BOX, CROP_BOX, ROTATE, CONTENTS]
                    } else {
                        &[TYPE, PARENT, RESOURCES, MEDIA_BOX, CROP_BOX, ROTATE]
                    };
                    self.entries(src, p.raw(), &mut d, skip);
                    d.pair(Name(MEDIA_BOX), rect(&p.media_box()));
                    d.pair(Name(CROP_BOX), rect(&p.crop_box()));
                    to_user = Affine::new(p.initial_transform(true).as_coeffs()).inverse();
                    match p.rotation() {
                        Rotation::None => 0,
                        Rotation::Horizontal => 1,
                        Rotation::Flipped => 2,
                        Rotation::FlippedHorizontal => 3,
                    }
                }
                None => {
                    d.pair(Name(MEDIA_BOX), Rect::new(0.0, 0.0, spec.size.0, spec.size.1));
                    to_user = Affine::new([1.0, 0.0, 0.0, -1.0, 0.0, spec.size.1 as f64]);
                    0
                }
            };
            d.pair(Name(ROTATE), ((own + spec.turns as i32) % 4) * 90);
            {
                let mut res = d.insert(Name(RESOURCES)).dict();
                if let Some((src, p)) = page {
                    let r = p.resources();
                    for (key, sub) in [
                        (EXT_G_STATE, &r.ext_g_states),
                        (SHADING, &r.shadings),
                        (PATTERN, &r.patterns),
                        (XOBJECT, &r.x_objects),
                        (COLORSPACE, &r.color_spaces),
                        (PROPERTIES, &r.properties),
                    ] {
                        if !sub.is_empty() {
                            let mut out = res.insert(Name(key)).dict();
                            self.entries(src, sub, &mut out, &[]);
                        }
                    }
                    if !r.fonts.is_empty() || !fonts.is_empty() {
                        let mut out = res.insert(Name(FONT)).dict();
                        self.entries(src, &r.fonts, &mut out, &[]);
                        stamp_fonts(&mut out, &fonts);
                    }
                } else if !fonts.is_empty() {
                    let mut out = res.insert(Name(FONT)).dict();
                    stamp_fonts(&mut out, &fonts);
                }
            }
            if let (Some(pre), Some(post)) = (pre, post) {
                let mut arr = d.insert(Name(CONTENTS)).array();
                if let Some((src, p)) = page {
                    arr.push().primitive(pre);
                    match p.raw().get_raw::<Object<'_>>(CONTENTS) {
                        Some(MaybeRef::Ref(cr)) => {
                            let id: ObjectIdentifier = cr.into();
                            // (an array of streams behind a reference: its items, not the array, go in ours)
                            if let Some(a) = self.sources[&src].xref().get::<Array<'_>>(id) {
                                for item in a.raw_iter() {
                                    self.direct(src, &item, arr.push());
                                }
                            } else {
                                self.reference(src, id, arr.push());
                            }
                        }
                        Some(MaybeRef::NotRef(Object::Array(a))) => {
                            for item in a.raw_iter() {
                                self.direct(src, &item, arr.push());
                            }
                        }
                        _ => {}
                    }
                }
                arr.push().primitive(post);
            }
        }
        if let (Some(pre), Some(post)) = (pre, post) {
            // (the page's own content wrapped in q and Q: a page that leaves its graphics state changed does not move
            // the stamps)
            if page.is_some() {
                chunk.stream(pre, b"q\n");
            } else {
                chunk.stream(pre, b"");
            }
            let mut content = Content::new();
            if page.is_some() {
                content.restore_state();
            }
            for st in &spec.stamps {
                let name = &fonts.iter().find(|(_, b)| *b == st.font.base_name()).unwrap().0;
                st.draw(&mut content, to_user, Name(name.as_bytes()));
            }
            chunk.stream(post, &content.finish());
        }
    }
}

fn stamp_fonts(out: &mut pdf_writer::Dict<'_>, fonts: &[(String, &'static str)]) {
    for (name, base) in fonts {
        let mut f = out.insert(Name(name.as_bytes())).dict();
        f.pair(Name(b"Type"), Name(b"Font"));
        f.pair(Name(b"Subtype"), Name(b"Type1"));
        f.pair(Name(b"BaseFont"), Name(base.as_bytes()));
        f.pair(Name(b"Encoding"), Name(b"WinAnsiEncoding"));
    }
}

fn rect(r: &object::Rect) -> Rect {
    Rect::new(r.x0 as f32, r.y0 as f32, r.x1 as f32, r.y1 as f32)
}

/// The file of `pages`. With `base` (a source's id and file), its catalog is kept: outlines, the form, the structure,
/// the page labels, its metadata.
pub fn write(pages: &[PageSpec<'_>], base: Option<(u32, &Pdf)>) -> Vec<u8> {
    let mut w = Writer {
        sources: HashMap::new(),
        map: HashMap::new(),
        queue: Vec::new(),
        pages: HashSet::new(),
        dropped: HashSet::new(),
        next: 1,
    };
    for (id, pdf) in pages.iter().filter_map(|p| p.source).chain(base) {
        if w.sources.insert(id, pdf).is_none() {
            for p in pdf.pages().iter() {
                if let Some(oid) = p.raw().obj_id() {
                    w.pages.insert((id, oid));
                }
            }
        }
    }
    let catalog = w.alloc();
    let tree = w.alloc();
    let info = w.alloc();
    let mut refs = Vec::with_capacity(pages.len());
    for spec in pages {
        let r = w.alloc();
        refs.push(r);
        if let Some((id, pdf)) = spec.source {
            if let Some(oid) = pdf.pages().get(spec.index).and_then(|p| p.raw().obj_id()) {
                // (the first time a page comes: the references to it name this one)
                w.map.entry((id, oid)).or_insert(r);
            }
        }
    }

    let mut out = pdf_writer::Pdf::new();
    let mut chunk = Chunk::new();
    {
        let mut cat = out.catalog(catalog);
        cat.pages(tree);
        if let Some((id, pdf)) = base {
            if let Some(root) = pdf.xref().get::<Dict<'_>>(pdf.xref().root_id()) {
                w.entries(id, &root, &mut cat, &[TYPE, PAGES]);
            }
        }
    }
    out.pages(tree).kids(refs.iter().copied()).count(refs.len() as i32);
    for (spec, r) in pages.iter().zip(&refs) {
        w.page(&mut chunk, spec, *r, tree);
    }
    w.drain(&mut chunk);
    if let Some((_, pdf)) = base {
        let m = pdf.metadata();
        let mut d = out.document_info(info);
        for (key, value) in [
            (&b"Title"[..], &m.title),
            (b"Author", &m.author),
            (b"Subject", &m.subject),
            (b"Keywords", &m.keywords),
            (b"Creator", &m.creator),
            (b"Producer", &m.producer),
        ] {
            if let Some(v) = value {
                d.pair(Name(key), Str(v));
            }
        }
    }
    out.extend(&chunk);
    out.finish()
}
