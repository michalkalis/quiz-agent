# UI-variant decisions — 2026-09-14 round (#179 TF feedback: lišta povelov, toolbar, preskoč)

Founder picks, in-session 2026-09-15. Variant page: `variants/issue-179-tf-feedback-2026-09-14.html`. Implementation: #179 — TF feedback 2026-09-14 (tasky D1–D3 v pláne).

## D1 Lišta hlasových povelov → **Variant A**

Jedna lišta so stavovým popisom a slovnými čipmi, štyri stavy rovnako na MCQ aj otvorenej otázke (čítam otázku → premýšľaj + odpočet → počúvam odpoveď → vyhodnocujem), slová vždy viditeľné (päťkvízová brána `voiceHintsFreeQuizzes` sa ruší, prepínač v Nastaveniach ostáva).

**Podmienka foundera:** zvyšný layout obrazovky sa nesmie zmeniť. Spodný rad tlačidiel (napr. tri tlačidlá vedľa seba) ostáva v jednom riadku, nikdy sa nezalomí na dva.

## D2 Toolbar + ikony → **podľa Apple HIG; Variant A ak HIG nerozhoduje**

Mute a pauza v jednej zlúčenej pilulke, ⋯ samostatne; pravidlo „obrysová = vypnuté, plná = zapnuté“; play v pauze ostáva modrý. Zlúčenie vs. nezlúčenie founderovi nezáleží — rozhoduje HIG (v HIG nie je predpis, ostáva A). Štyri zjednotenia z audítnej tabuľky (skúsiť znova · prehrať odpoveď · chybové ikony · balík) platia.

## D3 Preskoč → **rozkazovací spôsob všade, jeden tvar (kapsula A)**

Text je vždy rozkazovací spôsob: „Preskoč“, „Potvrď“, „Zopakuj“ a podobne — nie neurčitok („Preskočiť“ z odporúčania stránky sa NEPOUŽIJE). Platí pre všetky jazyky v katalógu (sk, cs, en, …): zjednotiť tvar v každom. Tvar tlačidla: kapsula (A) rovnaká na MCQ aj otvorenej otázke. Spodný rad tlačidiel ostáva v jednom riadku.

## Pipeline

HTML picks (this doc) → SwiftUI (#179 D1–D3, samostatné PR) → Pencil sync (`design/quiz-agent.pen`: question frame lišta + toolbar + päta; founder `⌘S`) → TF build na požiadanie.
