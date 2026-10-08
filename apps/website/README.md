# trubbo.app website

Static landing page in three languages: English at `/`, Slovak at `/sk/`, Czech at `/cs/`.
No framework, no web fonts, no external requests. Each page is one self-contained HTML file (about 8 KB gzipped).

## Layout

| Path | What it is |
|------|------------|
| `src/template.html` | Page markup, CSS and the small inline script. Text is `{{key}}` placeholders. |
| `src/screen.html` | The phone screen partial (used once as the sticky screen, and once per step for the stacked fallback). |
| `src/strings/en.json`, `sk.json`, `cs.json` | All visible text, one file per language, same keys. |
| `src/*.png`, `src/favicon.svg`, `src/robots.txt` | Static files copied as is. |
| `build.py` | Generator (Python stdlib only). |
| `public/` | Generated output. This is what Netlify serves. Committed, never edited by hand. |
| `netlify.toml` | Netlify config: publish `public/`, no build command, security headers. |

## Edit text

1. Change the value in all three `src/strings/*.json` files (keys must match across languages).
2. Run `python3 apps/website/build.py`.
3. Commit `src/` and `public/` together.

The build fails loudly on a missing or unused key, on keys that differ between languages, and on a dash (`–`, `—`, spaced `-`) used as punctuation. Keys ending in `_html` may contain inline markup; all other values are HTML-escaped.

Copy rules: `docs/design/copy-style.md` (informal „ty“, „kvíz“ for one quiz run, no dashes, natural Slovak and Czech rather than translated English). Category names and in-app labels match `apps/ios-app/Hangs/Hangs/Localizable.xcstrings`. Demo questions on the phone screen are real questions from the corpus, in each page's language.

## Preview

```sh
python3 apps/website/build.py
python3 -m http.server 8080 --directory apps/website/public
```

## Performance rules (keep them when editing)

The founder dislikes scroll-driven pages, so the story must feel like normal scrolling:

- Native scroll only. No scroll listeners, no scroll-jacking, no smooth-scroll libraries. Steps switch with one `IntersectionObserver`.
- Animate only `transform` and `opacity`.
- `backdrop-filter` only on small elements (the pills, the language hint), with a solid fallback.
- No endless animation offscreen: the voice wave runs only while the screen is visible and the tab is in front.
- `prefers-reduced-motion`: states swap without motion.
- Narrow (under 350 px) or short (under 560 px tall) phones get a plain stacked sequence: no sticky screen, a still screen above each step.

Verified with Playwright on a 390 px viewport under 4x CPU throttling: no long tasks while scrolling, layout shift 0.

## Deploy (Netlify)

1. Netlify: **Add new site** → **Import an existing project** → pick this GitHub repo.
2. **Base directory:** `apps/website`. Leave the build command empty; **Publish directory:** `apps/website/public` (Netlify fills it from `netlify.toml`).
3. Deploy, then **Domain management** → add `trubbo.app` and follow the DNS steps Netlify shows.

Netlify redeploys on pushes to `main` that touch `apps/website/` (the `ignore` rule skips the rest); only the committed `public/` is served, nothing is built on Netlify.
