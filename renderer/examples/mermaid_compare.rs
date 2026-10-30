//! Renders a .mmd file with both pure-Rust mermaid renderers, through typst, to compare them.
//! cargo run --release --example mermaid_compare -- <in.mmd> <out-prefix>
#[path = "../src/world.rs"]
mod world;

use std::collections::HashMap;
use std::time::Instant;

use typst_layout::PagedDocument;

fn to_png(svg: &str, out: &str) {
    let src = "#set page(width: auto, height: auto, margin: 8pt, fill: rgb(\"#222436\"))\n#image(\"/d.svg\")";
    let files = HashMap::from([("/d.svg".to_string(), svg.as_bytes().to_vec())]);
    let world = world::MemoryWorld::new(src.into(), files);
    match typst::compile::<PagedDocument>(&world).output {
        Ok(doc) => {
            let pix = typst_render::render(&doc.pages()[0], &typst_render::RenderOptions { pixel_per_pt: 1.5.into(), render_bleed: false });
            std::fs::write(out, pix.encode_png().unwrap()).unwrap();
        }
        Err(errors) => errors.iter().for_each(|e| eprintln!("typst: {}", e.message)),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let input = std::fs::read_to_string(&args[1]).unwrap();
    mermaid_rs_renderer::set_measurement_font(world::INTER_REGULAR);
    let mut opts = mermaid_rs_renderer::RenderOptions::default();
    opts.theme = mermaid_rs_renderer::Theme::dark();
    opts.theme.font_family = "Inter".into();
    for round in 0..2 {
        let t = Instant::now();
        match mermaid_rs_renderer::render_with_options(&input, opts.clone()) {
            Ok(svg) => {
                eprintln!("mmdr round {round}: {:?}", t.elapsed());
                to_png(&svg, &format!("{}-mmdr.png", args[2]));
            }
            Err(e) => eprintln!("mmdr error: {e}"),
        }
    }
}
