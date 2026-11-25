---
name: decide
description: Open a local decision page for the founder instead of a long chat output - what this is about, visual options to click, and a copy-back answers block. Use at the end of a session (or at a gate mid-session) whenever the founder has a product or UX decision to make, variants or screenshots to look at, or two or more questions to answer.
allowed-tools: Read, Write, Bash, Glob, Grep
---

# Decide — decision page for the founder

The founder cares about the product they test, not session output. When a session needs their judgment, give them one page they can scan and click through, then act on the pasted answers. (Founder, 2026-11-21.)

## When

- **Page:** any question about the product itself or a change to it (behavior, UX, scope), anything visual (screen variants, screenshots, copy in context), or two or more questions at once — even when it is a single question. Typically at the end of the session, or at a gate that blocks further work.
- **No page:** one quick question with no visuals and no UX or product weight (a yes/no on process, an approval to spend, which of two runs first) → in-session question prompt. Nothing to decide and nothing to look at → the normal short chat reply. Implementation choices you can make yourself never go on a page (Rule #13).
- **Local only** (founder, 2026-11-21): the page and its media live on this Mac; nothing is uploaded.

## Build

1. Write a JSON spec to the scratchpad. Format: docstring of `scripts/decision_page.py`.
2. `uv run scripts/decision_page.py <spec.json>` — builds the page, puts the session name in the heading (read from the session file, never guessed) and opens it in the browser. Output: `docs/artifacts/decisions/<session>-<slug>.html` in the main checkout.
3. Chat reply: at most three lines — the outcome in one sentence, the absolute path to the page, and "paste the answers here". Do not repeat the page content in chat.
4. Keep working on everything that does not depend on the answers.

Never hand-write the HTML; if the template lacks something, extend the script.

## Content rules

- **Slovak, informal (tykať), plain product language.** No file paths, code, PR numbers or jargon in the visible text.
- **Summary:** two or three sentences. `done`: only what the founder can see in the app. Drop any list that is empty.
- **`how` — the founder wants the overview, not the detail.** State how the thing works now and which technical direction was taken, in plain words: what technology does the job, where it runs (phone or server), whether it works in the iOS app, what it costs or limits. Examples: whether the feature uses the question search index and for what, what steps a question passes before it reaches players. Never how you got there, no file or function names. A technical direction with a product consequence (works offline or not, extra cost, slower answer, not possible on iOS) is a question for the founder, not a note.
- **`risks`:** only what touches the product, the UX or real players. No engineering risks.
- **Questions:** only real founder decisions, at most about six per page. Each has 2 to 4 options and says in one line what the choice changes for the player. Mark your pick with `recommended` when you have one.
- **Show, don't describe.** For UI choices every option carries a simulator screenshot (`image`) or a small mockup (`html`). Mockups reuse the app's real look (design catalog), mostly visual, minimal annotation.
- Videos go in with `video`; they play from disk, muted until the founder turns the sound on.

## When the answers come back

The founder pastes a block starting with `Odpovede · <session> · <title>`; each line carries the question id and the picked letter and title. Check the session name matches this session, then act on it without re-asking. An unanswered question means "not decided yet": continue with the rest and raise it again only if it blocks. Record durable decisions where they belong (issue plan, PRD, memory), not on the page — the page is throwaway.
