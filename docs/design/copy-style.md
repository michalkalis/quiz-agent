# Copy style — Trubbo user-facing texts (sk · cs · en)

Source of truth for every text a player sees or hears: `Localizable.xcstrings`, `InfoPlist.xcstrings`, voice hints and spoken prompts (`VoiceCommandLexicon+Display.swift`, spoken-prompt literals), notifications. Checked automatically by the `copy-review` job in `.github/workflows/claude-review.yml` on every PR that touches these files (subscription token, no API credits). Founder decisions: 2026-09-24 (voice lexicon parity), 2026-09-29 (#189 — TF feedback 2026-09-29: „kvíz“ term, gender-neutral address, automated check instead of manual review).

## Rules (a violation is a finding)

1. **Address:** informal singular. sk/cs „ty“, never „vy“ / „Vy“.
2. **Gender-neutral toward the player** where it reads naturally: „Tvoja odpoveď“, not „Povedal si“; restructure „si vyčerpal“, „aby si mohol“. The app talking about itself may stay masculine („Nerozumel som“).
3. **Buttons and actions in the imperative:** sk „Štart, Potvrď, Znova, Preskoč, Zruš, Ďalej“, cs „Start, Potvrď, Znovu, Přeskoč, Zruš, Další“, en "Start, Confirm, Again, Skip, Cancel, Next". Never the infinitive („Potvrdiť“, „Skryť lištu“). Running text that names a button uses its exact current label.
4. **Voice hints** quote the exact command words of that screen in the quiz language („Povedz „potvrď“, „znova“ alebo novú odpoveď“); every quoted word must be a valid command, in all three languages at once.
5. **No dashes as punctuation** (—, –, or a spaced -). Use a comma, period or colon. Hyphens inside words and number ranges are fine.
6. **Counts use xcstrings plural variants** (sk/cs one/few/many/other, en one/other). Never a single form such as „o %lld dní“ or "%lld questions".
7. **Terms:** one quiz run is „kvíz“ (cs „kvíz“, en "quiz"), not „relácia“ / „hra“ / "session" / "game"; exception: login expiry „Relácia vypršala. Prihlás sa znova.“ Product name „Trubbo“, never the code name. One word per concept across screens; when two compete, the existing majority wins and the PR says so.
8. **Language integrity:** cs rows are real Czech, sk rows real Slovak, en natural English; the three say the same thing.
9. **Natural, short:** no literal calques from English; buttons fit on one line (about 16 characters), hint and pill lines about 45.
10. **Spoken texts** (TTS) read naturally aloud: no symbols, abbreviations or quote marks the voice would pronounce.
11. **Placeholders** (`%@`, `%lld`, `%1$@`) keep their count and order in every language.

## Review procedure

Report only objective violations of the rules above, each with the exact replacement text for every affected language. Taste and tone are not findings; when a text looks off but no rule covers it, leave it for the founder in one summary comment. Author agents fix or rebut every finding before merge (PR workflow in `.claude/rules/shared.md`).
