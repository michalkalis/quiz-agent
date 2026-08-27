# Fact-check provider comparison — #166 D21b (2026-08-26)

Founder ask 2026-08-26: nájsť lacnejšiu alternatívu k Anthropic native
web-search fact-checku (prod Sonnet 5: recall 5/7 @ ~18 ¢/q, Haiku 4.5:
4/7 @ 6,9 ¢/q). Všetky testy na 20q D21b sade (7 founder-potvrdených chýb
+ 13 kandidátov, produkčný adversarial prompt
`app.verification.fact_verifier._PROMPT_TEMPLATE`).

Harnessy: `apps/quiz-pack-api/scripts/openai_native_eval_166.py`
+ `scripts/gemini_native_eval_166.py`. Výsledky (JSONL):
`docs/testing/runs/d21b-round-2026-08-18/factcheck-eval-166/native_openai_*.jsonl`
+ `native_gemini_*.jsonl`.

## Výsledky (20q sada)

- **OpenAI gpt-5-mini + Responses web_search: recall 7/7, 5,0 ¢/q**
  (0,25/2 USD/M + $10/1k searches, Ø 4,15 searchov/q) — prvá metóda vôbec
  s plným recallom, chytila aj q63 (tabuľkový fakt) aj q95. Flagy mimo
  referencie: 7, z toho q77+q91 sú founder-potvrdené chyby a q73 potvrdená
  ambiguita (verdikty 2026-08-26), q45 data bug, q37 needs-rewording →
  čisté FP len 2 (q28, q76).
- **gpt-5.4-mini: 2/7 — nepoužiteľný** (a 3× drahšie tokeny k tomu).
- **Gemini 3.5 Flash + Google Search grounding: recall 6/7, ~1,9 ¢/q
  nominálne** (0,75/3,75 USD/M promo + $14/1k grounded requestov; free
  tier 5 000 grounded req/mesiac → pri našom objeme fakticky zadarmo).
  Minula len q63. Flagy mimo ref: 6, čistý FP len q76. GOOGLE_API_KEY
  nový (AI Studio projekt quiz-agent, prepay billing zapnutý founderom
  2026-08-26); grounding vyžaduje billing, free-tier kľúč má nulovú kvótu.
- **gemini-3.7-flash: negroundoval** (0 search queries na všetkých 20) →
  4/7 len z pamäte za 0,23 ¢/q — ako grounded check nevalidný.
- **Perplexity Sonar** (len cenový research, netestované): sonar $1/$1
  za M + $5–12/1k requestov podľa search_context_size → odhad ~1–2 ¢/q;
  sonar-pro $3/$15 + $6–14/1k.

## Rozšírená validácia 40q (founder ask, 2026-08-26)

+20 čistých otázok (deterministický výber, `subset40()` v harnesse),
recall stále **7/7**, na čistej dvadsiatke jediný flag q92 (Hatsune Miku
„no human performer" — hlas je samplovaný z reálnej herečky; kandidát na
founder verdikt, skôr nitpick). Priemer **4,04 ¢/q** na n=40. Výsledky
`native_openai_gpt-5-mini_40.jsonl`.

## Batch API poznámka (korekcia 2026-08-26)

Anthropic Batch web search podporuje (−50 % len tokeny, search fee
1 ¢/hľadanie ostáva v plnej výške — pri native checku je search fee
dominantná zložka, takže reálna úspora je malá); OpenAI Batch web_search
NEPODPORUJE; Gemini Batch nejasné (docs mlčia); Perplexity batch nemá.

## Odporúčanie

gpt-5-mini je kvalitou aj cenou pred prod Sonnet 5 native (5/7 @ ~18 ¢).
Implementované a nasadené 2026-08-26 po founder zelenej (PR #36,
squash-merge `4b2d7465`) — detail nasadenia a rollback v
`docs/issues/issue-166-d21b-experiment-round.md`.
