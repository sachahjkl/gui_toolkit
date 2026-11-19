//! The widths of the standard fonts a stamp uses, in WinAnsi. `metrics.rs` and `win_ansi.rs` are hayro-font 0.5.0's
//! generated tables, copied unchanged (LICENSE-MIT): hayro draws a standard font with these widths, so a stamp measured
//! here is the stamp it draws.

#[allow(dead_code)]
mod metrics;
#[allow(dead_code)]
mod win_ansi;

/// A stamp's font family: Helvetica, Times or Courier.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Family {
    Sans,
    Serif,
    Mono,
}

/// A standard font: a family and its style.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct Font {
    pub family: Family,
    pub bold: bool,
    pub italic: bool,
}

impl Font {
    /// Helvetica: a caption's font.
    pub fn helvetica() -> Self {
        Font { family: Family::Sans, bold: false, italic: false }
    }

    /// From the C API's number: the family (0 sans, 1 serif, 2 mono), plus 4 when bold, plus 8 when italic.
    pub fn from_code(code: u32) -> Self {
        let family = match code & 3 {
            1 => Family::Serif,
            2 => Family::Mono,
            _ => Family::Sans,
        };
        Font { family, bold: code & 4 != 0, italic: code & 8 != 0 }
    }

    /// Its PostScript name, the `/BaseFont` of its dictionary.
    pub fn base_name(self) -> &'static str {
        match (self.family, self.bold, self.italic) {
            (Family::Sans, false, false) => "Helvetica",
            (Family::Sans, true, false) => "Helvetica-Bold",
            (Family::Sans, false, true) => "Helvetica-Oblique",
            (Family::Sans, true, true) => "Helvetica-BoldOblique",
            (Family::Serif, false, false) => "Times-Roman",
            (Family::Serif, true, false) => "Times-Bold",
            (Family::Serif, false, true) => "Times-Italic",
            (Family::Serif, true, true) => "Times-BoldItalic",
            (Family::Mono, false, false) => "Courier",
            (Family::Mono, true, false) => "Courier-Bold",
            (Family::Mono, false, true) => "Courier-Oblique",
            (Family::Mono, true, true) => "Courier-BoldOblique",
        }
    }

    /// Ascender and descender, in thousandths of the size (the AFM files' values).
    pub fn ascent_descent(self) -> (f32, f32) {
        match self.family {
            Family::Sans => (718.0, -207.0),
            Family::Serif => (683.0, -217.0),
            Family::Mono => (629.0, -157.0),
        }
    }

    fn table(self) -> &'static phf::Map<&'static str, f32> {
        match (self.family, self.bold, self.italic) {
            (Family::Sans, false, false) => &metrics::HELVETICA,
            (Family::Sans, true, false) => &metrics::HELVETICA_BOLD,
            (Family::Sans, false, true) => &metrics::HELVETICA_OBLIQUE,
            (Family::Sans, true, true) => &metrics::HELVETICA_BOLD_OBLIQUE,
            (Family::Serif, false, false) => &metrics::TIMES_ROMAN,
            (Family::Serif, true, false) => &metrics::TIMES_BOLD,
            (Family::Serif, false, true) => &metrics::TIMES_ITALIC,
            (Family::Serif, true, true) => &metrics::TIMES_BOLD_ITALIC,
            (Family::Mono, false, false) => &metrics::COURIER,
            (Family::Mono, true, false) => &metrics::COURIER_BOLD,
            (Family::Mono, false, true) => &metrics::COURIER_OBLIQUE,
            (Family::Mono, true, true) => &metrics::COURIER_BOLD_OBLIQUE,
        }
    }

    /// The width of a WinAnsi code, in thousandths of the size.
    pub fn width(self, code: u8) -> f32 {
        win_ansi::get(code).and_then(|name| self.table().get(name).copied()).unwrap_or(0.0)
    }
}

/// The WinAnsi code of a character; `?` for one outside it. WinAnsi is Latin-1 but for 0x80 to 0x9F, where Windows
/// 1252 puts the typographic marks (and the euro).
pub fn encode(c: char) -> u8 {
    let u = c as u32;
    if (0x20..=0x7E).contains(&u) || (0xA0..=0xFF).contains(&u) {
        return u as u8;
    }
    match u {
        0x20AC => 0x80,
        0x201A => 0x82,
        0x0192 => 0x83,
        0x201E => 0x84,
        0x2026 => 0x85,
        0x2020 => 0x86,
        0x2021 => 0x87,
        0x02C6 => 0x88,
        0x2030 => 0x89,
        0x0160 => 0x8A,
        0x2039 => 0x8B,
        0x0152 => 0x8C,
        0x017D => 0x8E,
        0x2018 => 0x91,
        0x2019 => 0x92,
        0x201C => 0x93,
        0x201D => 0x94,
        0x2022 => 0x95,
        0x2013 => 0x96,
        0x2014 => 0x97,
        0x02DC => 0x98,
        0x2122 => 0x99,
        0x0161 => 0x9A,
        0x203A => 0x9B,
        0x0153 => 0x9C,
        0x017E => 0x9E,
        0x0178 => 0x9F,
        0x09 => b' ',
        _ => b'?',
    }
}
