//! A font a program gives (src/md/features/pdf.md, Fonts): a TrueType or OpenType file, read once, its metrics kept.
//! A stamp in it is written with the font embedded, a subset of the glyphs the file uses (subsetter), as a CID font
//! with its ToUnicode map: any character the font has, its text copyable.

use skrifa::instance::{LocationRef, Size};
use skrifa::{FontRef, GlyphId, MetadataProvider};

pub struct Face {
    pub data: Vec<u8>,
    pub upem: f32,
    /// Ascender and descender, in thousandths of the size (the descender negative).
    pub ascent: f32,
    pub descent: f32,
    /// The glyphs' box, in thousandths of the size.
    pub bbox: [f32; 4],
    pub italic_angle: f32,
    /// Its PostScript name, safe in a PDF name.
    pub name: String,
}

impl Face {
    pub fn new(data: Vec<u8>) -> Option<Face> {
        let font = FontRef::new(&data).ok()?;
        let m = font.metrics(Size::unscaled(), LocationRef::default());
        let upem = m.units_per_em as f32;
        if upem <= 0.0 {
            return None;
        }
        let k = 1000.0 / upem;
        let bbox = m.bounds.map(|b| [b.x_min * k, b.y_min * k, b.x_max * k, b.y_max * k]).unwrap_or([0.0, m.descent * k, 1000.0, m.ascent * k]);
        let raw = font
            .localized_strings(skrifa::string::StringId::POSTSCRIPT_NAME)
            .english_or_first()
            .map(|s| s.to_string())
            .unwrap_or_else(|| "Font".into());
        let name: String = raw.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').collect();
        let (ascent, descent, italic_angle) = (m.ascent * k, m.descent * k, m.italic_angle);
        Some(Face { data, upem, ascent, descent, bbox, italic_angle, name: if name.is_empty() { "Font".into() } else { name } })
    }

    fn font(&self) -> FontRef<'_> {
        // (checked at new: the bytes do not change)
        FontRef::new(&self.data).expect("a face's bytes are a font")
    }

    /// The glyph of a character; 0 (.notdef) when the font has none.
    pub fn glyph(&self, c: char) -> u16 {
        self.font().charmap().map(c).map(|g| g.to_u32() as u16).unwrap_or(0)
    }

    /// A glyph's advance, in thousandths of the size.
    pub fn advance(&self, gid: u16) -> f32 {
        let font = self.font();
        let metrics = font.glyph_metrics(Size::unscaled(), LocationRef::default());
        metrics.advance_width(GlyphId::new(gid as u32)).unwrap_or(0.0) * 1000.0 / self.upem
    }

    /// A line's width, in thousandths of the size.
    pub fn width(&self, line: &str) -> f32 {
        let font = self.font();
        let charmap = font.charmap();
        let metrics = font.glyph_metrics(Size::unscaled(), LocationRef::default());
        line.chars()
            .map(|c| {
                let g = charmap.map(c).unwrap_or(GlyphId::NOTDEF);
                metrics.advance_width(g).unwrap_or(0.0)
            })
            .sum::<f32>()
            * 1000.0
            / self.upem
    }
}
