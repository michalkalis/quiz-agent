# QA root cause: defects in `approved` prod questions (2026-10-25)

Read-only: prod via `fly ssh` + asyncpg `transaction(readonly=True)`, SELECT only; repo read only.
Paths: `qpa/` = `apps/quiz-pack-api/app/`, `fv` = `qpa/verification/fact_verifier.py`, `vs` = `qpa/orchestrator/stages/verification.py`, `nc` = `qpa/generation/naturalness_check.py`, `ma` = `qpa/scoring/machine_approval.py`.

**The short version:** the pipeline fact-checks the **answer** and nothing else. The **explanation** is never shown to any checker. The sk/cs language check reads only the **question stem**. It ran only *after* approval and is not one of the approval gates. Separately, 145 older EN rows were approved with no gate at all.

## 0. Dropped (not real defects)
- `9bd651a8` Pohoda: the "+10 % capacity, 30th edition" claim is TRUE (pohodafestival.sk "30,000 tickets sold out, festival capacity increased by 10%"; the verifier cited that page). The only gap is that the stored `source_url` (Wikipedia) doesn't carry it.
- `c90959f3` korbáč: the folk-belief line (whipping passes on the spring vitality of the willow) is standard ethnography. It is only missing from the cited page. Not a defect.

## 1. Confirmed defects (18)
Approval paths: **M** = machine `gates-v1` at import. **L** = legacy import, `reviewed_by` NULL, no gate. **H** = founder rating. Model is the generator. vs = `verification_score`.

| id | kind | approved via / date / model | stage that should catch | why it didn't | evidence |
|---|---|---|---|---|---|
| 41b7bf47 Star Wars | wrong title in the stem; the real title contains the answer | L 09-02, fable-5 fact_first | fact-check (stem asserts something false) | The verifier *noticed* it: its notes say "official title is 'Star Wars: Maul – Shadow Lord'". It still returned ok/high because it judges whether the answer is right. Imported with a forced status, so no gate ran | provenance `verification_notes`; `fv:98-113` |
| 932f7686 Harry Styles | wrong album name in the explanation | L 09-02, fable-5 fact_first | fact-check + source | The source excerpt is a fragment: "Occasionally (2026), featured…" is cut out of the title "Kiss All the Time. Disco, Occasionally". The generator copied the fragment and the explanation was never checked | `source_excerpt`; naive `split(". ")` `qpa/sourcing/wikipedia_source.py:140` (likely mechanism) |
| d4962854 Yale | false claim in the explanation ("completely unrelated") | M 10-15, opus-5-5 direct | fact-check | The verifier only received stem + answer ("so 'False' is correct") | `vs:107-115` payload has no explanation |
| 6a737928 Hromnice | explanation contradicts its source ("takmer presne" vs "ne moc přesně", +1h20) | M 10-14, opus-5-5 | fact-check | Explanation never sent. vs 0.7: the verifier "could not open a Slovak source" and still said ok | `vs:107-115`; `fv:78` |
| 85cad3c7 Maine | understatement ("several hundred km"; the gap is ~1,500 km) | M 09-10, fable-5 | fact-check | Explanation never sent | `vs:107-115` |
| a3e88337 elephant | explanation says 40,000; its own excerpt says 150,000 | H 09-03 (10/10), fable-5 | fact-check / excerpt consistency | Explanation never sent; the founder rated fun, not facts | `source_excerpt` vs explanation |
| 7a483f8b pyramids | `source_url` is an unrelated Roman-empire page | L 08-01, pixtral (Bedrock) | source verification | Old Tavily+arbiter verifier ("5/5 sources confirm"; #166 measured 0/6 recall). Default-approved import, never re-gated | provenance `verification_notes` |
| 534619bc croc tears | wrong cause (the study blames air forced through the sinuses) | M 10-14, opus-5-5 | fact-check | Explanation never sent | `vs:107-115` |
| 6bb25426 paradajka (minor) | explanation contradicts the cited Duden entry (Paradeis, not "skrátený Paradiesapfel") | M 10-14, opus-5-5 | fact-check | Explanation never sent; vs 0.7 | `fv:78`; `ma:58` |
| 8a441eeb wood splitting | claim rests on a forum thread with mixed opinions | M 10-14, opus-5-5 | source quality + confidence gate | vs **0.5**; notes say "anecdotal forum posts, some dissent". 0.5 = the verifier's lowest-confidence "ok" and it passes. No source-quality rule | `fv:78,377-379`; `ma:58,133`; `fv:434-447` accepts any http URL |
| d4d813af potatoes | answer "sladkými" no longer fits the stem "Aké budú?" | M 10-14; stem rewritten **10-23 after approval** | rewrite must re-check the answer | `apply_rewrite` swaps only the stem; the answer and the gates were never re-run | provenance `naturalness.applied_by=founder-pairs-round2`; `nc:148-178` |
| c2fc5499 barber | "Oprava fúzov" should be "Úprava" (explanation) | M 10-14 | sk/cs language check | No language check existed when it was approved; the later check reads the stem only | `nc:6-7`, `nc:213` |
| 300aafa6 P+R | stray fragment "ďalej MHD" + a dev/staging source URL | M 10-14 | text hygiene + language + source | Fragment is raw generator output (`docs/testing/runs/topics-pilot-2026-10-14/N-5.json`). Nothing reads the explanation; no host check | `nc:213`; `fv:434-447` |
| bbac6ab1 rebarbora | "vyhadzujú dobrým dôvodom" is missing "s" (explanation) | M 10-14 | language | Stem only | `nc:213` |
| bd8aa2d7 bocian | "drevená rapkáč" should be "drevený" (explanation) | M 10-14 | language | Stem only | `nc:213` |
| e1d3a1f7 zabijačka | answer "maso nezkazí" is missing "se" | M 10-14 | language | The answer field is never language-checked | `nc:213` |
| 4bb75d5b štamgast (style) | clumsy last sentence with no subject (explanation) | M 10-15 | language | Stem only | `nc:213` |
| 8f0a53b1 svařák | "prodává" is the wrong verb + the source is a VWR product page | M 10-15, vs 0.7 | language + source quality | Stem only; any URL accepted; vs 0.7 passes | `nc:213`; `fv:434-447` |

Every row passed the approval gate in the state it was in at the time. The gates themselves are blind to these failure types.

## 2. Root causes, ranked by how many defects they explain
1. **The fact-check scope is (stem, answer) and never includes the explanation: 9 defects** (Yale, Styles, Hromnice, Maine, elephant, croc, paradajka, svařák fact part, partly Star Wars).
   - `vs:107-115` sends `question`, `correct_answer` and `topic` only.
   - The prompt says "find problems with a question-answer pair" (`fv:98`).
   - The source excerpt is the verifier's evidence for the answer (`vs:251-258`). It is never compared with the explanation, even when the row contradicts itself (elephant: 40k vs 150k).
   - The verifier tends to pass a correct answer even when it saw a false claim in the stem (Star Wars).
2. **The sk/cs language check never read the answer or the explanation, and was never an approval gate: 7 defects** (barber, P+R, rebarbora, bocian, zabijačka, štamgast, svařák).
   - Native rows "had no language check at all" (`nc:6-7`). The check was added on 10-22 (commit 5bf453be). All 823 native approvals happened 10-08..10-21, before it existed.
   - It reads only `q.question` (`nc:213`).
   - Its verdict is not part of the approval rule (`ma:100-145`).
   - In the importer, approval is decided first (`qpa/corpus/importer.py:213-215`). The naturalness check and the stem autofix run afterwards (`importer.py:352-366`).
3. **No source-quality or confidence floor: 4 defects** (wood, svařák, P+R, Hromnice).
   - An "ok" with **low** confidence maps to 0.5 and passes, because the bar is `score < 0.5` (`fv:78`, `ma:58,133`).
   - Any http URL is accepted (forum, product page, `*.dev.*`) (`fv:434-447`).
   - Our code never fetches the source and never checks that the excerpt is verbatim. The URL and the excerpt are both the verifier LLM's own output.
4. **Legacy approvals that never went through a gate: 3 defects** (pyramids, Star Wars, Styles).
   - Before PR #81 (08-28) the importer stamped `approved` by default. A forced `--review-status approved` approves every row with no `reviewed_by`.
   - No re-gating happened when `gates-v1` arrived on 09-10.
5. **Edits after approval with no re-validation: 1 defect** (potatoes), but a systemic hole.
   - `check_naturalness.py --apply` rewrites stems of rows that are already approved (`nc:148-178`).
   - Approval is not tied to the exact text that was checked.
- Contributing:
  - Session runs map the fact-check role gpt-5-mini to **session:sonnet** (`packages/shared/quiz_shared/llm/factory.py:301-311`). The 10-14 logs show "verifying session:sonnet". Memory 09-02: sonnet 5/7 vs opus 6/7 recall.
  - Fact-first sourcing splits text on ". " (`wikipedia_source.py:140`).
  - The founder's rating (H) scores fun, not accuracy, but it sets `approved`.
  - Audit gap: `reviewed_at` precedes `created_at` on many 10-14 rows (one timestamp per import run vs per-row creation time), so the approval history can't be fully reconstructed.

## 3. Blast radius (prod, approved, `pack_id IS NULL`; read-only counts)
- Approved corpus: en 696 · sk 413 · cs 410 = **1,519**. **100 % carry an explanation that no checker ever read.** Another **644** approved sk/cs translations of approved EN rows (sk 325, cs 319) inherit those unchecked explanations. The translation judge checks faithfulness to the English, not truth.
- Native sk/cs: **823/823** approved before any language check. The answer and explanation have never been language-checked. Stem check, after the fact:
  - 105 stems flagged (sk 63, cs 42).
  - **96 stems rewritten after approval** with no re-check (sk 56, cs 40).
  - **9 still flagged and serving** unfixed (sk 7, cs 2).
- Weak verifier confidence, approved anyway: **316** rows (vs 0.7: en 75, sk 108, cs 125; vs 0.5: sk 1, cs 3).
- Legacy EN with no reviewer stamp: **145** (07-10: 31 Opus 4.8; 08-01: 10 pixtral; 08-18: 84; 09-02: 20 forced).
  - **84 have no verification record at all** (08-18: Fable direct 65, Fable entertainment 14, kimi 5).
  - 125 lack `factcheck_tier=web`.
- Weak source hosts (regex lower bound: forum, product page, dev host, listicle): 7 (sk 4, cs 2, en 1). The real number is higher; nothing fetches or classifies sources.
- `usage_count` is 0 on every row, so player exposure can't be measured from the DB.

## 4. Proposed structural fixes (no code)
1. Fact-check the whole player-visible item (stem, options, answer, explanation) against the cited source, claim by claim. Any unsupported claim is a finding.
2. Our code fetches the source page itself, confirms the excerpt is on the page verbatim, and confirms the page supports the explanation's numbers and names (a deterministic check plus the verifier).
3. Raise the approval bar: high-confidence "ok" only (0.9). Add a source-quality allowlist/denylist (no forums, product pages, dev/staging hosts, listicles).
4. sk/cs language gate over every visible field (stem, answer, options, explanation), run **before** approval and part of the approval rule. Bump the gate version to `gates-v2`.
5. Tie approval to a content hash of the exact checked text. Any edit (rewrite, autofix, house style) drops the row to pending until the full gate set passes again.
6. Re-gate the whole approved corpus under `gates-v2`, starting with the 145 legacy EN rows, the 316 low-confidence rows and the 96 rewritten rows. Demote failures to `pending_review`.
7. Deterministic text hygiene: stray trailing fragments, and the case of the answer matching the question word ("Aké?" needs a nominative answer).
8. Pin the fact-check model, with no silent downgrade to session:sonnet. Any swap needs eval data first.
9. Store the founder's fun rating separately from accuracy approval. A fun rating must not set `approved` without the gates.
10. Remove the forced `--review-status approved` import path, or require it to run the gates.
