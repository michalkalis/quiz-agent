#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown>=3.5"]
# ///
"""Wrap a markdown file in the project dark-theme HTML report shell.

Usage:
    uv run scripts/md2report.py input.md [output.html]

Default output: docs/artifacts/<input-stem>.html
The agent writes ONLY the markdown body; all styling (dark theme, sticky TOC,
tables, badges, collapsibles) comes from this template — never hand-write it.

Markdown extras available in the body:
    - GFM-ish tables, fenced code, footnotes (via `extra`)
    - <details><summary>...</summary>...</details> passes through as HTML
    - status badges: <span class="badge ok">PASS</span> / warn / bad / info
"""
import sys
from pathlib import Path

import markdown

CSS = """
:root{color-scheme:dark;--bg:#12141a;--panel:#1a1d26;--border:#2a2e3b;
--fg:#d6dae3;--dim:#8b93a5;--accent:#6ea8fe;--ok:#3fb950;--warn:#d29922;--bad:#f85149}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:15px/1.6 -apple-system,'SF Pro Text',Segoe UI,sans-serif}
.layout{display:flex;max-width:1200px;margin:0 auto;gap:2rem;padding:2rem}
nav{position:sticky;top:2rem;align-self:flex-start;width:220px;flex-shrink:0;
font-size:.85rem;max-height:90vh;overflow-y:auto}
nav ul{list-style:none;padding-left:.9rem;margin:.2rem 0}
nav>ul{padding-left:0}
nav a{color:var(--dim);text-decoration:none;display:block;padding:.15rem 0}
nav a:hover{color:var(--accent)}
main{min-width:0;flex:1}
h1{font-size:1.6rem;margin-top:0}
h2{font-size:1.2rem;border-bottom:1px solid var(--border);padding-bottom:.3rem;margin-top:2.2rem}
h3{font-size:1rem;color:var(--accent)}
a{color:var(--accent)}
code{background:var(--panel);border:1px solid var(--border);border-radius:4px;
padding:.1em .35em;font-size:.85em}
pre{background:var(--panel);border:1px solid var(--border);border-radius:8px;
padding:1rem;overflow-x:auto}
pre code{background:none;border:none;padding:0}
table{border-collapse:collapse;width:100%;margin:1rem 0;font-size:.9rem}
th,td{border:1px solid var(--border);padding:.45rem .7rem;text-align:left}
th{background:var(--panel)}
tr:nth-child(even) td{background:#161923}
blockquote{border-left:3px solid var(--accent);margin:1rem 0;padding:.2rem 1rem;
color:var(--dim);background:var(--panel);border-radius:0 8px 8px 0}
details{background:var(--panel);border:1px solid var(--border);border-radius:8px;
padding:.6rem 1rem;margin:.8rem 0}
summary{cursor:pointer;font-weight:600}
.badge{display:inline-block;padding:.05em .55em;border-radius:999px;
font-size:.75rem;font-weight:700;letter-spacing:.02em}
.badge.ok{background:#12351c;color:var(--ok)}
.badge.warn{background:#3a2d10;color:var(--warn)}
.badge.bad{background:#3d1517;color:var(--bad)}
.badge.info{background:#16283f;color:var(--accent)}
@media(max-width:800px){.layout{flex-direction:column}nav{position:static;width:auto}}
"""

PAGE = """<!doctype html>
<html lang="sk"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title><style>{css}</style></head>
<body><div class="layout">
<nav>{toc}</nav>
<main>{body}</main>
</div></body></html>
"""


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = Path(sys.argv[1])
    out = (
        Path(sys.argv[2])
        if len(sys.argv) > 2
        else Path("docs/artifacts") / (src.stem + ".html")
    )
    text = src.read_text()
    md = markdown.Markdown(extensions=["extra", "toc", "sane_lists"])
    body = md.convert(text)
    title = next(
        (line.lstrip("# ").strip() for line in text.splitlines() if line.startswith("# ")),
        src.stem,
    )
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(PAGE.format(title=title, css=CSS, toc=md.toc, body=body))
    print(out)


if __name__ == "__main__":
    main()
