use super::*;
use hayro::hayro_syntax::object::dict::keys::{ANNOTS, DEST, FIRST, OUTLINES, P};
use hayro::hayro_syntax::object::{Array, Dict, Object, ObjectIdentifier};
use pdf_writer::{Content, Name, Rect, Ref, Str, TextStr};

// A two-page file: page 1 has a note whose /P names it; the outline's one entry goes to page 2; each page's content
// carries a word of its own.
fn two_pages() -> Vec<u8> {
    let mut pdf = pdf_writer::Pdf::new();
    let (catalog, tree, p1, p2, c1, c2, annot, outlines, entry, font) =
        (Ref::new(1), Ref::new(2), Ref::new(3), Ref::new(4), Ref::new(5), Ref::new(6), Ref::new(7), Ref::new(8), Ref::new(9), Ref::new(10));
    pdf.catalog(catalog).pages(tree).outlines(outlines);
    pdf.pages(tree).kids([p1, p2]).count(2);
    for (page, content) in [(p1, c1), (p2, c2)] {
        let mut pg = pdf.page(page);
        pg.parent(tree).media_box(Rect::new(0.0, 0.0, 200.0, 100.0)).contents(content);
        pg.resources().fonts().pair(Name(b"F1"), font);
        if page == p1 {
            pg.annotations([annot]);
        }
    }
    pdf.type1_font(font).base_font(Name(b"Helvetica"));
    for (content, word) in [(c1, &b"PAGE-ONE"[..]), (c2, b"PAGE-TWO-SECRET")] {
        let mut c = Content::new();
        c.begin_text().set_font(Name(b"F1"), 12.0).next_line(10.0, 50.0).show(Str(word)).end_text();
        pdf.stream(content, &c.finish());
    }
    {
        let mut a = pdf.indirect(annot).dict();
        a.pair(Name(b"Type"), Name(b"Annot"));
        a.pair(Name(b"Subtype"), Name(b"Text"));
        a.pair(Name(b"Rect"), Rect::new(10.0, 10.0, 30.0, 30.0));
        a.pair(Name(b"P"), p1);
    }
    pdf.outline(outlines).first(entry).last(entry).count(1);
    {
        let mut e = pdf.outline_item(entry);
        e.title(TextStr("Two")).parent(outlines);
        e.insert(Name(b"Dest")).array().item(p2).item(Name(b"Fit"));
    }
    pdf.finish()
}

fn open(bytes: Vec<u8>) -> u32 {
    let mut id = 0;
    let r = unsafe { gt_pdf_open(bytes.as_ptr(), bytes.len(), std::ptr::null(), 0, &mut id) };
    assert_eq!(r, OPENED);
    id
}

fn write_pages(pages: &[GtPdfPage], base: u32) -> Vec<u8> {
    let mut out: *mut u8 = std::ptr::null_mut();
    let n = unsafe { gt_pdf_write(pages.as_ptr(), pages.len(), base, &mut out) };
    assert!(n > 0, "written");
    let v = unsafe { std::slice::from_raw_parts(out, n).to_vec() };
    unsafe { gt_pdf_free(out, n) };
    v
}

fn page(source: u32, index: u32, turns: u32) -> GtPdfPage {
    GtPdfPage { source, index, turns, width: 0.0, height: 0.0, stamps: std::ptr::null(), stamp_count: 0, shapes: std::ptr::null(), shape_count: 0 }
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

#[test]
fn a_removed_page_leaves_the_file_and_what_named_it_names_nothing() {
    let id = open(two_pages());
    let out = write_pages(&[page(id, 0, 0)], id);
    assert!(!contains(&out, b"PAGE-TWO-SECRET"), "the removed page's content is not in the file");
    let pdf = Pdf::new(out).expect("the written file opens");
    assert_eq!(pdf.pages().len(), 1);
    let first = &pdf.pages()[0];
    let page_id = first.raw().obj_id().expect("a page is an object of its own");
    let annots = first.raw().get::<Array<'_>>(ANNOTS).expect("the note is kept");
    let note = annots.iter::<Dict<'_>>().next().expect("one note");
    let p: ObjectIdentifier = note.get_ref(P).expect("its /P").into();
    assert_eq!(p, page_id, "the note's /P names the new page 1");
    let root = pdf.xref().get::<Dict<'_>>(pdf.xref().root_id()).unwrap();
    let outline = root.get::<Dict<'_>>(OUTLINES).expect("the outline is kept");
    let entry = outline.get::<Dict<'_>>(FIRST).expect("its entry");
    let dest = entry.get::<Array<'_>>(DEST).expect("its destination");
    assert!(matches!(dest.iter::<Object<'_>>().next(), Some(Object::Null(_))), "the destination's page is null: the removed page does not come back");
    gt_pdf_close(id);
}

#[test]
fn pages_move_turn_and_come_from_two_files() {
    let a = open(two_pages());
    let b = open(two_pages());
    let out = write_pages(&[page(a, 1, 0), page(b, 0, 1), page(a, 0, 3)], a);
    let pdf = Pdf::new(out).expect("opens");
    assert_eq!(pdf.pages().len(), 3);
    let dims: Vec<_> = pdf.pages().iter().map(|p| p.render_dimensions()).collect();
    assert_eq!(dims[0], (200.0, 100.0));
    assert_eq!(dims[1], (100.0, 200.0), "a quarter turn swaps the sides");
    assert_eq!(dims[2], (100.0, 200.0));
    gt_pdf_close(a);
    gt_pdf_close(b);
}

#[test]
fn a_stamp_is_drawn_where_it_was_put_on_a_blank_page() {
    let text = b"Hello";
    let stamp = GtPdfStamp { x: 20.0, y: 30.0, size: 20.0, turns: 0, font: 0, color: 0xFFFFFF, background: 0x000000FF, text: text.as_ptr(), text_len: text.len() };
    let (mut w, mut h) = (0.0, 0.0);
    unsafe { gt_pdf_stamp_measure(&stamp, &mut w, &mut h) };
    assert!(w > 40.0 && h > 20.0, "{w} x {h}");
    let p = GtPdfPage { source: 0, index: 0, turns: 0, width: 200.0, height: 100.0, stamps: &stamp, stamp_count: 1, shapes: std::ptr::null(), shape_count: 0 };
    let mut px = vec![0u8; 200 * 100 * 4];
    assert!(unsafe { gt_pdf_render(&p, 200, 100, false, px.as_mut_ptr()) });
    let at = |x: usize, y: usize| { let i = (y * 200 + x) * 4; [px[i], px[i + 1], px[i + 2]] };
    assert_eq!(at(5, 5), [255, 255, 255], "the paper is white");
    assert_eq!(at(22, 32), [0, 0, 0], "the stamp's background starts at its corner, y down");
    assert_eq!(at((20.0 + w) as usize + 3, 32), [255, 255, 255], "and ends at its measured width");
}

// Shapes on a blank page, y down: a red rectangle filled, then a black bar under a yellow highlight. The highlight
// multiplies: over black it stays black, over white it is yellow. The written file names its graphics state.
#[test]
fn shapes_are_drawn_and_a_highlight_multiplies() {
    let red = [10.0f32, 10.0, 60.0, 40.0];
    let bar = [100.0f32, 20.0, 180.0, 30.0];
    let mark = [90.0f32, 15.0, 190.0, 50.0];
    let shapes = [
        GtPdfShape { kind: 0, stroke: 0, fill: 0xFF0000FF, width: 1.0, points: red.as_ptr(), point_count: 2 },
        GtPdfShape { kind: 0, stroke: 0, fill: 0x000000FF, width: 1.0, points: bar.as_ptr(), point_count: 2 },
        GtPdfShape { kind: 0, stroke: 0, fill: 0xFFFF0080, width: 1.0, points: mark.as_ptr(), point_count: 2 },
    ];
    let p = GtPdfPage { source: 0, index: 0, turns: 0, width: 200.0, height: 100.0, stamps: std::ptr::null(), stamp_count: 0, shapes: shapes.as_ptr(), shape_count: shapes.len() };
    let mut px = vec![0u8; 200 * 100 * 4];
    assert!(unsafe { gt_pdf_render(&p, 200, 100, false, px.as_mut_ptr()) });
    let at = |x: usize, y: usize| { let i = (y * 200 + x) * 4; [px[i], px[i + 1], px[i + 2]] };
    assert_eq!(at(30, 25), [255, 0, 0], "the rectangle is filled, where it was put");
    assert_eq!(at(5, 60), [255, 255, 255], "the paper around stays white");
    let under = at(140, 25);
    assert!(under[0] < 40 && under[2] < 40, "black under the highlight stays black: {under:?}");
    let over = at(140, 45);
    assert!(over[0] > 230 && over[1] > 230 && over[2] < 180, "white under the highlight turns yellow: {over:?}");

    let mut out: *mut u8 = std::ptr::null_mut();
    let n = unsafe { gt_pdf_write(&p, 1, 0, &mut out) };
    let file = unsafe { std::slice::from_raw_parts(out, n).to_vec() };
    unsafe { gt_pdf_free(out, n) };
    assert!(contains(&file, b"/GtAlpha128") && contains(&file, b"/Multiply"), "the highlight's state is in the file");
}

#[test]
fn a_turned_page_renders_turned() {
    let id = open(two_pages());
    let mut px = vec![0u8; 100 * 200 * 4];
    assert!(unsafe { gt_pdf_render(&page(id, 0, 1), 100, 200, false, px.as_mut_ptr()) });
    // (the text near the page's left edge, at mid-height, goes to the top after a quarter turn clockwise)
    let dark_top = (0..100).flat_map(|x| (0..60).map(move |y| (x, y))).any(|(x, y)| px[(y * 100 + x) * 4] < 128);
    assert!(dark_top, "the words are at the top");
    gt_pdf_close(id);
}

#[test]
fn what_is_not_a_pdf_is_refused() {
    let junk = b"not a pdf at all";
    let mut id = 0;
    let r = unsafe { gt_pdf_open(junk.as_ptr(), junk.len(), std::ptr::null(), 0, &mut id) };
    assert_eq!(r, FORMAT);
}
