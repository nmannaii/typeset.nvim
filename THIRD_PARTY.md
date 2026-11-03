# Third-party code and assets

The renderer binary embeds the following. Their licenses travel with this repository.

| Component | Where | License | Changes |
|---|---|---|---|
| [typst](https://github.com/typst/typst) (compiler, renderer, embedded fonts via typst-assets) | crates.io | Apache-2.0 (fonts: OFL / GUST) | none |
| [mermaid-rs-renderer](https://github.com/1jehuang/mermaid-rs-renderer) 0.3.1 | `vendor/mermaid-rs-renderer` | MIT (`vendor/mermaid-rs-renderer/LICENSE`) | `set_measurement_font` (labels measured with an embedded font, no system font scan); chains with labeled arrows (`A -- x --> B --> C`) split correctly; labeled self-loops no longer push their node down the diagram; state diagram labels get their own space (label ranks, edges routed through them) and self-loop labels sit beside their loop |
| [mitex](https://github.com/mitex-rs/mitex) 0.2.4 (Rust crate) | crates.io | Apache-2.0 | none |
| mitex typst scope (`specs/`) | `renderer/typst/mitex` | Apache-2.0 (`renderer/typst/mitex/LICENSE`) | `@preview/xarrow` (GPL-3.0-only, network package) replaced by typst's `stretch`; `kai` symbol (removed in typst 0.15) replaced |
| [Inter](https://rsms.me/inter/) 4.1 | `renderer/fonts` | SIL OFL 1.1 (`renderer/fonts/Inter-LICENSE.txt`) | none |
| Kitty placeholder diacritics table | `lua/typeset/placeholder.lua` | from the kitty graphics protocol specification | none |
