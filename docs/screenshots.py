#!/usr/bin/env python3
"""Regenerate the README screenshots from docs/demo.md with typeset-renderer.

    python3 docs/screenshots.py

Needs the renderer (bin/ or renderer/target/release) and ImageMagick (`magick`). The images
are the renderer's own output, the same PNGs the preview shows, laid on the theme's background;
the source pane is the markdown rendered as a code block.
"""
import json
import os
import shutil
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "screenshots")
CELL = [10, 24]  # pixels per terminal cell
WIDTH = 1000  # preview width, pixels

THEMES = {
    # tokyonight-moon, as typeset reads it from the highlight groups
    "dark": {
        "dark": True, "fg": "#c8d3f5", "base": "#222436", "muted": "#636da6", "border": "#474b60",
        "link": "#4fd6be", "code_bg": "#1b1d2b",
        "headings": ["#82aaff", "#ffc777", "#c3e88d", "#4fd6be", "#c099ff", "#fca7ea"],
        "syntax": {"keyword": "#fca7ea", "string": "#c3e88d", "comment": "#636da6", "function": "#82aaff",
                   "type": "#65bcff", "number": "#ff966c", "constant": "#ff966c", "operator": "#89ddff"},
    },
    # GitHub light
    "light": {
        "dark": False, "fg": "#1f2328", "base": "#ffffff", "muted": "#59636e", "border": "#d1d9e0",
        "link": "#0969da", "code_bg": "#eff1f3",
        "headings": ["#1f2328"],
        "syntax": {"keyword": "#cf222e", "string": "#0a3069", "comment": "#59636e", "function": "#8250df",
                   "type": "#953800", "number": "#0550ae", "constant": "#0550ae", "operator": "#1f2328"},
    },
}


def renderer():
    for path in ("bin/typeset-renderer", "renderer/target/release/typeset-renderer"):
        full = os.path.join(ROOT, path)
        if os.access(full, os.X_OK):
            return full
    raise SystemExit("typeset-renderer not found: run :TypesetInstall or cargo build --release")


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

    def flatten(src, bg, dest, pad=24):
        subprocess.run(["magick", src, "-background", bg, "-flatten", "-bordercolor", bg, "-border", str(pad),
                        "-strip", dest], check=True)

    for name, theme in THEMES.items():
        page = render(demo, WIDTH, theme, f"preview-{name}")
        flatten(page, theme["base"], os.path.join(OUT, f"preview-{name}.png"))

    # Side by side: the source (as typeset draws a markdown code block) and its preview.
    theme = THEMES["dark"]
    # A longer fence than the demo's own ``` blocks, so they don't close it.
    source = render("````markdown\n" + demo.strip() + "\n````", 860, theme, "source")
    preview = os.path.join(tmp, "preview-dark.png")
    pair = os.path.join(tmp, "pair.png")
    subprocess.run(["magick", source, "(", "-size", "32x1", "xc:none", ")", preview, "-background", "none",
                    "-gravity", "north", "+append", "+repage", pair], check=True)
    flatten(pair, theme["base"], os.path.join(OUT, "source-and-preview.png"))

    proc.stdin.close()
    proc.wait()
    shutil.rmtree(tmp)
    for f in sorted(os.listdir(OUT)):
        print(os.path.join("docs", "screenshots", f))


if __name__ == "__main__":
    main()
