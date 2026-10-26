//! Prints HarfRust's shaping of a text with a font file, with and without some features (a debugging aid, like
//! HarfBuzz's hb-shape):  cargo run --release --example shape_dump -- <font> <text> [rtl] [-feat,...]
use harfrust::{Buffer, Direction, Feature, ShapeOptions, ShaperFont, Tag};
use read_fonts::model::Font;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let data = std::fs::read(&args[1]).expect("font");
    let font = Font::new(data, 0).expect("face");
    let text = &args[2];
    let rtl = args.get(3).map_or(false, |a| a == "rtl");
    let feats: Vec<Feature> = args.iter().skip(4).flat_map(|a| a.split(',')).filter(|s| !s.is_empty()).map(|s| {
        let (on, name) = if let Some(n) = s.strip_prefix('-') { (0, n) } else { (1, s.trim_start_matches('+')) };
        let mut b = [b' '; 4];
        for (i, c) in name.bytes().take(4).enumerate() { b[i] = c; }
        Feature::new(Tag::new(&b), on, ..)
    }).collect();
    let mut buf = Buffer::new();
    buf.push_str(text);
    buf.set_direction(if rtl { Direction::RightToLeft } else { Direction::LeftToRight });
    buf.guess_segment_properties();
    println!("script {:?} direction {:?} language {:?}", buf.script(), buf.direction(), buf.language());
    let sf = ShaperFont::new(&font);
    harfrust::shape(&sf, &mut buf, ShapeOptions::new().features(&feats)).expect("shape");
    for (i, p) in buf.glyph_infos().iter().zip(buf.glyph_positions()) {
        println!("gid {:5} cl {:3} adv {:5} xoff {:5} yoff {:5}", i.glyph_id, i.cluster, p.x_advance, p.x_offset, p.y_offset);
    }
}
