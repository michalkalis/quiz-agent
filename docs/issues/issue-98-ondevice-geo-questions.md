# #98 — On-device geography questions (MapKit blind maps + vector silhouettes)

**Triage:** enhancement · needs-triage
**Status:** Proposal drafted 2026-07-16 (founder ask — geo image questions; drive-safety "no longer a hard blocker" given partial vehicle autonomy). Approach below is a recommendation; a few product decisions still open (see §7). Run `/prepare-issue` to harden before any agent run.

## 1. Why

Founder wants image-based **geography** questions — country silhouettes ("guess the country by its shape") and blind maps ("which highlighted country/city is this?"). These already exist as a *designed* feature (data model, iOS renderer, opt-in wiring) but are built around **pre-rendered image files**, and it's unverified whether any exist in prod.

This proposal renders those questions **on-device from a bundled public-domain boundary dataset** instead of pre-generating and hosting images. That removes an entire offline pipeline + storage/CDN cost, aligns with our "curated data + deterministic sampling, no LLM on the hot path" preference, and gives crisp, dark-mode-adaptable visuals at any screen size.

## 2. Current state (ground truth)

- **Data model** (`packages/shared/quiz_shared/models/question.py`): `QuestionType` includes `image`; visual carried only as `media_url` (opaque remote URL) + `image_subtype` (free str: `silhouette | blind_map | hint_image`). **No coordinate / ISO / geometry field** — the geography is baked into pixels.
- **iOS** (`ImageQuestionView.swift`): always `AsyncImage(url: media_url)`; subtype changes only the a11y label. Image questions route to `voiceBody` → **answered by voice**. Gate: `hasImage = type==.image && mediaUrl != nil` (`Models/Question.swift:35`).
- **Backend** (`retrieval/question_retriever.py:202`): image type served only when session opts in (`include_images`, default OFF, #68). Wire client→server intact.
- **Home toggle** hidden: `Config.imageQuestionsToggleVisible = false` (setting + wiring kept).
- **Generation** (`apps/quiz-pack-api/app/image_generation/`): `blind_maps.py` / `silhouettes.py` / `hint_images.py` render PNGs (gpt-image-1 for hints; matplotlib-style maps), LLM writes the question text (`silhouette_questions.py`), `r2_uploader.py` pushes to Cloudflare R2 → that URL becomes `media_url`. Off the main CLI path; **city coords live only transiently at gen time**, not on the question.
- **No web-ui app exists** — iOS is the only renderer, so there is no second client to re-implement.

## 3. Proposed approach

Backend serves **structured geographic target** (ISO code / feature id + subtype), not an image URL. iOS draws the visual on-device. Split by subtype:

| Subtype | Renderer | Why |
|---|---|---|
| **silhouette** | SwiftUI vector `Path` from bundled Natural Earth GeoJSON — **NOT MapKit** | MapKit always draws a real map (ocean/terrain); a clean shape-on-blank-background needs a plain vector polygon. No map key, no attribution. |
| **blind_map** | **MapKit** — SwiftUI `Map` + `MapPolygon` (live) or `MKMapSnapshotter` + Core Graphics (static, glance-friendly) | Real geographic context is exactly what a blind map wants. Free, keyless. |
| **hint_image** | unchanged (`media_url` / R2) | Real photos aren't geometry; out of scope here. |

- **Answer path unchanged** — voice (fits the driving vision); MCQ optional. No tap-the-map (conflicts with driving; see §7).
- **Making a MapKit map "blind":** `MKStandardMapConfiguration.pointOfInterestFilter = .excludingAll` strips POIs; target region highlighted via a filled `MapPolygon`/`MKPolygon`. (Standard config still shows some place labels — for fully label-free we use the vector path or satellite config; see sources.)

## 4. Prior art & data sources (cited)

- **Dominant approach for outline/silhouette quizzes is vector (SVG/TopoJSON), not raster tiles** — Seterra "Country Outlines", JetPunk/Mappr "guess by shape". Raster tiles only for imagery-guessing (GeoGuessr, a different mechanic). Our plan matches the category.
- **Natural Earth** boundary data — **public domain / CC0**, no attribution/redistribution friction, commercial OK; Admin-0 (countries) + Admin-1 (states) at 1:110m / 1:50m / 1:10m, ISO codes on each feature. World Admin-0 at **110m ≈ 689 kB GeoJSON** (smaller as TopoJSON); per-country extracts are a few KB. 110m is plenty for silhouettes. [terms](https://www.naturalearthdata.com/about/terms-of-use/) · [GeoJSON mirror](https://github.com/nvkelso/natural-earth-vector)
  - Avoid **GADM** (non-commercial only). **geoBoundaries** (CC-BY) is the fallback if finer admin-1 detail is needed. OSM-derived = ODbL share-alike (heavier compliance).
- **MapKit is free, no key** for native use; rate-limited "at user speed". **Apple logo + Legal label must stay visible** on any MapKit-rendered surface (factor into a glance UI). Not applicable to our vector silhouettes. [is-MapKit-free](https://lemon.io/answers/mapkit/is-mapkit-free-to-use-for-commercial-applications/) · [logo rule](https://forums.developer.apple.com/forums/thread/761565)
- **MapKit specifics:** `MKMapSnapshotter` renders a static map to a `UIImage` (UIKit, async, background queue) but **does not draw your overlays** — draw the polygon yourself in Core Graphics via `snapshot.point(for:)` (`MKOverlayRenderer` mis-scales on snapshots). SwiftUI `Map` (iOS 17+) supports `MapPolygon` overlays live but **cannot snapshot**. [MKMapSnapshotter](https://developer.apple.com/documentation/mapkit/mkmapsnapshotter) · [MKGeoJSONDecoder](https://developer.apple.com/documentation/mapkit/mkgeojsondecoder) · [NSHipster](https://nshipster.com/mktileoverlay-mkmapsnapshotter-mkdirections/)
- **Vector silhouette libraries (both MIT):** [FeatureShapes](https://github.com/mpiannucci/FeatureShapes) (GeoJSON `Feature` → SwiftUI `Shape`, closest fit) and [GeoProjector](https://github.com/maparoni/GeoProjector) (native projections + CGContext/SVG). Pattern: project lon/lat → `CGPoint`, build `Path`, scale-to-fit bbox + center + flip Y.
- **Projection:** for a single isolated country, **equirectangular** (lon=x, lat=y) after scale-to-fit reads fine; Mercator badly distorts area. Use the **same projection for both subtypes** for visual consistency.

## 5. Architecture changes

1. **Shared model** (`packages/shared`): add a structured `geo_target` field to `Question` — ISO 3166 country code (silhouette) or region/feature id + optional center coordinate (blind_map). `media_url` stays (hint_image + fallback); `image_subtype` stays. Update `from_dict` + iOS `Codable`.
2. **iOS renderers:** new `SilhouetteView` (vector `Path`) and `BlindMapView` (MapKit); route by `image_subtype` inside/replacing `ImageQuestionView`. Update `hasImage` to trigger on `geo_target` too (not just `media_url`). Bundle the Natural Earth file (~689 kB) in the app.
3. **Backend generation** (`quiz-pack-api`): a data-only path that emits geo questions (subtype + geo_target + answer + options) from a curated country/city allow-list — **no PNG render, no R2 upload, no gpt-image-1**. Reuses the admin create path (already writes `image_subtype`). Question text can be a fixed template ("Which country has this outline?") — no per-question LLM needed.
4. **Retriever:** unchanged — still gated on `include_images`; question just carries `geo_target` instead of `media_url`.
5. **Home toggle:** re-expose (`imageQuestionsToggleVisible = true`) — pending §7 decision on default.

## 6. Scope / phases (agent-effort, not calendar)

1. **Data foundation** — bundle Natural Earth, add `geo_target` to shared model + iOS Codable, pick projection, curate country/city allow-lists.
2. **Silhouette renderer** — vector `Path` (higher value, simpler, no MapKit). Ship first.
3. **Blind-map renderer** — MapKit (`Map`+`MapPolygon`, or snapshotter for glance UI).
4. **Backend data-gen path** — emit geo rows, import a first batch to prod, verify retrieval e2e with `include_images`.
5. **Toggle + on-device founder check** — re-expose, confirm default, device walkthrough.

Silhouette (phases 1–2) is a self-contained first increment that delivers value without any MapKit work.

## 7. Open product decisions (need founder input)

1. **Answer mode** — voice only (current, fits driving), add MCQ, or tap-the-map (breaks hands-free)? *Rec: voice + optional MCQ; no tap.*
2. **Drive-safety default** — founder relaxed the blocker. Re-expose the toggle: default **OFF (opt-in)** or **ON**? *Rec: re-expose, keep default OFF for now.*
3. **Scope** — geo-only (silhouette + blind_map) this issue; hint_image stays on R2. *Confirm.*
4. **Existing pre-rendered geo questions** — recon suggests likely none in prod → clean slate, no migration. *Confirm; if some exist, retire vs keep both paths.*
5. **Disputed-borders POV** — Natural Earth encodes de-facto borders + per-country POV variants; pick one consistent policy (political sensitivity).

## 8. Tradeoffs

- **Cost win (Rule #11):** eliminates gpt-image-1 + LLM question-writing + R2 storage/CDN/bandwidth for geo subtypes; one ~689 kB bundled file yields unlimited geo questions. No LLM on the generation hot path.
- **Cost:** backend sends structured geo-data instead of a URL (small API-model change); ~0.7 MB app-size increase; two new iOS renderers to build + maintain.
- **Risk / pitfalls:** tiny/island microstates unrecognizable as silhouettes → **curate an allow-list**; disputed borders → POV policy; MapKit async threading + manual CG overlay draw + **cache the snapshot per question** (moving vehicle); keep Apple logo/Legal visible on MapKit surfaces.

## 9. Links

- Current image infra: #68 (image render + toggle), `image_subtype`/`media_url` in `packages/shared/quiz_shared/models/question.py`
- Product vision (voice-first, driving): `CONTEXT.md`
- Related: #97 (CarPlay) — geo visuals only make sense on a passenger/head-unit surface
