//! A stamp: text on a page, with an optional background (src/md/features/pdf.md, Stamps).

use crate::afm::{self, Font};
use hayro::vello_cpu::kurbo::Affine;
use pdf_writer::{Content, Name, Str};

/// The space between lines, in sizes.
const LEADING: f32 = 1.2;
/// The margin around the text, inside the background, in sizes.
const PADDING: f32 = 0.3;

#[derive(Clone, Debug)]
pub struct Stamp {
    /// Its top-left corner, in points, in the page as its source shows it (y down).
    pub x: f32,
    pub y: f32,
    /// Quarter turns clockwise of the text, about its top-left corner.
    pub turns: u8,
    pub font: Font,
    pub size: f32,
    pub color: [u8; 3],
    pub background: Option<[u8; 3]>,
    pub text: String,
}

impl Stamp {
    fn lines(&self) -> impl Iterator<Item = &str> {
        self.text.split('\n')
    }

    /// Its box before its turns: width and height in points.
    pub fn measure(&self) -> (f32, f32) {
        let size = self.size.max(1.0);
        let mut width: f32 = 0.0;
        let mut count = 0;
        for line in self.lines() {
            count += 1;
            let w: f32 = line.chars().map(|c| self.font.width(afm::encode(c))).sum::<f32>() * size / 1000.0;
            width = width.max(w);
        }
        (width + 2.0 * PADDING * size, count as f32 * LEADING * size + 2.0 * PADDING * size)
    }

    /// Draws the stamp in `content`: `to_user` maps the page as its source shows it (points, y down) to the page's user
    /// space; `font` is the name of its font in the page's resources.
    pub fn draw(&self, content: &mut Content, to_user: Affine, font: Name<'_>) {
        let size = self.size.max(1.0);
        let (w, h) = self.measure();
        let turn = match self.turns % 4 {
            1 => Affine::new([0.0, 1.0, -1.0, 0.0, 0.0, 0.0]),
            2 => Affine::new([-1.0, 0.0, 0.0, -1.0, 0.0, 0.0]),
            3 => Affine::new([0.0, -1.0, 1.0, 0.0, 0.0, 0.0]),
            _ => Affine::IDENTITY,
        };
        // (the stamp's own space: its top-left corner at the origin, y down, as the person placed it)
        let m = to_user * Affine::translate((self.x as f64, self.y as f64)) * turn;
        let c = m.as_coeffs();
        content.save_state();
        content.transform([c[0] as f32, c[1] as f32, c[2] as f32, c[3] as f32, c[4] as f32, c[5] as f32]);
        if let Some(bg) = self.background {
            content.set_fill_rgb(channel(bg[0]), channel(bg[1]), channel(bg[2]));
            content.rect(0.0, 0.0, w, h);
            content.fill_nonzero();
        }
        let (ascent, descent) = self.font.ascent_descent();
        // (each line's glyphs centred in its leading)
        let above = (LEADING * 1000.0 - (ascent - descent)) / 2.0 + ascent;
        content.set_fill_rgb(channel(self.color[0]), channel(self.color[1]), channel(self.color[2]));
        content.begin_text();
        content.set_font(font, size);
        for (i, line) in self.lines().enumerate() {
            let baseline = PADDING * size + i as f32 * LEADING * size + above * size / 1000.0;
            // (y down in the stamp's space: the text matrix flips it back so the glyphs stand upright)
            content.set_text_matrix([1.0, 0.0, 0.0, -1.0, PADDING * size, baseline]);
            let bytes: Vec<u8> = line.chars().map(afm::encode).collect();
            content.show(Str(&bytes));
        }
        content.end_text();
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
            size: 10.0,
            color: [0, 0, 0],
            background: None,
            text: text.into(),
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
}
