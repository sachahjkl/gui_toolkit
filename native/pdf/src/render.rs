//! A page's picture: exactly `width` by `height` RGBA pixels on white, its turns in the transform (a quarter turn of an
//! axis-aligned page stays axis-aligned: nothing is resampled).

use hayro::hayro_interpret::{InterpreterSettings, RenderContent};
use hayro::hayro_syntax::page::Page;
use hayro::hayro_syntax::Pdf;
use hayro::vello_cpu::color::palette::css::WHITE;
use hayro::vello_cpu::kurbo::Affine;
use hayro::vello_cpu::{Pixmap, RasterizerSettings, RenderContext, Resources, TargetInit};
use hayro::{render_into, RenderCache, RenderSettings};

use crate::write::{write, PageSpec};

/// The page's size in points as its source shows it, before the turns.
pub fn page_size(page: &Page<'_>) -> (f32, f32) {
    page.render_dimensions()
}

/// Renders `spec` into `out` (width * height * 4 bytes). A page with stamps, or a blank one, is written alone first
/// and that file rendered: the picture is what the save writes.
pub fn render(spec: &PageSpec<'_>, width: u32, height: u32, layer: bool, out: &mut [u8]) -> bool {
    if width == 0 || height == 0 || width > u16::MAX as u32 || height > u16::MAX as u32 {
        return false;
    }
    if out.len() != (width * height * 4) as usize {
        return false;
    }
    if spec.stamps.is_empty() {
        if let Some((_, pdf)) = spec.source {
            let Some(page) = pdf.pages().get(spec.index) else { return false };
            return render_page(page, spec.turns, width, height, layer, out);
        }
    }
    let alone = PageSpec { source: spec.source, index: spec.index, turns: spec.turns, size: spec.size, stamps: spec.stamps.clone() };
    let bytes = write(std::slice::from_ref(&alone), None);
    let Ok(pdf) = Pdf::new(bytes) else { return false };
    let Some(page) = pdf.pages().first() else { return false };
    // (the turns are in the written page's /Rotate)
    render_page(page, 0, width, height, layer, out)
}

fn render_page(page: &Page<'_>, turns: u8, width: u32, height: u32, layer: bool, out: &mut [u8]) -> bool {
    let (pw, ph) = page.render_dimensions();
    let (pw, ph) = (pw as f64, ph as f64);
    let (turn, dw, dh) = match turns % 4 {
        1 => (Affine::new([0.0, 1.0, -1.0, 0.0, ph, 0.0]), ph, pw),
        2 => (Affine::new([-1.0, 0.0, 0.0, -1.0, pw, ph]), pw, ph),
        3 => (Affine::new([0.0, -1.0, 1.0, 0.0, 0.0, pw]), ph, pw),
        _ => (Affine::IDENTITY, pw, ph),
    };
    if dw <= 0.0 || dh <= 0.0 {
        return false;
    }
    let transform = Affine::scale_non_uniform(width as f64 / dw, height as f64 / dh) * turn * Affine::new(page.initial_transform(true).as_coeffs());
    let content = if layer { RenderContent::PAGE | RenderContent::ANNOTATIONS } else { RenderContent::PAGE };
    let interpreter = InterpreterSettings { render_content: content, ..InterpreterSettings::default() };
    // (a cache a render: it holds Rc, so it cannot be shared between the threads a source is rendered from)
    let cache = RenderCache::new();
    let mut ctx = RenderContext::new(width as u16, height as u16);
    render_into(page, &cache, &interpreter, &RenderSettings::default(), &mut ctx, transform);
    ctx.flush();
    let mut pixmap = Pixmap::new(width as u16, height as u16);
    ctx.render_with(
        &mut pixmap,
        &mut Resources::default(),
        RasterizerSettings { target_init: TargetInit::Clear(WHITE), ..Default::default() },
    );
    // (on an opaque white page, premultiplied and straight alpha are the same bytes)
    out.copy_from_slice(pixmap.data_as_u8_slice());
    true
}
