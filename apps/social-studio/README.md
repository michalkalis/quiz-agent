# social-studio

Renders Trubbo's social posts from approved questions (#210 — Marketing on social networks, sub-task 210.3). Remotion + TypeScript, everything local and free; the only paid call is the opt-in `--make-voice` below.

Spec: [content plan](../../docs/issues/issue-210-content-plan.md) · [issue](../../docs/issues/issue-210-social-marketing.md).

## Compositions

| Id | Size | What |
|---|---|---|
| `FiveSeconds` | 1080×1920, ~17–21 s | hook (1.5 s) · question read by the app voice with word captions · 5 s countdown, monkey thinking · answer + one line why · end card |
| `ABC` | 1080×1920 | same, with the options on the card and "Comment A, B or C" during the countdown; the right option lights up |
| `CarouselSlide` | 1080×1350 still | `cover` · `question` (one per slide) · `answers` |

Background colour follows the category (`src/theme.ts`) so a series does not look identical. Copy (hooks, end card, carousel) is per language in `src/copy.ts` (en / sk / cs). No music is baked in; no dashes as punctuation in on-screen text (`cli/shape.ts` strips them).

## Use

```sh
npm install                      # also copies fonts + mascot from apps/website/src
npm run render -- <question-id>  # mp4 + cover jpg into out/ (gitignored)
npm run render -- <id> --lang sk --format abc --hook 2 --out ~/Movies/trubbo
npm run render -- <id> --make-voice  # no clip yet: the app's own TTS makes it (max 5 a week)
npm run render -- question.json  # hand-written input, see cli/shape.ts (QuestionInput)
npm run render -- --carousel <id>,<id>,<id> --part 4
npm run coverage                 # how many approved questions already have a voice clip
npm run studio                   # Remotion preview
```

A question id is fetched **read-only** from prod: `scripts/fetch_question.py` is piped into the `quiz-agent-api` machine over `fly ssh console` (SELECT in a read-only transaction, R2 GET only), so no prod secret leaves Fly. Only `review_status = 'approved'` rows (and approved translations for `--lang`) are accepted. Rows are cached in `.cache/rows/` for 6 hours only, because approved question text can be rewritten in place.

## Weekly batch (210.4)

```sh
npm run batch -- --dry-run       # show next week's picks only
npm run batch                    # pick, render into out/<week>/, write batches/<week>.json
npm run batch -- --monday 2026-11-02
```

- **Week per account** (content plan): Mon 5 Seconds · Tue Road Trip Round (7-question carousel) · Wed A, B or C · Fri 5 Seconds, for Instagram EN and Instagram SK/CZ (one language per post, sk/cs alternating, flipped weekly). Thu "How it plays" is not built yet. EN reels also go to YouTube Shorts.
- **Picks**: approved native rows (`--candidates` in `scripts/fetch_question.py`, read-only), founder/rater score first, then fresh pop culture; the EN account skips local questions, SK/CZ keeps sk/cz ones. Reels need a voice clip: existing ones are used first, the slots with the fewest clips (MCQ, cs) get the weekly voice budget.
- **Never repeat**: `batches/*.json` are committed and are the posted log; a question in any earlier manifest is never picked again. `batches/voice-ledger.json` (committed) holds the 5-clips-per-7-days cap.
- **Captions**: fixed per-language templates in `cli/captions.ts` (question first, prompt, app named every 3rd post, 3–5 hashtags), no model.
- **Approval page**: `review/index.html`, published as the claude.ai artifact https://claude.ai/artifact/TmE5zjEF8kn1yKyFMpzzj5 (same URL every week) with `capabilities: {db: {}}` and files `batch.json` ← `batches/<week>.json`, `media/<file>` ← `out/<week>/<file>` (drop last week's media with `null`). The founder's decisions land in the artifact's `decisions` collection (doc `<week>_<key>`: status `approved` / `rejected` / null, note), read back with ArtifactData.

## Publishing to Instagram (210.5)

The Instagram API (with Instagram Login, own Meta app, Standard Access) has no scheduling, so we schedule ourselves:

```sh
# after the founder approved the week (decisions read with ArtifactData into a JSON list), from the main checkout:
uv run --no-sync python apps/social-studio/scripts/stage_week.py 2026-W44 decisions.json [media dir]
uv run --no-sync python apps/social-studio/scripts/ig_tokens.py   # refresh tokens, copy to GitHub secrets
# commit batches/<week>.json through a PR before Monday
```

- **Stage**: approved posts' media go to the public `quiz-images` R2 bucket under `social/<week>/`; the manifest gets `status`, `publish_at` (18:00 London for EN, 18:00 Bratislava for SK/CZ, stored in UTC) and `media_urls`.
- **Publish**: `.github/workflows/social-publish.yml` runs `scripts/publish_due.py` hourly. Reels (cover = the jpg, shared to feed, labelled AI-generated because of the synthetic voice) and carousels; a post already on the account (same caption) is skipped, so reruns never double-post. A failure or a post that missed its 24 h window turns the run red. Manual run: `gh workflow run social-publish.yml -f mode=check` (tokens + quota) or `-f mode=dry-run`.
- **Tokens**: `IG_TOKEN_IG_EN`, `IG_TOKEN_IG_SKCZ` in the root `.env` (from the Meta dashboard, 60 days), refreshed and copied to GitHub secrets by `ig_tokens.py` with every weekly batch. An expired token cannot be refreshed: generate a new one in the dashboard.

## Voice and captions

- **Voice** = the clip the app already made for that question, looked up in the private R2 TTS store under the app's own cache key (spoken text + voice). If there is no clip, the reel is rendered **without voice** (silent reading pace) and the CLI says so.
- **`--make-voice`** (founder 2026-10-22, opt-in): for a question without a clip, `fetch_question.py --ensure-audio` runs the app's own `TTSService` on the prod machine. It speaks exactly what the app reads (shipped client capabilities, MCQ options included) in the app voice and stores it in R2 under the app's key, so a player who later gets the question hears the same clip and nothing is paid twice. ElevenLabs only (no fallback voice), refused past the app's ElevenLabs daily budget. The CLI prints the characters used and keeps a local ledger (`.cache/voice-ledger.json`) that stops at **5 clips per 7 days** (the ElevenLabs plan has no top-ups).
- **Why line** = the first full sentence of the explanation, never cut mid-sentence: the font shrinks to fit (`src/fitWhy.ts`), and only if it still does not fit, the sentence up to a comma is shown.
- **Word captions**: whisper.cpp runs locally (`@remotion/install-whisper-cpp`, release 1.5.5, multilingual `base` model, installed into `.cache/` on first use). Its word timestamps are mapped onto the on-screen words by character position, so spelled-out numbers and read-aloud MCQ options in the clip still line up.
- ffmpeg/ffprobe and Chrome come from Remotion itself (chrome-headless-shell), not from the system.

## Licence note

Remotion is free for companies of up to 3 people (our case); re-check the [licence](https://www.remotion.dev/license) if the team grows.
