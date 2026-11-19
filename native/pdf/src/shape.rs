//! A shape drawn on a page: a rectangle, an ellipse, a line, an arrow or a free line (src/md/features/pdf.md, Shapes).

use hayro::vello_cpu::kurbo::Affine;
use pdf_writer::{Content, Name};

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Kind {
    Rect,
    Ellipse,
    Line,
    Arrow,
    Ink,
    /// Closed outlines filled with the non-zero rule: a pen's ink as gt:ink gives it, its width changing along the
    /// stroke. A point whose x is NaN starts the next outline (a signature's strokes are one shape).
    Outline,
}

impl Kind {
    pub fn from_code(code: u32) -> Option<Self> {
        Some(match code {
            0 => Kind::Rect,
            1 => Kind::Ellipse,
            2 => Kind::Line,
            3 => Kind::Arrow,
            4 => Kind::Ink,
            5 => Kind::Outline,
            _ => return None,
        })
    }
}

#[derive(Clone, Debug)]
pub struct Shape {
    pub kind: Kind,
    /// Points in the page as its source shows it (y down): two corners (rectangle, ellipse), two ends (line, arrow:
    /// from, to), or the free line's points.
    pub points: Vec<(f32, f32)>,
    /// RGBA; alpha 0: none. A colour less than opaque is laid over the page by multiplication, as a highlighter's ink.
    pub stroke: [u8; 4],
    pub fill: [u8; 4],
    /// The stroke's width, in points.
    pub width: f32,
}

/// The arrow's head: its length in widths of the line, and its half opening.
const HEAD_LENGTH: f32 = 4.0;
const HEAD_MIN: f32 = 8.0;
/// The ellipse's control distance, as a share of its radius (four Bézier arcs).
const KAPPA: f32 = 0.552_284_8;

fn channel(v: u8) -> f32 {
    v as f32 / 255.0
}

impl Shape {
    /// The alphas it needs a graphics state for (its fill's, its stroke's), those under 255.
    pub fn alphas(&self) -> impl Iterator<Item = u8> + '_ {
        [self.fill[3], self.stroke[3]].into_iter().filter(|a| *a > 0 && *a < 255)
    }

    /// Draws the shape in `content`; `to_user` maps the page as its source shows it (points, y down) to the page's user
    /// space; `state` names the graphics state of an alpha (an ExtGState with /ca, /CA and /BM /Multiply).
    pub fn draw(&self, content: &mut Content, to_user: Affine, state: &dyn Fn(u8) -> String) {
        if self.points.is_empty() || (self.stroke[3] == 0 && self.fill[3] == 0) {
            return;
        }
        let c = to_user.as_coeffs();
        content.save_state();
        content.transform([c[0] as f32, c[1] as f32, c[2] as f32, c[3] as f32, c[4] as f32, c[5] as f32]);
        content.set_line_width(self.width.max(0.1));
        content.set_line_cap(pdf_writer::types::LineCapStyle::RoundCap);
        content.set_line_join(pdf_writer::types::LineJoinStyle::RoundJoin);
        let filled = self.fill[3] > 0 && matches!(self.kind, Kind::Rect | Kind::Ellipse | Kind::Outline);
        if filled {
            self.paint(content, state, true);
        }
        if self.stroke[3] > 0 && self.kind != Kind::Outline {
            self.paint(content, state, false);
        }
        content.restore_state();
    }

    fn paint(&self, content: &mut Content, state: &dyn Fn(u8) -> String, fill: bool) {
        let colour = if fill { self.fill } else { self.stroke };
        content.save_state();
        if colour[3] < 255 {
            let name = state(colour[3]);
            content.set_parameters(Name(name.as_bytes()));
        }
        if fill {
            content.set_fill_rgb(channel(colour[0]), channel(colour[1]), channel(colour[2]));
        } else {
            content.set_stroke_rgb(channel(colour[0]), channel(colour[1]), channel(colour[2]));
            // (the arrow's head is filled with the stroke's colour)
            content.set_fill_rgb(channel(colour[0]), channel(colour[1]), channel(colour[2]));
        }
        let p = &self.points;
        let (a, b) = (p[0], *p.get(1).unwrap_or(&p[0]));
        match self.kind {
            Kind::Outline => {
                for contour in p.split(|q| q.0.is_nan()).filter(|c| c.len() >= 3) {
                    content.move_to(contour[0].0, contour[0].1);
                    for q in &contour[1..] {
                        content.line_to(q.0, q.1);
                    }
                    content.close_path();
                }
            }
            Kind::Rect => {
                let (x0, y0, x1, y1) = (a.0.min(b.0), a.1.min(b.1), a.0.max(b.0), a.1.max(b.1));
                content.rect(x0, y0, x1 - x0, y1 - y0);
            }
            Kind::Ellipse => {
                let (cx, cy) = ((a.0 + b.0) / 2.0, (a.1 + b.1) / 2.0);
                let (rx, ry) = ((b.0 - a.0).abs() / 2.0, (b.1 - a.1).abs() / 2.0);
                let (kx, ky) = (rx * KAPPA, ry * KAPPA);
                content.move_to(cx + rx, cy);
                content.cubic_to(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry);
                content.cubic_to(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy);
                content.cubic_to(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry);
                content.cubic_to(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy);
                content.close_path();
            }
            Kind::Line | Kind::Arrow | Kind::Ink => {
                if fill {
                    content.restore_state();
                    return;
                }
                content.move_to(a.0, a.1);
                if self.kind == Kind::Ink {
                    for q in &p[1..] {
                        content.line_to(q.0, q.1);
                    }
                } else if self.kind == Kind::Arrow {
                    // (the line stops inside the head: its round end would show past the tip)
                    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
                    let len = (dx * dx + dy * dy).sqrt().max(1e-3);
                    let back = ((self.width * HEAD_LENGTH).max(HEAD_MIN).min(len)) * 0.6;
                    content.line_to(b.0 - dx / len * back, b.1 - dy / len * back);
                } else {
                    content.line_to(b.0, b.1);
                }
            }
        }
        if fill {
            content.fill_nonzero();
        } else {
            content.stroke();
        }
        if self.kind == Kind::Arrow && !fill {
            // (the head: a triangle at `b`, along the line, filled)
            let (dx, dy) = (b.0 - a.0, b.1 - a.1);
            let len = (dx * dx + dy * dy).sqrt();
            if len > 0.0 {
                let (ux, uy) = (dx / len, dy / len);
                let head = (self.width * HEAD_LENGTH).max(HEAD_MIN).min(len);
                let half = head * 0.5;
                let (bx, by) = (b.0 - ux * head, b.1 - uy * head);
                content.move_to(b.0, b.1);
                content.line_to(bx - uy * half, by + ux * half);
                content.line_to(bx + uy * half, by - ux * half);
                content.close_path();
                content.fill_nonzero();
            }
        }
        content.restore_state();
    }
}
