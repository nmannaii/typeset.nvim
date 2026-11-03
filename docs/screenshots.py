#!/usr/bin/env python3
"""Regenerate the README screenshots from docs/demo.md with typeset-renderer.

    python3 docs/screenshots.py

Needs the renderer (bin/ or renderer/target/release) and ImageMagick (`magick`). Every picture is
the renderer's own output, the same PNGs the preview shows, framed as an editor window:

- hero.png      the markdown source next to its split preview
- overlay.png   the reading overlay: the document in a centred column over the whole editor
- themes.png    the preview in a dark and a light colourscheme
"""
import json
import os
import shutil
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "screenshots")
FONT = os.path.join(ROOT, "renderer", "fonts", "Inter-Regular.ttf")
FONT_BOLD = os.path.join(ROOT, "renderer", "fonts", "Inter-SemiBold.ttf")
CELL = [10, 24]  # pixels per terminal cell

THEMES = {
    # tokyonight-moon, as typeset reads it from the highlight groups
    "dark": {
        "dark": True, "fg": "#c8d3f5", "base": "#222436", "muted": "#636da6", "border": "#3b4261",
        "link": "#4fd6be", "code_bg": "#1e2030",
        "headings": ["#82aaff", "#ffc777", "#c3e88d", "#4fd6be", "#c099ff", "#fca7ea"],
        "syntax": {"keyword": "#c099ff", "string": "#c3e88d", "comment": "#636da6", "function": "#82aaff",
                   "type": "#65bcff", "number": "#ff966c", "constant": "#ff966c", "operator": "#89ddff"},
    },
    # GitHub light
    "light": {
        "dark": False, "fg": "#1f2328", "base": "#ffffff", "muted": "#59636e", "border": "#d1d9e0",
        "link": "#0969da", "code_bg": "#f6f8fa",
        "headings": ["#1f2328"],
        "syntax": {"keyword": "#cf222e", "string": "#0a3069", "comment": "#59636e", "function": "#8250df",
                   "type": "#953800", "number": "#0550ae", "constant": "#0550ae", "operator": "#1f2328"},
    },
}
# Window chrome per theme: title bar, pane title bar, divider, title text.
CHROME = {
    "dark": {"bar": "#1b1d2b", "pane": "#1e2030", "divider": "#3b4261", "text": "#828bb8"},
    "light": {"bar": "#eaeef2", "pane": "#f6f8fa", "divider": "#d1d9e0", "text": "#59636e"},
}


def renderer():
    for path in ("bin/typeset-renderer", "renderer/target/release/typeset-renderer"):
        full = os.path.join(ROOT, path)
        if os.access(full, os.X_OK):
            return full
    raise SystemExit("typeset-renderer not found: run :TypesetInstall or cargo build --release")


def magick(*args):
    subprocess.run(["magick", *map(str, args)], check=True)


def size(path):
    out = subprocess.run(["magick", "identify", "-format", "%w %h", path], check=True, capture_output=True, text=True)
    w, h = out.stdout.split()
    return int(w), int(h)


def main():
    demo = open(os.path.join(ROOT, "docs", "demo.md")).read()
    os.makedirs(OUT, exist_ok=True)
    proc = subprocess.Popen([renderer()], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    tmp = tempfile.mkdtemp()

    def render(markdown, width, theme, name):
        path = os.path.join(tmp, name + ".png")
        request = {"id": 1, "markdown": markdown, "width": width, "cell": CELL, "out": path, "theme": theme}
        proc.stdin.write(json.dumps(request) + "\n")
        proc.stdin.flush()
        reply = json.loads(proc.stdout.readline())
        if "error" in reply:
            raise SystemExit(f"{name}: {reply['error']}")
        return path

    def pane(src, width, height, bg, dest, top=0, left=0):
        """`src` laid on `bg`, `width` x `height`, starting at row `top` of it, `left` px in."""
        magick("-size", f"{width}x{height}", f"xc:{bg}", "(", src, "-crop", f"{width}x{height}+0+{top}", "+repage", ")",
               "-geometry", f"+{left}+0", "-composite", dest)

    def titled(src, title, chrome, dest, hint=""):
        """A pane title bar (like a winbar) over `src`, `hint` on its right."""
        args = [src, "-gravity", "north", "-background", chrome["pane"], "-splice", "0x34",
                "-font", FONT, "-pointsize", 15, "-fill", chrome["text"],
                "-gravity", "northwest", "-annotate", "+18+9", title]
        if hint:
            args += ["-gravity", "northeast", "-annotate", "+18+9", hint]
        magick(*args, dest)

    def window(src, title, chrome, dest):
        """`src` in an editor window: a title bar with traffic lights, rounded corners, a shadow."""
        w, h = size(src)
        bar = 44
        body = os.path.join(tmp, "body.png")
        magick("-size", f"{w}x{h + bar}", f"xc:{chrome['bar']}", src, "-geometry", f"+0+{bar}", "-composite",
               "-fill", "#ff5f57", "-draw", f"circle 24,{bar // 2} 30,{bar // 2}",
               "-fill", "#febc2e", "-draw", f"circle 46,{bar // 2} 52,{bar // 2}",
               "-fill", "#28c840", "-draw", f"circle 68,{bar // 2} 74,{bar // 2}",
               "-font", FONT_BOLD, "-pointsize", 15, "-fill", chrome["text"], "-gravity", "north",
               "-annotate", "+0+13", title, body)
        w, h = size(body)
        magick(body, "(", "+clone", "-alpha", "extract", "-fill", "black", "-colorize", "100",
               "-fill", "white", "-draw", f"roundrectangle 0,0,{w - 1},{h - 1},14,14", ")",
               "-alpha", "off", "-compose", "CopyOpacity", "-composite",
               "(", "+clone", "-background", "black", "-shadow", "45x22+0+14", ")", "+swap",
               "-background", "none", "-compose", "over", "-layers", "merge", "+repage", dest)

    dark = THEMES["dark"]
    height = 1080

    # hero: source | preview, as the split shows them. The source is the markdown as a code block,
    # its card made invisible (background, border and language label in the page colour) so it
    # reads as the editor's buffer.
    plain = dict(dark, code_bg=dark["base"], border=dark["base"], muted=dark["base"])
    src = render("````markdown\n" + demo.strip() + "\n````", 860, plain, "source")
    preview = render(demo, 1000, dark, "preview-dark")
    left, right = os.path.join(tmp, "left.png"), os.path.join(tmp, "right.png")
    pane(src, 860, height, dark["base"], left)
    pane(preview, 1000, height, dark["base"], right)
    titled(left, "demo.md", CHROME["dark"], left)
    titled(right, "typeset", CHROME["dark"], right)
    pair = os.path.join(tmp, "pair.png")
    magick(left, "(", "-size", f"1x{height + 34}", f"xc:{CHROME['dark']['divider']}", ")", right, "+append", pair)
    window(pair, "nvim — demo.md", CHROME["dark"], os.path.join(OUT, "hero.png"))

    # overlay: the document in a centred column over the whole editor, scrolled to the table.
    full = 1861
    column = os.path.join(tmp, "column.png")
    pane(preview, full, height, dark["base"], column, top=660, left=(full - 1000) // 2)
    titled(column, "demo.md", CHROME["dark"], column, hint="j/k  d/u  ]] [[ headings  ·  e edit  ·  q close")
    window(column, "nvim — demo.md", CHROME["dark"], os.path.join(OUT, "overlay.png"))

    # themes: the same document in a dark and a light colourscheme.
    shots = []
    for name in ("dark", "light"):
        img = render(demo, 900, THEMES[name], f"theme-{name}")
        p = os.path.join(tmp, f"theme-pane-{name}.png")
        pane(img, 900, 900, THEMES[name]["base"], p)
        w = os.path.join(tmp, f"theme-window-{name}.png")
        window(p, "tokyonight-moon" if name == "dark" else "GitHub light", CHROME[name], w)
        shots.append(w)
    magick("-background", "none", shots[0], "(", "-size", "8x1", "xc:none", ")", shots[1], "+append",
           os.path.join(OUT, "themes.png"))

    proc.stdin.close()
    proc.wait()
    shutil.rmtree(tmp)
    # Pictures of the previous layout.
    for old in ("source-and-preview.png", "preview-dark.png", "preview-light.png"):
        path = os.path.join(OUT, old)
        if os.path.exists(path):
            os.remove(path)
    for f in sorted(os.listdir(OUT)):
        print(os.path.join("docs", "screenshots", f))


if __name__ == "__main__":
    main()
