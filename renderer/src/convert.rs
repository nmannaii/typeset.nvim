//! Markdown → typst source.
//!
//! Every piece of text is emitted as a typst *string literal* (`#"..."`) inside content blocks,
//! never as markup, so nothing in the markdown (`*`, `#`, `$`, `@`, `<`...) can be misread by
//! typst and no markup escaping rules are needed. Formatting is applied with function calls
//! (`#strong[...]`, `#link("...")[...]`). Mermaid blocks are rendered to SVG here and handed to
//! typst as in-memory files; LaTeX math is converted with mitex and evaluated in its scope.

use std::collections::HashMap;
use std::fmt::Write;

use pulldown_cmark::{Alignment, BlockQuoteKind, CodeBlockKind, Event, Options, Parser, Tag, TagEnd};
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Theme {
    pub dark: bool,
    pub fg: String,
    /// Page background; `None` = transparent, the terminal background shows through.
    pub bg: Option<String>,
    /// The editor background, which the page sits on (for blends; the page itself stays
    /// transparent).
    pub base: String,
    pub muted: String,
    /// Rules, table borders, the bar of quotes.
    pub border: String,
    pub link: String,
    pub code_bg: String,
    /// Colours of heading levels 1..6 (shorter lists repeat their last colour).
    pub headings: Vec<String>,
    pub font: String,
    pub mono_font: String,
    /// Code colours by role (keyword, string, comment, function, type, number, constant,
    /// operator, variable, punctuation), usually taken from the editor's highlight groups.
    pub syntax: HashMap<String, String>,
}

impl Default for Theme {
    fn default() -> Self {
        Self {
            dark: true,
            fg: "#c8d3f5".into(),
            bg: None,
            base: "#222436".into(),
            muted: "#828bb8".into(),
            border: "#3b4261".into(),
            link: "#82aaff".into(),
            code_bg: "#2f334d".into(),
            headings: vec!["#82aaff".into(), "#ffc777".into(), "#c3e88d".into(), "#4fd6be".into(), "#c099ff".into(), "#fca7ea".into()],
            font: "Inter".into(),
            mono_font: "DejaVu Sans Mono".into(),
            syntax: [
                ("keyword", "#c099ff"),
                ("string", "#c3e88d"),
                ("comment", "#636da6"),
                ("function", "#82aaff"),
                ("type", "#65bcff"),
                ("number", "#ff966c"),
                ("constant", "#ff966c"),
                ("operator", "#89ddff"),
            ]
            .into_iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
        }
    }
}

/// Page geometry, in typst points.
#[derive(Debug, Clone, Copy)]
pub struct Page {
    pub width: f64,
    pub text_size: f64,
}

pub struct Document {
    pub source: String,
    pub files: HashMap<String, Vec<u8>>,
}

fn string(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => {}
            '\t' => out.push_str("    "),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// TextMate scopes each syntax role colours. typst highlights code with syntect, which takes
/// a .tmTheme; building one from the editor's colours keeps code blocks on its colourscheme.
const SCOPES: [(&str, &str); 8] = [
    ("comment", "comment, punctuation.definition.comment"),
    ("string", "string, constant.character"),
    ("keyword", "keyword, storage.modifier, keyword.control"),
    ("function", "entity.name.function, support.function, meta.function-call"),
    ("type", "storage.type, entity.name.type, entity.name.class, support.type, support.class"),
    ("number", "constant.numeric"),
    ("constant", "constant.language, constant.other, variable.other.constant"),
    ("operator", "keyword.operator, punctuation.separator, punctuation.accessor"),
];

pub const CODE_THEME_PATH: &str = "/code.tmTheme";

pub fn code_theme(theme: &Theme) -> String {
    let xml = |s: &str| s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
    let mut out = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict><key>name</key><string>typeset</string><key>settings</key><array>\n<dict><key>settings</key><dict><key>foreground</key><string>{}</string></dict></dict>\n",
        xml(&theme.fg)
    );
    for (role, scope) in SCOPES {
        if let Some(color) = theme.syntax.get(role) {
            let style = if role == "comment" { "<key>fontStyle</key><string>italic</string>" } else { "" };
            let _ = writeln!(
                out,
                "<dict><key>scope</key><string>{scope}</string><key>settings</key><dict><key>foreground</key><string>{}</string>{style}</dict></dict>",
                xml(color)
            );
        }
    }
    out.push_str("</array></dict></plist>\n");
    out
}

/// Fence names people write that syntect knows under another name.
fn code_lang(lang: &str) -> &str {
    match lang {
        "csharp" | "dotnet" => "cs",
        "shell" | "zsh" | "console" => "bash",
        "jsonc" | "json5" => "json",
        "yml" => "yaml",
        "golang" => "go",
        "py" => "python",
        "rb" => "ruby",
        "md" => "markdown",
        other => other,
    }
}

/// Hex colour `a` mixed over `b` (`alpha` of `a`).
fn blend(a: &str, b: &str, alpha: f64) -> String {
    let rgb = |s: &str| {
        let s = s.trim_start_matches('#');
        let c = |i: usize| u8::from_str_radix(s.get(i..i + 2).unwrap_or("00"), 16).unwrap_or(0) as f64;
        [c(0), c(2), c(4)]
    };
    let (a, b) = (rgb(a), rgb(b));
    let m = |i: usize| (a[i] * alpha + b[i] * (1.0 - alpha)).round() as u8;
    format!("#{:02x}{:02x}{:02x}", m(0), m(1), m(2))
}

/// The stylesheet: GitHub's markdown layout (sizes, rules under h1/h2, padded code, striped
/// tables) in the editor's colours. Each block is a page of its own, so the page's bottom
/// margin is the space between blocks and headings bring their own space above.
fn preamble(theme: &Theme, page: Page) -> String {
    let heading = |level: usize| theme.headings.get(level - 1).or(theme.headings.last()).cloned().unwrap_or(theme.fg.clone());
    let headings: Vec<String> = (1..=6).map(|l| format!("rgb({})", string(&heading(l)))).collect();
    let fill = theme.bg.as_ref().map_or("none".to_string(), |bg| format!("rgb({})", string(bg)));
    format!(
        r#"#import "/mitex/specs/mod.typ": mitex-scope
#let fg = rgb({fg})
#let muted = rgb({muted})
#let border = rgb({border})
#let code-bg = rgb({code_bg})
#let stripe = rgb({stripe})
#let heading-colors = ({headings})
#set page(width: {width}pt, height: auto, margin: (left: 1em, right: 1em, top: 0pt, bottom: 0.9em), fill: {fill})
#set text(font: ({font}, "Libertinus Serif", {mono}), size: {size}pt, fill: fg, hyphenate: false)
#set par(justify: false, leading: 0.65em, spacing: 1em)
#show strong: set text(weight: 600)
#show link: set text(fill: rgb({link}))

#show heading: it => {{
  let size = (1.75em, 1.4em, 1.2em, 1.05em, 0.95em, 0.9em).at(it.level - 1)
  v(0.5em)
  let title = text(size: size, weight: 600, fill: heading-colors.at(it.level - 1), it.body)
  if it.level <= 2 {{
    block(width: 100%, stroke: (bottom: 0.8pt + border), inset: (bottom: 0.35em), title)
  }} else {{
    block(title)
  }}
}}

#set raw(theme: {code_theme})
#show raw: set text(font: {mono})
#show raw.where(block: false): it => box(
  fill: code-bg, inset: (x: 0.3em), outset: (y: 0.25em), radius: 4pt, text(size: 0.92em, it),
)
// Set rules, not `par(..., it)`: a code block is block content, which par() drops silently.
#show raw.where(block: true): set par(leading: 0.6em)
#show raw.where(block: true): set text(size: 0.9em)
#show raw.where(block: true): it => block(
  fill: code-bg, inset: (x: 1em, y: 0.85em), radius: 6pt, width: 100%, it,
)

#set list(marker: (text(fill: muted)[•], text(fill: muted)[◦], text(fill: muted)[▪]), indent: 0.3em, body-indent: 0.6em, spacing: 0.5em)
#set enum(indent: 0.3em, body-indent: 0.6em, spacing: 0.5em)

#set table(
  stroke: 0.6pt + border,
  inset: (x: 0.8em, y: 0.5em),
  fill: (_, y) => if y == 0 {{ code-bg }} else if calc.even(y) {{ stripe }} else {{ none }},
)
#show table.cell.where(y: 0): set text(weight: 600)

#let mi(s) = math.equation(block: false, eval("$" + s + "$", scope: mitex-scope))
#let mb(s) = math.equation(block: true, eval("$" + s + "$", scope: mitex-scope))

#let quote-block(title, color, body) = block(
  stroke: (left: 3pt + color), inset: (left: 1em, y: 0.2em), width: 100%,
  {{
    if title != none {{ text(fill: color, weight: 600, title); parbreak(); body }}
    else {{ text(fill: muted, body) }}
  }},
)
#let fit-image(path) = layout(size => {{
  let img = image(path)
  // Left-aligned: the renderer trims the transparent right side, so centring would only add
  // empty cells.
  if measure(img).width > size.width {{ image(path, width: 100%) }} else {{ img }}
}})
"#,
        width = page.width,
        size = page.text_size,
        font = string(&theme.font),
        mono = string(&theme.mono_font),
        fg = string(&theme.fg),
        muted = string(&theme.muted),
        border = string(&theme.border),
        link = string(&theme.link),
        code_bg = string(&theme.code_bg),
        stripe = string(&blend(&theme.code_bg, &theme.base, 0.45)),
        headings = headings.join(", "),
        code_theme = string(CODE_THEME_PATH),
    )
}

/// Title and colour of a GitHub alert (`> [!NOTE]`), readable on dark or light backgrounds.
fn alert(kind: BlockQuoteKind, dark: bool) -> (&'static str, &'static str) {
    match (kind, dark) {
        (BlockQuoteKind::Note, true) => ("Note", "#82aaff"),
        (BlockQuoteKind::Tip, true) => ("Tip", "#c3e88d"),
        (BlockQuoteKind::Important, true) => ("Important", "#c099ff"),
        (BlockQuoteKind::Warning, true) => ("Warning", "#ffc777"),
        (BlockQuoteKind::Caution, true) => ("Caution", "#ff757f"),
        (BlockQuoteKind::Note, false) => ("Note", "#0969da"),
        (BlockQuoteKind::Tip, false) => ("Tip", "#1a7f37"),
        (BlockQuoteKind::Important, false) => ("Important", "#8250df"),
        (BlockQuoteKind::Warning, false) => ("Warning", "#9a6700"),
        (BlockQuoteKind::Caution, false) => ("Caution", "#cf222e"),
    }
}

/// Mermaid in the editor's colours instead of its stock themes (near-black boxes and grey text
/// on a dark background): boxes in the code background, borders and lines in the border and
/// muted colours, text in the foreground, notes tinted with the link colour.
fn mermaid_svg(code: &str, theme: &Theme, text_size: f64) -> Result<String, String> {
    let mut opts = mermaid_rs_renderer::RenderOptions::default();
    let t = &mut opts.theme;
    *t = if theme.dark { mermaid_rs_renderer::Theme::dark() } else { mermaid_rs_renderer::Theme::modern() };
    t.font_family = theme.font.clone();
    t.font_size = text_size as f32;
    t.background = "none".into();
    let note = blend(&theme.link, &theme.base, 0.18);
    let box_fill = theme.code_bg.clone();
    for (field, value) in [
        (&mut t.primary_color, &box_fill),
        (&mut t.secondary_color, &box_fill),
        (&mut t.tertiary_color, &box_fill),
        (&mut t.sequence_actor_fill, &box_fill),
        (&mut t.sequence_activation_fill, &box_fill),
        (&mut t.cluster_background, &theme.base),
        (&mut t.edge_label_background, &theme.base),
        (&mut t.primary_border_color, &theme.muted),
        (&mut t.sequence_actor_border, &theme.muted),
        (&mut t.sequence_activation_border, &theme.muted),
        (&mut t.cluster_border, &theme.border),
        (&mut t.line_color, &theme.muted),
        (&mut t.sequence_actor_line, &theme.border),
        (&mut t.primary_text_color, &theme.fg),
        (&mut t.text_color, &theme.fg),
        (&mut t.sequence_note_fill, &note),
        (&mut t.sequence_note_border, &theme.link),
    ] {
        *field = value.clone();
    }
    mermaid_rs_renderer::render_with_options(code, opts).map_err(|e| e.to_string())
}

fn math(latex: &str, block: bool) -> String {
    match mitex::convert_math(latex, None) {
        Ok(code) => format!("#{}({})", if block { "mb" } else { "mi" }, string(&code)),
        // Unknown command or syntax error: show the source rather than nothing.
        Err(_) => format!("#raw({})", string(latex)),
    }
}

/// Convert `markdown` to a typst document laid out `page.width` points wide.
pub fn convert(markdown: &str, theme: &Theme, page: Page) -> Document {
    let mut out = preamble(theme, page);
    let mut files = HashMap::from([(CODE_THEME_PATH.to_string(), code_theme(theme).into_bytes())]);
    // Text of the code block being read (code blocks arrive as Text events).
    let mut code: Option<(String, String)> = None;

    let options = Options::ENABLE_TABLES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_MATH
        | Options::ENABLE_GFM
        | Options::ENABLE_YAML_STYLE_METADATA_BLOCKS;
    let mut in_metadata = false;
    for event in Parser::new_ext(markdown, options) {
        if let Some((_, text)) = code.as_mut() {
            match event {
                Event::Text(t) => {
                    text.push_str(&t);
                    continue;
                }
                Event::End(TagEnd::CodeBlock) => {}
                _ => continue,
            }
        }
        if in_metadata {
            match event {
                // Front matter: only its title is shown, as the document title.
                Event::Text(t) => {
                    for line in t.lines() {
                        if let Some(title) = line.strip_prefix("title:") {
                            let title = title.trim().trim_matches(|c| c == '"' || c == '\'');
                            let _ = writeln!(out, "#heading(level: 1, outlined: false)[#{}]", string(title));
                        }
                    }
                }
                Event::End(TagEnd::MetadataBlock(_)) => in_metadata = false,
                _ => {}
            }
            continue;
        }
        match event {
            Event::Start(tag) => match tag {
                Tag::MetadataBlock(_) => in_metadata = true,
                Tag::Paragraph => {}
                Tag::Heading { level, .. } => {
                    let _ = write!(out, "#heading(level: {}, outlined: false)[", level as usize);
                }
                Tag::BlockQuote(kind) => {
                    let (title, color) = kind.map(|k| alert(k, theme.dark)).map_or(("none".to_string(), theme.muted.as_str()), |(t, c)| (string(t), c));
                    let _ = write!(out, "#quote-block({title}, rgb({}))[", string(color));
                }
                Tag::CodeBlock(kind) => {
                    let lang = match kind {
                        CodeBlockKind::Fenced(info) => info.split_whitespace().next().unwrap_or("").to_string(),
                        CodeBlockKind::Indented => String::new(),
                    };
                    code = Some((lang, String::new()));
                }
                Tag::List(Some(start)) => {
                    let _ = write!(out, "#enum(start: {start}, tight: true, ");
                }
                Tag::List(None) => out.push_str("#list(tight: true, "),
                Tag::Item => out.push('['),
                Tag::Table(aligns) => {
                    let align: Vec<&str> = aligns
                        .iter()
                        .map(|a| match a {
                            Alignment::Center => "center",
                            Alignment::Right => "right",
                            _ => "left",
                        })
                        .collect();
                    let _ = write!(out, "#table(columns: {}, align: ({},), ", aligns.len(), align.join(", "));
                }
                Tag::TableHead | Tag::TableRow => {}
                Tag::TableCell => out.push('['),
                Tag::Emphasis => out.push_str("#emph["),
                Tag::Strong => out.push_str("#strong["),
                Tag::Strikethrough => out.push_str("#strike["),
                Tag::Link { dest_url, .. } => {
                    let _ = write!(out, "#link({})[", string(&dest_url));
                }
                // Images are snacks.image's job; keep the alt text visible.
                Tag::Image { .. } => out.push_str("#text(fill: rgb(\"#828bb8\"))[#\"🖼 \""),
                _ => {}
            },
            Event::End(tag) => match tag {
                TagEnd::Paragraph => out.push_str("\n\n"),
                TagEnd::Heading(_) => out.push_str("]\n"),
                TagEnd::BlockQuote(_) => out.push_str("]\n"),
                TagEnd::CodeBlock => {
                    let (lang, text) = code.take().unwrap_or_default();
                    let text = text.trim_end_matches('\n');
                    match lang.as_str() {
                        "mermaid" => match mermaid_svg(text, theme, page.text_size) {
                            Ok(svg) => {
                                let path = format!("/mermaid-{}.svg", files.len());
                                let _ = writeln!(out, "#fit-image({})", string(&path));
                                files.insert(path, svg.into_bytes());
                            }
                            Err(e) => {
                                let _ = writeln!(out, "#text(fill: rgb(\"#ff757f\"))[#{}]", string(&format!("mermaid: {e}")));
                            }
                        },
                        "math" | "latex" | "tex" => {
                            out.push_str(&math(text, true));
                            out.push('\n');
                        }
                        _ => {
                            let _ = writeln!(out, "#raw(block: true, lang: {}, {})", string(code_lang(&lang)), string(text));
                        }
                    }
                }
                TagEnd::List(_) => out.push_str(")\n"),
                TagEnd::Item => out.push_str("], "),
                TagEnd::Table => out.push_str(")\n"),
                TagEnd::TableHead | TagEnd::TableRow => {}
                TagEnd::TableCell => out.push_str("], "),
                TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough | TagEnd::Link | TagEnd::Image => out.push(']'),
                _ => {}
            },
            Event::Text(t) => {
                out.push('#');
                out.push_str(&string(&t));
            }
            Event::Code(t) => {
                let _ = write!(out, "#raw({})", string(&t));
            }
            Event::InlineMath(t) => out.push_str(&math(&t, false)),
            Event::DisplayMath(t) => out.push_str(&math(&t, true)),
            Event::SoftBreak => out.push_str("#\" \""),
            Event::HardBreak => out.push_str("#linebreak()"),
            Event::Rule => {
                let _ = writeln!(out, "#line(length: 100%, stroke: 0.5pt + rgb({}))", string(&theme.muted));
            }
            Event::TaskListMarker(done) => out.push_str(if done { "#\"☑ \"" } else { "#\"☐ \"" }),
            Event::Html(html) | Event::InlineHtml(html) => {
                if html.trim().trim_end_matches('/').trim_end().eq_ignore_ascii_case("<br") || html.trim().eq_ignore_ascii_case("<br>") {
                    out.push_str("#linebreak()");
                }
            }
            _ => {}
        }
    }
    Document { source: out, files }
}
