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
| `public/` | Generated output. This is what GitHub Pages serves. Committed, never edited by hand. |
| `src/404.html`, `src/CNAME` | Not-found page and the custom domain (`trubbo.app`) for GitHub Pages. |
| `.github/workflows/website.yml` | Builds and deploys `public/` to GitHub Pages. |

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

## Deploy (GitHub Pages)

Deploy = merge to `main`. The `website` workflow runs on every push to `main` that touches `apps/website/` (or by hand via **Actions → website → Run workflow**). It runs `build.py`, fails if the committed `public/` differs from the sources, and publishes `public/` to GitHub Pages.

### One-time setup

1. Repo **Settings → Pages → Build and deployment → Source:** choose **GitHub Actions**.
2. Recommended first: **your profile Settings → Pages → Add a domain** `trubbo.app` and add the TXT record GitHub shows, so the domain is verified to this account.
3. DNS at the registrar of `trubbo.app`:

| Host | Type | Value |
|------|------|-------|
| `@` | A | `185.199.108.153` |
| `@` | A | `185.199.109.153` |
| `@` | A | `185.199.110.153` |
| `@` | A | `185.199.111.153` |
| `@` | AAAA | `2606:50c0:8000::153` |
| `@` | AAAA | `2606:50c0:8001::153` |
| `@` | AAAA | `2606:50c0:8002::153` |
| `@` | AAAA | `2606:50c0:8003::153` |
| `www` | CNAME | `michalkalis.github.io` |

   No wildcard record. GitHub then redirects `www.trubbo.app` to `trubbo.app`.
4. Run the workflow once (or merge), then **Settings → Pages → Custom domain:** `trubbo.app` → Save. When the DNS check passes, tick **Enforce HTTPS** (the certificate can take a while to be issued).

Records from GitHub's docs: "Managing a custom domain for your GitHub Pages site".
