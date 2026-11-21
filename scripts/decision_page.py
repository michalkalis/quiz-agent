#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown>=3.5"]
# ///
"""Build a local decision page for the founder from a small JSON spec and open it.

Usage:
    uv run scripts/decision_page.py spec.json [--session NAME] [--out FILE] [--no-open]

The founder reads the page, clicks options, presses "Skopírovať odpovede" and
pastes the block back into the session. The agent writes ONLY the spec; layout,
styling and the copy-back logic come from this template (see /decide).

Spec (every text field accepts markdown; only `title` and `questions` are required):
    {
      "title": "Rodinný režim: úvodná obrazovka",
      "summary": "2-3 sentences: what this is about, product level",
      "done": ["what now works", "..."],            # optional, short
      "test": ["what to try in the app", "..."],    # optional
      "questions": [{
        "id": "entry",                               # stable key, echoed in the answers
        "title": "Kde má byť vstup do režimu?",
        "context": "why it matters / what it changes for the player",
        "multi": false,                              # true = more options can be picked
        "options": [{
          "title": "Karta na domovskej obrazovke",
          "desc": "one line of consequence",
          "image": "path/to/screenshot.png",         # embedded into the page
          "html": "<div>inline mockup</div>",        # rendered in an isolated frame
          "height": 420,                             # frame height for `html`
          "recommended": true
        }]
      }]
    }

Session name: --session, else ~/.claude/sessions/$CLAUDE_PID.json (never guessed).
Default output: <main checkout>/docs/artifacts/decisions/<session>-<slug>.html
"""

import argparse
import base64
import html
import json
import mimetypes
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

import markdown

CSS = """
:root{color-scheme:dark;--bg:#12141a;--panel:#1a1d26;--border:#2a2e3b;--fg:#d6dae3;
--dim:#8b93a5;--accent:#6ea8fe;--ok:#3fb950;--pick:#16283f}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:16px/1.55 -apple-system,'SF Pro Text',Segoe UI,sans-serif;padding-bottom:7rem}
main{max-width:1100px;margin:0 auto;padding:2rem 1.5rem}
.session{display:inline-block;background:var(--pick);color:var(--accent);font-weight:700;
border-radius:999px;padding:.15rem .8rem;font-size:.85rem;letter-spacing:.02em}
h1{font-size:1.7rem;margin:.6rem 0 .4rem;line-height:1.25}
.summary{color:var(--dim);max-width:70ch}
.cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:1rem;margin:1.2rem 0}
.box{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:.8rem 1.1rem}
.box h2{font-size:.8rem;text-transform:uppercase;letter-spacing:.06em;color:var(--dim);margin:0 0 .3rem}
.box ul{margin:0;padding-left:1.1rem}
.box p{margin:0;display:inline}
section.q{margin-top:2.4rem;border-top:1px solid var(--border);padding-top:1.4rem}
.q h2{font-size:1.25rem;margin:0 0 .3rem}
.q .num{color:var(--accent);margin-right:.4rem}
.q .ctx{color:var(--dim);max-width:70ch}
.q .hint{font-size:.8rem;color:var(--dim)}
.opts{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:1rem;margin:1rem 0}
.opt{display:flex;flex-direction:column;background:var(--panel);border:2px solid var(--border);
border-radius:14px;padding:.9rem;cursor:pointer;transition:border-color .12s,background .12s}
.opt:hover{border-color:#44506a}
.opt input{position:absolute;opacity:0;pointer-events:none}
.opt:has(input:checked){border-color:var(--accent);background:var(--pick)}
.opt:has(input:focus-visible){outline:2px solid var(--accent);outline-offset:2px}
.opt .head{display:flex;gap:.6rem;align-items:baseline}
.opt .letter{flex-shrink:0;width:1.7rem;height:1.7rem;border-radius:50%;border:2px solid var(--border);
display:grid;place-items:center;font-weight:700;font-size:.85rem;color:var(--dim)}
.opt:has(input:checked) .letter{background:var(--accent);border-color:var(--accent);color:#0b1220}
.opt .t{font-weight:650}
.opt .d{color:var(--dim);font-size:.9rem;margin:.35rem 0 0}
.opt .d p{margin:0}
.rec{margin-left:auto;flex-shrink:0;font-size:.7rem;font-weight:700;color:var(--ok);
background:#12351c;border-radius:999px;padding:.05rem .5rem}
.media{margin-top:.8rem;border-radius:10px;overflow:hidden;background:#0d0f14;
display:grid;place-items:center}
.media img{display:block;max-width:100%;max-height:460px;cursor:zoom-in}
.media iframe{display:block;width:100%;border:0;background:#fff}
textarea{width:100%;background:var(--panel);color:var(--fg);border:1px solid var(--border);
border-radius:10px;padding:.6rem .8rem;font:inherit;font-size:.95rem;resize:vertical}
textarea::placeholder{color:#5d6577}
#bar{position:fixed;left:0;right:0;bottom:0;background:#0d0f14f2;border-top:1px solid var(--border);
backdrop-filter:blur(8px)}
#bar .in{max-width:1100px;margin:0 auto;padding:.8rem 1.5rem;display:flex;gap:1rem;align-items:center}
#progress{color:var(--dim);font-size:.9rem;flex:1}
button{font:inherit;font-weight:700;border:0;border-radius:10px;padding:.65rem 1.3rem;
background:var(--accent);color:#0b1220;cursor:pointer}
button.done{background:var(--ok)}
#out{margin-top:1rem;display:none;font:13px/1.5 ui-monospace,Menlo,monospace}
#zoom{position:fixed;inset:0;background:#000d;display:none;place-items:center;cursor:zoom-out;z-index:9}
#zoom img{max-width:96vw;max-height:96vh}
"""

JS = """
const S = JSON.parse(document.getElementById('spec').textContent);
const KEY = 'decide:' + S.session + ':' + S.slug;
const form = document.getElementById('f');
const saved = JSON.parse(localStorage.getItem(KEY) || '{}');
for (const el of form.elements) {
  if (!el.name) continue;
  if (el.type === 'radio' || el.type === 'checkbox') el.checked = (saved[el.name] || []).includes(el.value);
  else if (saved[el.name]) el.value = saved[el.name];
}
function state() {
  const st = {};
  for (const el of form.elements) {
    if (!el.name) continue;
    if (el.type === 'radio' || el.type === 'checkbox') { if (el.checked) (st[el.name] ||= []).push(el.value); }
    else if (el.value.trim()) st[el.name] = el.value.trim();
  }
  return st;
}
function answers() {
  const st = state();
  const lines = ['Odpovede · ' + S.session + ' · ' + S.title];
  S.questions.forEach((q, i) => {
    const picks = (st['q:' + q.id] || []).map(v => v + ': ' + q.options[v.charCodeAt(0) - 65]);
    const note = st['n:' + q.id];
    lines.push((i + 1) + '. [' + q.id + '] ' + q.title + ' → ' +
      (picks.length ? picks.join(' + ') : note ? '(vlastná odpoveď)' : '(bez odpovede)'));
    if (note) lines.push('   poznámka: ' + note);
  });
  if (st.overall) lines.push('Celkovo: ' + st.overall);
  return lines.join('\\n');
}
function refresh() {
  const st = state();
  localStorage.setItem(KEY, JSON.stringify(st));
  const n = S.questions.filter(q => st['q:' + q.id] || st['n:' + q.id]).length;
  document.getElementById('progress').textContent = 'Zodpovedané ' + n + ' z ' + S.questions.length;
  document.getElementById('out').value = answers();
}
form.addEventListener('input', refresh);
refresh();
document.getElementById('copy').addEventListener('click', async e => {
  const out = document.getElementById('out');
  out.style.display = 'block';
  out.value = answers();
  try { await navigator.clipboard.writeText(out.value); }
  catch { out.select(); document.execCommand('copy'); }
  e.target.textContent = 'Skopírované ✓ vlož do session ' + S.session;
  e.target.classList.add('done');
});
const zoom = document.getElementById('zoom');
document.querySelectorAll('.media img').forEach(img => img.addEventListener('click', ev => {
  ev.preventDefault();
  zoom.firstElementChild.src = img.src;
  zoom.style.display = 'grid';
}));
zoom.addEventListener('click', () => { zoom.style.display = 'none'; });
"""

PAGE = """<!doctype html>
<html lang="sk"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{session} · {title}</title><style>{css}</style></head>
<body><main>
<span class="session">Session: {session}</span>
<h1>{title}</h1>
<div class="summary">{summary}</div>
<div class="cols">{boxes}</div>
<form id="f" onsubmit="return false">
{questions}
<section class="q"><h2>Ešte niečo?</h2>
<textarea name="overall" rows="2" placeholder="Voliteľné: čokoľvek, čo sa nezmestilo do možností"></textarea>
<textarea id="out" rows="8" readonly></textarea></section>
</form>
</main>
<div id="bar"><div class="in"><span id="progress"></span>
<button id="copy" type="button">Skopírovať odpovede</button></div></div>
<div id="zoom"><img alt=""></div>
<script type="application/json" id="spec">{data}</script>
<script>{js}</script>
</body></html>
"""


def md(text: str) -> str:
    return markdown.markdown(text or "", extensions=["extra", "sane_lists"])


def slugify(text: str) -> str:
    ascii_text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", ascii_text.lower()).strip("-")[:60] or "page"


def session_name(explicit: str | None) -> str:
    if explicit:
        return explicit
    pid = os.environ.get("CLAUDE_PID")
    path = Path.home() / ".claude" / "sessions" / f"{pid}.json"
    if pid and path.exists():
        name = json.loads(path.read_text()).get("name")
        if name:
            return name
    sys.exit("Session name not found: pass --session NAME (never guess it).")


def default_out_dir() -> Path:
    """The main checkout, so pages outlive a session's temporary worktree."""
    common = subprocess.run(
        ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    return Path(common).parent / "docs" / "artifacts" / "decisions"


def media(opt: dict, base: Path) -> str:
    if opt.get("image"):
        path = (base / opt["image"]).resolve()
        if not path.exists():
            sys.exit(f"Image not found: {path}")
        mime = mimetypes.guess_type(path.name)[0] or "image/png"
        data = base64.b64encode(path.read_bytes()).decode()
        return f'<div class="media"><img alt="" src="data:{mime};base64,{data}"></div>'
    if opt.get("html"):
        doc = html.escape(opt["html"], quote=True)
        return (
            f'<div class="media"><iframe sandbox srcdoc="{doc}" '
            f'style="height:{int(opt.get("height", 420))}px"></iframe></div>'
        )
    return ""


def question(index: int, q: dict, base: Path) -> str:
    kind = "checkbox" if q.get("multi") else "radio"
    opts = []
    for i, opt in enumerate(q["options"]):
        letter = chr(65 + i)
        rec = '<span class="rec">odporúčam</span>' if opt.get("recommended") else ""
        opts.append(
            f'<label class="opt"><input type="{kind}" name="q:{html.escape(q["id"])}" value="{letter}">'
            f'<span class="head"><span class="letter">{letter}</span>'
            f'<span class="t">{html.escape(opt["title"])}</span>{rec}</span>'
            f'<div class="d">{md(opt.get("desc", ""))}</div>{media(opt, base)}</label>'
        )
    hint = (
        '<div class="hint">Môžeš vybrať viac možností.</div>' if q.get("multi") else ""
    )
    return (
        f'<section class="q"><h2><span class="num">{index}.</span>{html.escape(q["title"])}</h2>'
        f'<div class="ctx">{md(q.get("context", ""))}</div>{hint}'
        f'<div class="opts">{"".join(opts)}</div>'
        f'<textarea name="n:{html.escape(q["id"])}" rows="1" '
        f'placeholder="Poznámka alebo vlastná odpoveď (voliteľné)"></textarea></section>'
    )


def box(heading: str, items: list[str]) -> str:
    if not items:
        return ""
    rows = "".join(f"<li>{md(item)}</li>" for item in items)
    return f'<div class="box"><h2>{heading}</h2><ul>{rows}</ul></div>'


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("spec", type=Path)
    parser.add_argument("--session")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()

    spec = json.loads(args.spec.read_text())
    if not spec.get("title") or not spec.get("questions"):
        sys.exit("Spec needs a `title` and at least one entry in `questions`.")
    ids = [q["id"] for q in spec["questions"]]
    if len(set(ids)) != len(ids):
        sys.exit("Question ids must be unique.")

    session = session_name(args.session)
    slug = slugify(spec["title"])
    out = args.out or default_out_dir() / f"{session}-{slug}.html"
    base = args.spec.resolve().parent
    data = {
        "session": session,
        "slug": slug,
        "title": spec["title"],
        "questions": [
            {
                "id": q["id"],
                "title": q["title"],
                "options": [o["title"] for o in q["options"]],
            }
            for q in spec["questions"]
        ],
    }
    page = PAGE.format(
        session=html.escape(session),
        title=html.escape(spec["title"]),
        css=CSS,
        summary=md(spec.get("summary", "")),
        boxes=box("Čo je hotové", spec.get("done", []))
        + box("Čo vyskúšať", spec.get("test", [])),
        questions="\n".join(
            question(i, q, base) for i, q in enumerate(spec["questions"], 1)
        ),
        data=json.dumps(data, ensure_ascii=False).replace("</", "<\\/"),
        js=JS,
    )
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page)
    print(out)
    if not args.no_open:
        subprocess.run(["open", str(out)], check=False)


if __name__ == "__main__":
    main()
