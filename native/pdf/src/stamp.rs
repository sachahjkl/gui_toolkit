//! A stamp: text on a page, with an optional background, in a standard font or a font the program gave, with the
//! effects of a signature: a tilt, a heavier pen, a flourish under it, a caption line (src/md/features/pdf.md, Stamps).

use std::sync::Arc;

use crate::afm::{self, Font};
use crate::face::Face;
use hayro::vello_cpu::kurbo::Affine;
use pdf_writer::types::{LineCapStyle, TextRenderingMode};
use pdf_writer::{Content, Name, Str};

/// The space between lines, in sizes (at least: a script font's tall loops ask for more).
const LEADING: f32 = 1.2;
/// The margin around the text, inside the background, in sizes.
const PADDING: f32 = 0.3;
/// The caption: its size, a share of the stamp's, and the least.
const CAPTION_SIZE: f32 = 0.36;
const CAPTION_MIN: f32 = 7.0;
/// The room of the flourish under the text, in sizes.
const FLOURISH_ROOM: f32 = 0.35;

#[derive(Clone)]
pub struct Stamp {
    /// Its top-left corner, in points, in the page as its source shows it (y down).
    pub x: f32,
    pub y: f32,
    /// Quarter turns clockwise of the text, about its top-left corner.
    pub turns: u8,
    pub font: Font,
    /// A font the program gave (its id and its file), in place of `font`.
    pub face: Option<(u32, Arc<Face>)>,
    pub size: f32,
    pub color: [u8; 3],
    pub background: Option<[u8; 3]>,
    pub text: String,
    /// Degrees the text rises to the right, about its box's centre.
    pub tilt: f32,
    /// The pen's weight: the glyphs' outline stroked too, this wide, in thousandths of the size (0: none).
    pub weight: f32,
    /// A flourish under the text.
    pub underline: bool,
    /// A line under it in Helvetica, smaller ("Paris, 19 November 2026"); "": none.
    pub caption: String,
}

// Where everything goes, in the stamp's own space before its tilt (y down, its content box at 0,0).
struct Layout {
    w0: f32,
    h0: f32,
    /// The box after the tilt (what the stamp takes on the page).
    w: f32,
    h: f32,
    text_w: f32,
    baselines: Vec<f32>,
    flourish_y: f32,
    caption_size: f32,
    caption_base: f32,
}

impl Stamp {
    fn lines(&self) -> impl Iterator<Item = &str> {
        self.text.split('\n')
    }

    fn line_width(&self, line: &str) -> f32 {
        match &self.face {
            Some((_, f)) => f.width(line),
            None => line.chars().map(|c| self.font.width(afm::encode(c))).sum::<f32>(),
        }
    }

    // Ascender and descender of the text's font, in thousandths of the size.
    fn extent(&self) -> (f32, f32) {
        match &self.face {
            Some((_, f)) => (f.ascent, f.descent),
            None => self.font.ascent_descent(),
        }
    }

    fn layout(&self) -> Layout {
        let size = self.size.max(1.0);
        let pad = PADDING * size;
        let (ascent, descent) = self.extent();
        // (a line as tall as its font's ascender and descender, LEADING at least)
        let line_k = (LEADING * 1000.0).max(ascent - descent);
        let line_h = line_k * size / 1000.0;
        let above = (line_k - (ascent - descent)) / 2.0 + ascent;
        let mut text_w: f32 = 0.0;
        let mut baselines = Vec::new();
        for (i, line) in self.lines().enumerate() {
            text_w = text_w.max(self.line_width(line) * size / 1000.0);
            baselines.push(pad + i as f32 * line_h + above * size / 1000.0);
        }
        let mut y = pad + baselines.len() as f32 * line_h;
        let flourish_y = baselines.last().copied().unwrap_or(pad) + (-descent).max(120.0) * size / 1000.0 * 0.6;
        if self.underline {
            y += FLOURISH_ROOM * size;
        }
        let caption_size = (size * CAPTION_SIZE).max(CAPTION_MIN);
        let mut caption_base = 0.0;
        let mut w0 = text_w;
        if !self.caption.is_empty() {
            let (ca, cd) = Font::helvetica().ascent_descent();
            caption_base = y + ca * caption_size / 1000.0;
            y += (ca - cd) * caption_size / 1000.0;
            let cw: f32 = self.caption.chars().map(|c| Font::helvetica().width(afm::encode(c))).sum::<f32>() * caption_size / 1000.0;
            w0 = w0.max(cw);
        }
        let (w0, h0) = (w0 + 2.0 * pad, y + pad);
        let t = self.tilt.to_radians().abs();
        let (w, h) = (w0 * t.cos() + h0 * t.sin(), w0 * t.sin() + h0 * t.cos());
        Layout { w0, h0, w, h, text_w, baselines, flourish_y, caption_size, caption_base }
    }

    /// Its box before its turns: width and height in points (its tilt inside it).
    pub fn measure(&self) -> (f32, f32) {
        let l = self.layout();
        (l.w, l.h)
    }

    /// Draws the stamp in `content`: `to_user` maps the page as its source shows it (points, y down) to the page's user
    /// space; `font` is the name of its text's font in the page's resources, `caption_font` Helvetica's; `encode`
    /// gives a line's bytes in that font (WinAnsi for a standard font, its subset's glyphs for a font the program gave).
    pub fn draw(&self, content: &mut Content, to_user: Affine, font: Name<'_>, caption_font: Name<'_>, encode: &dyn Fn(&str) -> Vec<u8>) {
        let size = self.size.max(1.0);
        let l = self.layout();
        let turn = match self.turns % 4 {
            1 => Affine::new([0.0, 1.0, -1.0, 0.0, 0.0, 0.0]),
            2 => Affine::new([-1.0, 0.0, 0.0, -1.0, 0.0, 0.0]),
            3 => Affine::new([0.0, -1.0, 1.0, 0.0, 0.0, 0.0]),
            _ => Affine::IDENTITY,
        };
        // (the tilt about the box's centre: y is down, so a rise to the right turns the other way round)
        let tilt = Affine::translate((l.w as f64 / 2.0, l.h as f64 / 2.0))
            * Affine::rotate(-(self.tilt as f64).to_radians())
            * Affine::translate((-l.w0 as f64 / 2.0, -l.h0 as f64 / 2.0));
        let m = to_user * Affine::translate((self.x as f64, self.y as f64)) * turn * tilt;
        let c = m.as_coeffs();
        content.save_state();
        content.transform([c[0] as f32, c[1] as f32, c[2] as f32, c[3] as f32, c[4] as f32, c[5] as f32]);
        if let Some(bg) = self.background {
            content.set_fill_rgb(channel(bg[0]), channel(bg[1]), channel(bg[2]));
            content.rect(0.0, 0.0, l.w0, l.h0);
            content.fill_nonzero();
        }
        let (r, g, b) = (channel(self.color[0]), channel(self.color[1]), channel(self.color[2]));
        content.set_fill_rgb(r, g, b);
        content.set_stroke_rgb(r, g, b);
        let pad = PADDING * size;
        content.begin_text();
        content.set_font(font, size);
        if self.weight > 0.0 {
            // (the outline stroked over the fill: a heavier pen, the letters' joins rounded)
            content.set_text_rendering_mode(TextRenderingMode::FillStroke);
            content.set_line_width(self.weight * size / 1000.0);
            content.set_line_join(pdf_writer::types::LineJoinStyle::RoundJoin);
        }
        for (line, base) in self.lines().zip(&l.baselines) {
            // (y down in the stamp's space: the text matrix flips it back so the glyphs stand upright)
            content.set_text_matrix([1.0, 0.0, 0.0, -1.0, pad, *base]);
            content.show(Str(&encode(line)));
        }
        content.end_text();
        if self.underline && l.text_w > 0.0 {
            // (a pen's flourish: from under the first letter, dipping, then rising past the last)
            let (x0, x1, y) = (pad, pad + l.text_w, l.flourish_y);
            let w = l.text_w;
            content.set_line_width((size * 0.035 + self.weight * size / 1000.0).max(0.6));
            content.set_line_cap(LineCapStyle::RoundCap);
            content.move_to(x0 + w * 0.02, y + size * 0.06);
            content.cubic_to(x0 + w * 0.3, y + size * 0.22, x0 + w * 0.65, y - size * 0.02, x1 + size * 0.15, y - size * 0.12);
            content.stroke();
        }
        if !self.caption.is_empty() {
            content.begin_text();
            content.set_text_rendering_mode(TextRenderingMode::Fill);
            content.set_font(caption_font, l.caption_size);
            content.set_text_matrix([1.0, 0.0, 0.0, -1.0, pad, l.caption_base]);
            let bytes: Vec<u8> = self.caption.chars().map(afm::encode).collect();
            content.show(Str(&bytes));
            content.end_text();
        }
        content.restore_state();
    }
}

fn channel(v: u8) -> f32 {
    v as f32 / 255.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::afm::Family;

    fn stamp(text: &str, family: Family) -> Stamp {
        Stamp {
            x: 0.0,
            y: 0.0,
            turns: 0,
            font: Font { family, bold: false, italic: false },
            face: None,
            size: 10.0,
            color: [0, 0, 0],
            background: None,
            text: text.into(),
            tilt: 0.0,
            weight: 0.0,
            underline: false,
            caption: String::new(),
        }
    }

    #[test]
    fn courier_is_six_hundred_thousandths_a_character() {
        let (w, h) = stamp("abcd\nab", Family::Mono).measure();
        assert!((w - (4.0 * 6.0 + 6.0)).abs() < 0.01, "{w}");
        assert!((h - (2.0 * 12.0 + 6.0)).abs() < 0.01, "{h}");
    }

    #[test]
    fn helvetica_has_its_own_widths_and_winansi_its_euro() {
        let (w, _) = stamp("il", Family::Sans).measure();
        assert!((w - (2.22 + 2.22 + 6.0)).abs() < 0.01, "{w}");
        assert_eq!(afm::encode('€'), 0x80);
        assert_eq!(afm::encode('é'), 0xE9);
        assert_eq!(afm::encode('漢'), b'?');
    }

    #[test]
    fn a_tilt_a_flourish_and_a_caption_grow_the_box() {
        let plain = stamp("Camille", Family::Serif).measure();
        let mut s = stamp("Camille", Family::Serif);
        s.underline = true;
        s.caption = "Paris, 19 November 2026".into();
        let signed = s.measure();
        assert!(signed.1 > plain.1 + 3.0, "taller with its flourish and caption: {plain:?} {signed:?}");
        assert!(signed.0 > plain.0, "as wide as its caption: {plain:?} {signed:?}");
        s.tilt = 8.0;
        let tilted = s.measure();
        assert!(tilted.0 > signed.0 && tilted.1 > signed.1, "a tilted box holds the tilted text: {signed:?} {tilted:?}");
    }
}
