#!/usr/bin/env python3
"""Append an Obsidian-wikilink "Súvisiace issues" footer to each issue file.

Builds issue->issue edges from the bare `#NN` cross-references already present in
each file's prose, so Obsidian's graph view shows the real dependency graph.
Idempotent: the footer lives between HTML-comment markers and is regenerated on
every run. Original `#NN` anchors in the body are never touched (git-anchor rule).

Precision rules:
- Titles + canonical slug per issue number come from INDEX.md (authoritative).
- Only `#NN` with NN >= MIN_ISSUE_EDGE counts as an edge. Issues #1-#21 are all
  done early work and are never current dependency targets, while `#1`-`#11` are
  heavily reused in prose as decision/step/hole markers ("launch decision #4",
  "§8b #2") -- this cut removes that enumeration noise.
"""
from __future__ import annotations
import re
from pathlib import Path

ISSUES = Path("docs/issues")
INDEX = ISSUES / "INDEX.md"
START = "<!-- obsidian-links:start -->"
END = "<!-- obsidian-links:end -->"
MIN_ISSUE_EDGE = 22


def short_title(raw: str) -> str:
    return raw.split(":")[0].split("(")[0].split("—")[0].strip()


# 1. Map issue number -> (slug, title) from INDEX.md link rows.
num_to_slug: dict[int, str] = {}
num_to_title: dict[int, str] = {}
for title, slug, num in re.findall(
    r"\[([^\]]+)\]\((issue-(\d+)[^)]*)\.md\)", INDEX.read_text(encoding="utf-8")
):
    num = int(num)
    if num not in num_to_slug:  # first occurrence in INDEX = canonical
        num_to_slug[num] = slug
        num_to_title[num] = short_title(title)

# 2. For each file, collect referenced issue numbers and (re)write the footer.
touched, total_edges = 0, 0
for f in sorted(ISSUES.glob("issue-*.md")):
    m = re.match(r"issue-(\d+)", f.stem)
    self_num = int(m.group(1)) if m else None
    text = f.read_text(encoding="utf-8")
    body = text.split(START)[0].rstrip()  # drop any prior footer

    refs = {int(n) for n in re.findall(r"#(\d+)", body)}
    refs = {n for n in refs if n >= MIN_ISSUE_EDGE and n in num_to_slug and n != self_num}
    if not refs:
        if START in text:  # had a footer, now has no edges -> strip it
            f.write_text(body + "\n", encoding="utf-8")
        continue

    links = " · ".join(
        f"[[{num_to_slug[n]}|#{n} {num_to_title[n]}]]" for n in sorted(refs)
    )
    footer = f"\n\n{START}\n## Súvisiace issues\n{links}\n{END}\n"
    f.write_text(body + footer, encoding="utf-8")
    touched += 1
    total_edges += len(refs)

print(f"footer written to {touched} issue files · {total_edges} edges total")
