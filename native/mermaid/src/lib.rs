//! gt_mermaid: a Mermaid diagram's text to SVG, through mermaid-svg (its parser, its layout, its SVG). The toolkit's mermaid
//! package calls it and draws the SVG with its svg package.
//!
//! Every entry point catches panics: a diagram the library cannot draw is an error the program shows as the diagram's text.
//!
//! A gantt chart whose `dateFormat` is `X` (seconds since 1970) or `x` (milliseconds), which mermaid-svg does not read, is
//! given to it in `YYYY-MM-DD HH:mm:ss` (epoch_gantt). A gantt chart's section names, which mermaid-svg sets on the
//! edge of their band, are moved half its padding in (gantt_labels).

use std::panic::{catch_unwind, AssertUnwindSafe};

pub const GT_MERMAID_ABI: u32 = 1;

/// The SVG is in `out`.
pub const GT_MERMAID_OK: i32 = 1;
/// The text is not a diagram the library knows: why is in `out`.
pub const GT_MERMAID_ERROR: i32 = 0;
/// The library failed: nothing is in `out`.
pub const GT_MERMAID_PANIC: i32 = -2;

#[no_mangle]
pub extern "C" fn gt_mermaid_abi() -> u32 {
    GT_MERMAID_ABI
}

/// Renders `src` (UTF-8, `src_len` bytes) with the theme named `theme` (mermaid's: "default", "dark", "neutral", "forest";
/// empty or unknown: "default") at `font_size` px (0: the theme's). `out` and `out_len` receive a buffer this library
/// owns: give it back with gt_mermaid_free.
///
/// # Safety
/// `src` and `theme` point to that many readable bytes (or are null with a length of 0); `out` and `out_len` are writable.
#[no_mangle]
pub unsafe extern "C" fn gt_mermaid_render(
    src: *const u8,
    src_len: usize,
    theme: *const u8,
    theme_len: usize,
    font_size: f64,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        return GT_MERMAID_PANIC;
    }
    *out = std::ptr::null_mut();
    *out_len = 0;
    let text = bytes(src, src_len);
    let name = bytes(theme, theme_len);
    let result = catch_unwind(AssertUnwindSafe(|| {
        let text = String::from_utf8_lossy(text);
        let name = String::from_utf8_lossy(name);
        let mut t = mermaid_svg::Theme::by_name(&name).unwrap_or_default();
        if font_size > 0.0 {
            t = t.with_font_size(font_size);
        }
        let svg = match epoch_gantt(&text) {
            Some(text) => mermaid_svg::render_with(&text, &t),
            None => mermaid_svg::render_with(&text, &t),
        };
        svg.map(|svg| gantt_labels(&svg))
    }));
    let (code, body) = match result {
        Ok(Ok(svg)) => (GT_MERMAID_OK, svg),
        Ok(Err(e)) => (GT_MERMAID_ERROR, e.to_string()),
        Err(_) => return GT_MERMAID_PANIC,
    };
    let boxed = body.into_bytes().into_boxed_slice();
    *out_len = boxed.len();
    *out = Box::into_raw(boxed) as *mut u8;
    code
}

/// Gives back a buffer of gt_mermaid_render.
///
/// # Safety
/// `p` and `len` are what gt_mermaid_render gave (or null).
#[no_mangle]
pub unsafe extern "C" fn gt_mermaid_free(p: *mut u8, len: usize) {
    if !p.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, len)));
    }
}

/// A gantt chart in `dateFormat X` or `x`, its dates written as `YYYY-MM-DD HH:mm:ss` (UTC). None: not one.
/// A task's dates are its numbers after the `:` (a duration has a unit, an id a letter: they stay as they are).
fn epoch_gantt(text: &str) -> Option<String> {
    let mut lines = text.lines();
    let first = lines.clone().map(str::trim).find(|l| !l.is_empty() && !l.starts_with("%%"))?;
    if first != "gantt" {
        return None;
    }
    let scale = lines.clone().find_map(|l| match l.trim().strip_prefix("dateFormat")?.trim() {
        "X" => Some(1.0),
        "x" => Some(0.001),
        _ => None,
    })?;
    let mut out = String::with_capacity(text.len() + 64);
    for line in lines.by_ref() {
        let t = line.trim();
        let indent = &line[..line.len() - line.trim_start().len()];
        if t.starts_with("dateFormat") {
            out.push_str(indent);
            out.push_str("dateFormat YYYY-MM-DD HH:mm:ss");
        } else if let Some(colon) = task_colon(t) {
            out.push_str(indent);
            out.push_str(&t[..=colon]);
            let parts: Vec<String> = t[colon + 1..]
                .split(',')
                .map(|p| {
                    let v = p.trim();
                    match v.parse::<f64>() {
                        Ok(n) if v.chars().all(|c| c.is_ascii_digit() || c == '.' || c == '-') => format!(" {}", civil(n * scale)),
                        _ => p.to_string(),
                    }
                })
                .collect();
            out.push_str(&parts.join(","));
        } else {
            out.push_str(line);
        }
        out.push('\n');
    }
    Some(out)
}

/// A gantt chart's section names away from the edge of their band: mermaid-svg sets them at the band's x, the whole
/// padding after them (its gutter is the widest name and that padding); half of it goes before. Another drawing: as it is.
fn gantt_labels(svg: &str) -> String {
    if !svg.contains(r#"aria-roledescription="gantt""#) {
        return svg.to_string();
    }
    // the bands: the first rect drawn is a section's, its x the gutter's edge; the padding is that x (the chart's own)
    let Some(at) = svg.find("<rect x=\"") else { return svg.to_string() };
    let rest = &svg[at + 9..];
    let Some(end) = rest.find('"') else { return svg.to_string() };
    let edge = &rest[..end];
    let Ok(pad) = edge.parse::<f64>() else { return svg.to_string() };
    let from = format!("<text x=\"{edge}\" ");
    let to = format!("<text x=\"{}\" ", pad + pad / 2.0);
    svg.replace(&from, &to)
}

/// Where a task line's `:` is (a directive's is not a task's: `title`, `axisFormat`...).
fn task_colon(t: &str) -> Option<usize> {
    const DIRECTIVES: [&str; 14] = ["title", "dateFormat", "axisFormat", "tickInterval", "excludes", "includes", "todayMarker",
        "weekday", "weekend", "section", "displayMode", "inclusiveEndDates", "topAxis", "click"];
    if t.is_empty() || t.starts_with("%%") || DIRECTIVES.iter().any(|d| t.starts_with(d)) {
        return None;
    }
    t.find(':')
}

/// Seconds since 1970 as `YYYY-MM-DD HH:mm:ss`, UTC (Howard Hinnant's civil_from_days).
fn civil(secs: f64) -> String {
    let total = secs.floor() as i64;
    let (days, rest) = (total.div_euclid(86_400), total.rem_euclid(86_400));
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{y:04}-{m:02}-{d:02} {:02}:{:02}:{:02}", rest / 3600, rest % 3600 / 60, rest % 60)
}

unsafe fn bytes<'a>(p: *const u8, len: usize) -> &'a [u8] {
    if p.is_null() || len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(p, len)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render(src: &str, theme: &str) -> (i32, String) {
        let (mut out, mut len) = (std::ptr::null_mut(), 0usize);
        let code = unsafe { gt_mermaid_render(src.as_ptr(), src.len(), theme.as_ptr(), theme.len(), 0.0, &mut out, &mut len) };
        let s = unsafe { String::from_utf8_lossy(std::slice::from_raw_parts(out, len)).into_owned() };
        unsafe { gt_mermaid_free(out, len) };
        (code, s)
    }

    const EPOCH: &str = "gantt\n    title Calls\n    dateFormat X\n    axisFormat %S s\n    section Parallel\n    Read the folder :a1, 0, 1\n    Explore :a2, 0, 3\n    section After\n    Answer :after a2, 1\n";

    #[test]
    fn a_gantt_in_seconds_since_1970_is_drawn() {
        let (code, svg) = render(EPOCH, "dark");
        assert_eq!(code, GT_MERMAID_OK, "{svg}");
        assert!(svg.contains("Read the folder") && svg.contains("Answer"));
        let text = epoch_gantt(EPOCH).unwrap();
        assert!(text.contains("dateFormat YYYY-MM-DD HH:mm:ss"));
        assert!(text.contains(":a2, 1970-01-01 00:00:00, 1970-01-01 00:00:03"), "{text}");
        assert!(text.contains(":after a2, 1970-01-01 00:00:01"), "the start an id: {text}");
        assert!(text.contains("title Calls") && text.contains("axisFormat %S s"), "the directives as they were: {text}");
        let ms = epoch_gantt("gantt\ndateFormat x\nA :a, 1500, 2000\n").unwrap();
        assert!(ms.contains("1970-01-01 00:00:01, 1970-01-01 00:00:02"), "milliseconds: {ms}");
        assert!(epoch_gantt("gantt\ndateFormat YYYY-MM-DD\nA :a, 2026-01-01, 3d\n").is_none(), "another format: as it is");
        assert!(epoch_gantt("flowchart LR\nA --> B\n").is_none(), "not a gantt");
        assert_eq!(civil(1_794_351_911.0), "2026-11-10 23:05:11");
        // a section's name half the padding in from its band's edge, the band where it was
        assert!(svg.contains(r#"<rect x="16" "#) && !svg.contains(r#"<text x="16" "#), "{svg}");
        assert!(svg.contains(r#"<text x="24" "#));   // (date -u -d @1794351911)
    }

    #[test]
    fn a_flowchart_is_svg_and_a_mistake_says_why() {
        let (code, svg) = render("flowchart LR\n A[Start] --> B[End]", "dark");
        assert_eq!(code, GT_MERMAID_OK);
        assert!(svg.starts_with("<svg") && svg.contains("Start"));
        let (code, why) = render("not a diagram at all", "");
        assert_eq!(code, GT_MERMAID_ERROR);
        assert!(!why.is_empty());
    }
}
