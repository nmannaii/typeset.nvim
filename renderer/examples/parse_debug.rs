//! cargo run --release --example parse_debug -- '<mermaid source>'
fn main() {
    let src = std::env::args().nth(1).unwrap().replace("\\n", "\n");
    let out = mermaid_rs_renderer::parse_mermaid(&src).unwrap();
    let g = &out.graph;
    for (id, n) in &g.nodes { println!("node {id:?} label={:?}", n.label); }
    for e in &g.edges { println!("edge {} -> {} label={:?}", e.from, e.to, e.label); }
}
