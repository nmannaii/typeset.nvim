//! typeset-renderer: renders markdown snippets to PNG for typeset.nvim.
//!
//! Protocol: one JSON request per line on stdin, one JSON reply per line on stdout.
//!
//!   → {"id": 1, "markdown": "# Title", "width": 960, "cell": [10, 20], "out": "/cache/x.png", "theme": {...}, "inline": false}
//!   ← {"id": 1, "path": "/cache/x.png", "width": 960, "height": 60, "cols": 96, "rows": 3}
//!   ← {"id": 1, "error": "..."}
//!
//! Sizes are in pixels. The image is exactly `width` wide and padded to a whole number of cell
//! rows, so the terminal shows it on `cols` x `rows` cells without rescaling. The process stays
//! up between requests: typst memoizes across compilations, so re-rendering an edited block
//! only redoes what changed.

mod convert;
mod world;

use std::io::{BufRead, Write};

use serde::Deserialize;
use serde_json::json;
use typst_layout::PagedDocument;

#[derive(Deserialize)]
struct Request {
    id: u64,
    markdown: String,
    width: u32,
    cell: [u32; 2],
    out: String,
    #[serde(default)]
    theme: convert::Theme,
    /// Body text size as a fraction of the cell height.
    #[serde(default = "default_text_scale")]
    text_scale: f64,
    /// Shown in the editor buffer between lines of text (typeset.nvim's inline mode): no page
    /// margins and no space above headings, the buffer's blank lines space the blocks.
    #[serde(default)]
    inline: bool,
}

fn default_text_scale() -> f64 {
    0.72
}

struct Rendered {
    width: u32,
    height: u32,
    cols: u32,
    rows: u32,
}

fn render(req: &Request) -> Result<Rendered, String> {
    let [cw, ch] = req.cell;
    if cw == 0 || ch == 0 || req.width == 0 {
        return Err("width and cell must be positive".into());
    }
    // One typst point = one pixel: the page is laid out directly in terminal pixels.
    let page = convert::Page { width: req.width as f64, text_size: ch as f64 * req.text_scale, inline: req.inline };
    let doc = convert::convert(&req.markdown, &req.theme, page);
    let world = world::MemoryWorld::new(doc.source, doc.files);
    let document = typst::compile::<PagedDocument>(&world).output.map_err(|errors| {
        errors.iter().map(|e| e.message.to_string()).collect::<Vec<_>>().join("; ")
    })?;
    let page = document.pages().first().ok_or("empty document")?;
    let pixmap = typst_render::render(page, &typst_render::RenderOptions { pixel_per_pt: 1.0.into(), render_bleed: false });

    // Trim the transparent right side: the page is as wide as the window, but a heading or a
    // small table only covers part of it, and every cell the image spans becomes a placeholder
    // character the editor and the terminal have to draw on each redraw.
    let used = used_width(&pixmap).max(1);
    let cols = used.div_ceil(cw);
    let rows = pixmap.height().div_ceil(ch).max(1);
    let (width, height) = (cols * cw, rows * ch);
    let mut padded = tiny_skia::Pixmap::new(width, height).ok_or("bad image size")?;
    padded.draw_pixmap(0, 0, pixmap.as_ref(), &tiny_skia::PixmapPaint::default(), tiny_skia::Transform::identity(), None);
    let png = padded.encode_png().map_err(|e| e.to_string())?;
    std::fs::write(&req.out, png).map_err(|e| format!("{}: {e}", req.out))?;
    Ok(Rendered { width, height, cols, rows })
}

/// Width up to the rightmost pixel that isn't fully transparent.
fn used_width(pixmap: &tiny_skia::Pixmap) -> u32 {
    let w = pixmap.width() as usize;
    let mut right = 0;
    for row in pixmap.data().chunks_exact(w * 4) {
        // Scan from the right edge only as far as the widest row found so far.
        for x in (right..w).rev() {
            if row[x * 4 + 3] != 0 {
                right = x + 1;
                break;
            }
        }
        if right == w {
            break;
        }
    }
    right as u32
}

fn main() {
    // Diagram labels are measured with the font typst draws them with: no system fonts.
    mermaid_rs_renderer::set_measurement_font(world::INTER_REGULAR);

    let stdout = std::io::stdout();
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Request>(&line) {
            Err(e) => json!({ "id": null, "error": format!("bad request: {e}") }),
            Ok(req) => {
                // A panic in a dependency (parser bug on odd input) must not take the server down.
                match std::panic::catch_unwind(|| render(&req)) {
                    Ok(Ok(r)) => json!({ "id": req.id, "path": req.out, "width": r.width, "height": r.height, "cols": r.cols, "rows": r.rows }),
                    Ok(Err(e)) => json!({ "id": req.id, "error": e }),
                    Err(_) => json!({ "id": req.id, "error": "renderer panicked" }),
                }
            }
        };
        let mut out = stdout.lock();
        let _ = writeln!(out, "{reply}");
        let _ = out.flush();
    }
}
