# Issue #206 — Voľba „bez lokálnych otázok“

**Triage:** enhancement · ready-for-agent

**Created:** 2026-10-15 · **Founder:** Michal

## Goal

Next to category and difficulty, the player can choose to skip **local questions**: ones that only make sense to people from one country or city (Bratislava public transport, the Czech card game prší, a domestic TV show). Default stays as today: local questions **included**; the player opts out.

Success = every question in the corpus carries a "local" label, every newly generated question gets it the same way, and a player who turns local questions off gets none in a round.

## Founder decisions (2026-10-15)

1. Default: local questions **included** (native sk/cs home-country share was deliberate, see #203 — boring stock questions: cause and replacement). The player can switch them off.
2. New questions must be labelled from now on. Labelling them **the same way** as the existing corpus is fine, nothing special at generation time.
3. Issue first; order and timing decided by the agent run.

## Current state (2026-10-15)

- No "local" label on questions. Retrieval filters only difficulty, type, review status, language, category and `language_dependent` (#128 — idiom questions break in translation).
- Native sk/cs generation deliberately includes a home-country share (prompt builder, `_HOME_COUNTRY`), so most local questions are in the sk/cs corpus. The English corpus is told to stay universal, so few local rows there.
- A close cousin exists: the **regional classifier** from #168 (batch translation SK/CS), `apps/quiz-pack-api/app/translation_verification/regional.py`. It asks "is this English question foreign-specific for a Slovak/Czech player", is used only on translations, and its result sits in the translation review blob. It never affects which questions a player gets. Different question from ours (ours includes the player's *own* country), so reuse its shape, not its prompt.

## Approach

One classifier, one label, applied in two places, so old and new rows are labelled identically (decision 2):

- **Label:** `local_scope` on the question: `null` = universal, otherwise the country it is tied to (ISO code, e.g. `sk`, `cz`, `us`). The country, not just a yes/no, so a later "keep my own country's local questions, drop foreign ones" needs no relabel. The player-facing switch only checks "is set".
- **What counts as local:** answering depends on knowledge that people from one country (or one city/region) have and others generally do not: city transport, domestic TV/radio, local politicians, domestic leagues, national holidays, school-curriculum facts, regional customs and games. **Not local:** world history, geography, science, globally known culture, even if it originated in one country (Škoda, Kafka, Ice hockey world cup).
- **Classifier:** cheap model (Haiku class), one short call per question, strict JSON `{local_scope, reason}`, shape of `regional.py`. Fail-safe = unlabelled (universal) with the reason recorded, same direction as #168: a missing label must never block or drop a row.
- **Spot check before the full run:** 50 rows (20 sk, 20 cs, 10 en) shown to the founder as a short list with the classifier's verdict and reason; fix the prompt until the founder agrees, then run everything.

## Sub-tasks

- [ ] **206.1 Data.** New nullable column `local_scope` on questions (quiz-pack-api migration via Fly release command) and the matching metadata on the quiz-agent side, carried through every path that copies `language_dependent` today (model ↔ dict, admin import, serializers). Additive only: the live 1.0 app must keep working.
- [ ] **206.2 Classifier.** `local_scope` classifier module + prompt + tests that encode the boundary (Bratislava MHD → `sk`; prší → `cz`; Kafka → universal; US state capital → `us`). Model choice per the Max API credit rule (#196 — AI calls through the Anthropic API).
- [ ] **206.3 Backfill.** Script that labels every row without a label, resumable, cost logged. Spot check first (above), then full run on prod. Estimated cost of the full run reported up front; above ~$3–4 ask the founder first.
- [ ] **206.4 New questions.** Run the same classifier on every newly stored question in all generation paths that write to the shared corpus: corpus runs / import, the weekly fresh entertainment job (#202), any native sk/cs generation. Simplest robust point: where a question row is created/approved, not inside each prompt. Custom packs (private, user-ordered) are out of scope. Test: a newly generated question ends up labelled.
- [ ] **206.5 Retrieval.** Session preference "skip local questions" (default off = include). When on, retrieval adds `local_scope IS NULL`. Check the stock guard (#199 — question stock + Trubbo Plus) still counts correctly when the filter shrinks the pool.
- [ ] **206.6 iOS.** Switch next to category/difficulty in quiz settings, sk/cs/en copy (short, no dashes, copy-review CI). Sent with the session start; older app versions simply never send it. Exact placement and wording → show the founder 2 HTML variants first (UI rule).

## Done when

- All approved + pending rows labelled; spot check signed off by the founder; numbers per language (how many local) reported.
- A newly generated question is labelled without a manual step.
- Backend tests green (targeted suites), deployed; iOS unit test for the setting green; simulator screenshot of the switch (iPhone 18 Pro, sk).
- PRs merged through the normal flow on `main`. **No TestFlight build** unless the founder asks.
