---
name: decide
description: Open a local decision page for the founder instead of a long chat output - what this is about, visual options to click, and a copy-back answers block. Use at the end of a session (or at a gate mid-session) whenever the founder has a product or UX decision to make, variants or screenshots to look at, or two or more questions to answer.
allowed-tools: Read, Write, Bash, Glob, Grep
---

# Decide — decision page for the founder

The founder cares about the product they test, not session output. When a session needs their judgment, give them one page they can scan and click through, then act on the pasted answers. (Founder, 2026-11-21.)

## When

- **Page:** a product/UX decision, anything visual (screen variants, screenshots, copy in context), or two or more questions at once. Typically at the end of the session, or at a gate that blocks further work.
- **No page:** one quick non-visual question → in-session question prompt. Nothing to decide and nothing to look at → the normal short chat reply. Technical choices you can make yourself never go on a page (Rule #13).

## Build

1. Write a JSON spec to the scratchpad. Format: docstring of `scripts/decision_page.py`.
2. `uv run scripts/decision_page.py <spec.json>` — builds the page, puts the session name in the heading (read from the session file, never guessed) and opens it in the browser. Output: `docs/artifacts/decisions/<session>-<slug>.html` in the main checkout.
3. Chat reply: at most three lines — the outcome in one sentence, the absolute path to the page, and "paste the answers here". Do not repeat the page content in chat.
4. Keep working on everything that does not depend on the answers.

Never hand-write the HTML; if the template lacks something, extend the script.

## Content rules

- **Slovak, informal (tykať), plain product language.** No file paths, code, PR numbers or jargon in the visible text.
- **Summary:** two or three sentences. `done` / `test`: only what the founder can see or try in the app; drop the lists when empty.
- **Questions:** only real founder decisions, at most about six per page. Each has 2 to 4 options and says in one line what the choice changes for the player. Mark your pick with `recommended` when you have one.
- **Show, don't describe.** For UI choices every option carries a simulator screenshot (`image`) or a small mockup (`html`). Mockups reuse the app's real look (design catalog), mostly visual, minimal annotation.
- Videos and other heavy media stay in a claude.ai artifact; link it from the option text.

## When the answers come back

The founder pastes a block starting with `Odpovede · <session> · <title>`; each line carries the question id and the picked letter and title. Check the session name matches this session, then act on it without re-asking. An unanswered question means "not decided yet": continue with the rest and raise it again only if it blocks. Record durable decisions where they belong (issue plan, PRD, memory), not on the page — the page is throwaway.
