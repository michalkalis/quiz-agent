# trubbo.app website

Static landing page in three languages: English at `/`, Slovak at `/sk/`, Czech at `/cs/`. Also the legal pages (privacy policy, terms of use, support) at `/privacy`, `/terms`, `/support` and their `/sk/…`, `/cs/…` variants; the iOS app and the App Store listing link to these URLs.
No framework, no external requests. Three self-hosted web fonts, all SIL OFL (licenses in `calistoga-OFL.txt`, `funnel-OFL.txt`, `rethink-sans-OFL.txt`): Calistoga for headings and the demo question (founder 2026-11-03), Rethink Sans ExtraBold for the "trubbo" logo like the app's wordmark, Funnel Sans for everything else. Each page is one self-contained HTML file.

The main call to action is the App Store listing (id 6762482437, local storefront on `/sk/` and `/cs/`, Smart App Banner in Safari); the public TestFlight beta is the secondary link. Both URLs live in `build.py` (`STORE`, `BETA`).

## Layout

| Path | What it is |
|------|------------|
| `src/template.html` | Page markup, CSS and the small inline script. Text is `{{key}}` placeholders. |
| `src/mascot.svg` | The mascot. Also inlined into the hero by `build.py`, eyes wrapped so the page can blink them; the build fails if the eye circles change. |
| `src/app-store-badge.svg` | Apple's official "Download on the App Store" badge. |
| `src/audio/question-<lang>.mp3` | Optional. Trubbo's own voice reading the demo question; while a file is missing, "Hear the question" uses the browser's voice. |
| `src/footer.html` | Footer partial shared by the landing page and the legal pages. |
| `src/strings/en.json`, `sk.json`, `cs.json` | All visible text, one file per language, same keys. |
| `src/legal.html`, `src/legal/<page>.<lang>.html` | Legal page shell and the legal texts (privacy, terms, support), one file per page and language. Written as plain HTML; the `<h1>` becomes the page title. Built to `public/<page>.html`, which GitHub Pages serves at `/<page>`. |
| `src/rethink-sans-*` | Rethink Sans, the app's font. Not used by the site; kept here because the website is the brand source for `apps/social-studio` (`sync-brand.mjs`) and `scripts/brand/mascot_assets.py`. |
| `src/*.png`, `src/*.woff2`, `src/favicon.svg`, `src/robots.txt` | Static files copied as is. |
| `build.py` | Generator (Python stdlib only). |
| `build.py` → `sitemap.xml`, `llms.txt`, JSON-LD | Generated for search engines and AI assistants: the sitemap lists every page with its language alternates, `llms.txt` is a plain summary built from the English strings, the landing page carries schema.org data (publisher, site, app with links to the social accounts). Social accounts live in `SOCIAL_EN` / `SOCIAL_SKCZ` and also render in the footer. |
| `public/` | Generated output. This is what GitHub Pages serves. Committed, never edited by hand. |
| `src/404.html`, `src/CNAME` | Not-found page and the custom domain (`trubbo.app`) for GitHub Pages. |
| `.github/workflows/website.yml` | Builds and deploys `public/` to GitHub Pages. |

## Edit text

1. Change the value in all three `src/strings/*.json` files (keys must match across languages).
2. Run `python3 apps/website/build.py`.
3. Commit `src/` and `public/` together.

The build fails loudly on a missing or unused key, on keys that differ between languages, and on a dash (`–`, `—`, spaced `-`) used as punctuation. Keys ending in `_html` may contain inline markup; all other values are HTML-escaped.

Copy rules: `docs/design/copy-style.md` (informal „ty“, „kvíz“ for one quiz run, no dashes, natural Slovak and Czech rather than translated English). Category names and in-app labels match `apps/ios-app/Hangs/Hangs/Localizable.xcstrings`. The demo question in the hero is a real question from the corpus, in each page's language (`demo.*` keys; the second answer is the correct one).

## Preview

```sh
python3 apps/website/build.py
python3 -m http.server 8080 --directory apps/website/public
```

The local server needs the extension for legal pages (`/sk/privacy.html`); GitHub Pages serves them without it (`/sk/privacy`).

## Performance rules (keep them when editing)

The founder dislikes scroll-driven pages and busy motion:

- Native scroll only. No scroll listeners, no scroll-jacking, no smooth-scroll libraries.
- Animate only `transform` and `opacity`. The mascot only blinks and glances aside (no peeking or sliding), and only while it is on screen and the tab is in front (`IntersectionObserver` + `visibilitychange`).
- The voice wave moves only while the question plays.
- `prefers-reduced-motion`: nothing moves.
- No horizontal overflow at 390 px (the tilted cards behind the question tilt less on phones).

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

## Question topic pages (#223)

`/questions/`, `/sk/otazky/`, `/cs/otazky/` and one page per topic (`/questions/road-trip/`, `/sk/otazky/do-auta/` …): 20 approved questions each, answer in `<details>` (no script), story and source, App Store link with campaign `ct=web_<lang>_<slug>` (App Store Connect → App Analytics → Campaigns). Built by `topics.py` from `src/topics.html`, texts in `src/topics/<lang>.json` (topics pair across languages by `key`; sk and cs share one list, en has its own with general knowledge in place of the country page), questions in `src/topics/questions.<lang>.json`.

Refresh the questions: run `tools/export_questions.py` read-only on the `quiz-agent-api` machine, pick ids per topic, then `python3 tools/topic_snapshot.py <export.json> <picks.json> <lang>` (steps in the script header). The build refuses dashes as punctuation, a question on two pages, a topic under 10 questions or a question without an https source.

Fresh entertainment page (`/questions/fresh/`, `/sk/otazky/cerstve/`, `/cs/otazky/cerstve/`, `fresh.py`): the committed page comes from `src/topics/fresh.<lang>.json` (fallback); the deploy workflow then runs `build.py --fresh-live`, which loads the newest boosted entertainment questions from `/api/v1/public/fresh-questions` (`api.trubbo.app`, then the Fly host) and rewrites only those pages. It runs on every deploy and daily at 06:40 UTC; if the API fails, the fallback stays. Every home page links to it above the headline.

Home entry points (`topics.home`): a "Questions" / "Otázky" link in the header and, between how it works and the price, the first question of each topic marked `"home": true` in `src/topics/<lang>.json` (answer behind a tap) with a link to all questions.

