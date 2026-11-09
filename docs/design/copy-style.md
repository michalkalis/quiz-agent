# Copy style — Trubbo user-facing texts (sk · cs · en)

Source of truth for every text a player sees or hears: `Localizable.xcstrings`, `InfoPlist.xcstrings`, voice hints and spoken prompts (`VoiceCommandLexicon+Display.swift`, spoken-prompt literals), notifications. Checked automatically by the `copy-review` job in `.github/workflows/claude-review.yml` on every PR that touches these files (subscription token, no API credits). Founder decisions: 2026-09-24 (voice lexicon parity), 2026-09-29 (#189 — TF feedback 2026-09-29: „kvíz“ term, gender-neutral address, automated check instead of manual review).

## Rules (a violation is a finding)

1. **Address:** informal singular. sk/cs „ty“, never „vy“ / „Vy“.
2. **Gender-neutral toward the player** where it reads naturally: „Tvoja odpoveď“, not „Povedal si“; restructure „si vyčerpal“, „aby si mohol“. The app talking about itself may stay masculine („Nerozumel som“).
3. **Buttons and actions in the imperative:** sk „Štart, Potvrď, Znova, Zruš“, cs „Start, Potvrď, Znovu, Zruš“, en "Start, Confirm, Again, Cancel". Two different "next" actions (#224, 2026-11-03): moving on to the next question (former „Preskoč“) is sk „Ďalšia“, cs „Další“, en "Next" (button and voice command); continuing after a result is sk „Ďalej“, cs „Dál“. Do not swap them. Never the infinitive („Potvrdiť“, „Skryť lištu“). Running text that names a button uses its exact current label.
4. **Voice hints** quote the exact command words of that screen in the quiz language („Povedz „potvrď“, „znova“ alebo novú odpoveď“); every quoted word must be a valid command, in all three languages at once.
5. **No dashes as punctuation** (—, –, or a spaced -). Use a comma, period or colon. Hyphens inside words and number ranges are fine.
6. **Counts use xcstrings plural variants** (sk/cs one/few/many/other, en one/other). Never a single form such as „o %lld dní“ or "%lld questions".
7. **Terms:** one quiz run is „kvíz“ (cs „kvíz“, en "quiz"), not „relácia“ / „hra“ / "session" / "game"; exception: login expiry „Relácia vypršala. Prihlás sa znova.“ Product name „Trubbo“, never the code name. One word per concept across screens; when two compete, the existing majority wins and the PR says so.
8. **Language integrity:** cs rows are real Czech, sk rows real Slovak, en natural English; the three say the same thing.
9. **Natural, short:** no literal calques from English; buttons fit on one line (about 16 characters), hint and pill lines about 45.
10. **Spoken texts** (TTS) read naturally aloud: no symbols, abbreviations or quote marks the voice would pronounce.
11. **Placeholders** (`%@`, `%lld`, `%1$@`) keep their count and order in every language.

### Sound like a person (rules 12 to 19)

Founder, 2026-11-08: these apply to every Trubbo text, also App Store, web, socials and video narration (CI checks only the app strings listed above). Test: would a friend say it out loud like this? Sources: `docs/research/human-sounding-copy-2026-11-08.md`.

12. **No contrast tail.** No „X, nie Y“, „nie X, ale Y“, „nielen X, ale aj Y“, "not X, but Y", "not just X". Say the positive thing concretely.
    ✗ „so zábavnými otázkami, nie školskými“ → ✓ „so zábavnými otázkami z bežného života“ · ✗ "fun questions, not school trivia" → ✓ "fun questions about everyday life"
13. **Concrete nouns, not abstract ones.** Name the thing: otázky, kvíz, kamaráti, telefón. Not „zážitok“, „obsah“, „funkcia“, „riešenie“, "experience", "content", "feature".
    ✗ „Zážitok z kvízu pre celú partiu“ → ✓ „Kvíz pre celú partiu“
14. **Verbs, not office nouns.** ✗ „Trubbo vykoná kontrolu odpovede“ → ✓ „Trubbo skontroluje odpoveď“. Also not „za účelom“, „prostredníctvom“, „realizovať“, "utilize", "facilitate".
15. **No stock marketing words.** en: seamless, elevate, unleash, delve, effortless, immersive, vibrant, ultimate, next-level, game-changer, empower. sk: jedinečný, bezproblémový, revolučný, dokonalý zážitok, posuň na novú úroveň, ponor sa. cs: jedinečný, bezproblémový, revoluční, dokonalý zážitek, posuň na novou úroveň, ponoř se. Say what the player gets.
    ✗ "Elevate your road trips with seamless voice trivia" → ✓ "Play a quiz by voice on your next drive"
16. **No triads for show.** No three adjectives or three parallel benefits in a row; keep the one or two that matter.
    ✗ „Rýchly, zábavný a chytrý kvíz“ → ✓ „Rýchly kvíz na cestu“
17. **No filler hooks or reveals.** No sales rhetorical question as an opener („Chceš zažiť…?“, "Ready to…?") and no colon or question reveal („Výsledok? Zábava.“). Real quiz questions are fine. No empty intensifiers: „jednoducho, skutočne, naozaj“, "simply, truly, actually, just".
    ✗ „Hľadáš zábavu na cesty? Trubbo je tu!“ → ✓ „Trubbo ti cestou prečíta otázky a ty odpovedáš.“
18. **sk/cs prepositions and phrases as people say them, not copied from English.** ✗ „v tej istej Wi‑Fi“ → ✓ „na tej istej Wi‑Fi“ (cs „na stejné Wi‑Fi“) · ✗ „Užívaj si kvíz“ (*enjoy*) → ✓ „Bav sa“ or nothing · ✗ „urob rozdiel“ (*make a difference*) → say the effect.
19. **Spoken texts and narration: short sentences, one idea each, in the order the player does it**, mixing short and medium lengths. Web and social copy: no emoji bullets, sentence case ("Play with friends", not "Play With Friends").
    ✗ „Po zodpovedaní otázky dostaneš vysvetlenie v jednej či dvoch vetách.“ → ✓ „Odpovieš. Trubbo ti povie, či je to správne, a prečo.“
20. **No prices on social media** (founder, 2026-11-09): posts, captions, video narration, pinned comments and profile bios never state a price or amount (€, $, „za X €“). Prices change; the App Store shows the current one. „Zadarmo v App Store“ is not a price and stays fine.
    ✗ „Vlastný balík za 6,99 €“ → ✓ „Vlastný balík na tému, ktorú si vyberieš“

## Review procedure

Report only objective violations of the rules above, each with the exact replacement text for every affected language. Taste and tone are not findings; when a text looks off but no rule covers it, leave it for the founder in one summary comment. Author agents fix or rebut every finding before merge (PR workflow in `.claude/rules/shared.md`).
