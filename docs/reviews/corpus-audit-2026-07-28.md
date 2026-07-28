# Full-corpus screen — language portability + correctness (2026-07-28)

Closes the founder task "full-corpus screen" filed after the 2026-07-28 TestFlight field test
(see [[issue-128-idiom-questions-break-in-translation]]). Scope: **every** question row in both
deployed environments, not a sample.

## Inventory

| Env | Fly app / DB | Rows | approved | archived |
|-----|--------------|------|----------|----------|
| staging | `quiz-agent-api-staging` / `quiz_pack_staging` | 596 | 592 (was 596) | 4 (was 0) |
| prod | `quiz-agent-api` / `quiz_pack` | 596 | 31 | 565 (was 565) |

Prod's 31 approved rows are a **byte-identical subset** of staging's 596 (same ids, question text,
answers and options — verified before any write), so one screen covered both. Prod's approved count
is unchanged because all four newly-archived rows were already inside prod's 565-row archive from
the 2026-07-26 cull; the archive flags were still applied there to keep the two corpora in sync.

## Method

15 audit agents, ~40 questions each, every question read in full on two axes:

- **Portability** — does the fact survive literal translation into Slovak? (wordplay, spelling and
  letter-count facts, anagrams, English collective nouns, imperial units for a metric audience)
- **Correctness** — is the answer factually right and precise, does it exactly match one option for
  multiple-choice rows, is only one option defensible, are the accepted spoken variants right?
  Suspicious facts were checked against live sources.

Findings were then re-checked at top level against the actual stored rows before any write — which
mattered: see *Rejected / corrected* below. Both databases were exported to JSON first as a rollback
baseline.

## Result

**50 distinct defects found; 48 applied, 2 rejected.** Same fix applied to both environments.

| Class | Count | What changed |
|-------|-------|--------------|
| Wrong or unsupported fact | 21 | question / answer / explanation corrected |
| Not portable → `language_dependent = true` | 11 | excluded from non-English sessions |
| Imperial units → metric | 7 | question, answer or explanation rewritten in metric |
| Accepted spoken answers wrong or missing | 5 | `alternative_answers` corrected |
| Archived (not fixable by editing) | 4 | `review_status = archived` + reason in `review_notes` |
| Over-flagged → `language_dependent = false` | 1 | returned to non-English sessions |
| Broken multiple-choice options | 1 | second defensible distractor replaced |

`language_dependent` rows: 8 → 18.

### Archived rows

- "Buried in three countries simultaneously" — self-contradictory and unsupported by its own source.
- "Library that shelves books by colour → Stockholm" — no source supports Stockholm; answer appears fabricated.
- Instagram-vs-Apollo code size — the stored answer ("about 7 times") matches none of the three options the question offers.
- "Humans share 50% of DNA with a banana" — contradicted two other corpus questions that both answer 60%.

### Rejected / corrected at top level

Three agent proposals would have introduced new defects and were overruled after checking the raw rows:

- Neutron-star teaspoon question — flagged as wrong; the stored answer is in fact correct for the
  options offered. No change.
- Catullus / teeth-whitening — the proposed rewrite asked "which Iberian people?" while the stored
  answer is "Urine", which would have broken the question. Rewritten to fix the false "Romans"
  premise while keeping the answer valid.
- "Bird that sleeps in flight" — the proposed rewrite asserted unihemispheric sleep for the Alpine
  swift, which is documented for frigatebirds; the claim was dropped and the question disambiguated
  by flight duration instead.

A "Monopoly was banned in the USSR" flag was left alone — disputed, but the agent offered no
better-sourced replacement.

### Follow-up sweep

A deterministic regex sweep over all approved rows (imperial units, spelling/anagram/collective-noun
markers) found no further defects: every remaining imperial figure is either a parenthetical after
the metric value or an accepted spoken variant, both of which are intended.

## Admin key conflict — fixed

The long-standing blocker (neither `.env` key authenticated against staging) had two causes, both now resolved:

1. `.env` declared `ADMIN_API_KEY` **twice**; the second line silently shadowed the first, so every
   admin script sent the quiz-pack-api key to quiz-agent and got 401. The second entry is now
   `QUIZ_PACK_ADMIN_API_KEY`, and `.env.example` documents the one-name-one-value rule.
2. The staging Fly secret held a third, unknown value. It was reset to the canonical `.env` value.

Both environments now authenticate with the single `ADMIN_API_KEY` from `.env` (verified 200 against
the admin stats endpoint on staging and prod).

## Do the edits actually reach clients?

Yes, with no redeploy or machine restart. Verified against the code:

- The retrieval layer holds **no cache** — `QuestionRetriever` and `PgvectorQuestionStore` issue a live
  `SELECT` per call, so the next question served is the corrected row.
- The TTS cache is keyed on `sha256(text:voice)` (`apps/quiz-agent/app/tts/cache.py:120-131`), so changed
  question wording produces a new key: fresh audio is synthesised and the old clip is simply orphaned on
  the volume. No stale narration.
- Answer grading re-fetches the question at answer time (`apps/quiz-agent/app/quiz/flow.py:114`), so it
  always uses the corrected answer key.

One nuance, harmless here: a session that was **already mid-question** when the edit landed keeps the old
wording for that one question, because `current_question_text` is snapshotted onto the session
(`packages/shared/quiz_shared/models/session.py:92-93`) and write-through-persisted, so a restart would not
clear it either. Grading for that question would use the new answer key against the old spoken text. Prod
has no users beyond the founder and staging is beta-only, so no real session was exposed; sessions pick up
the correction on their next question.

## Rollback

Full pre-change exports of both databases exist for the session; per-row rollback is also possible
from git history of this document plus the `review_notes` reason strings. Archived rows are
restorable via `POST /api/v1/admin/questions/review-status` with `status: "approved"`.
