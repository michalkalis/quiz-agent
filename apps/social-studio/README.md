# social-studio

Renders Trubbo's social posts from approved questions (#210 — Marketing on social networks, sub-task 210.3). Remotion + TypeScript, everything local and free; the only paid call is the opt-in `--make-voice` below.

Spec: [content plan](../../docs/issues/issue-210-content-plan.md) · [issue](../../docs/issues/issue-210-social-marketing.md).

## Compositions

| Id | Size | What |
|---|---|---|
| `FiveSeconds` | 1080×1920, ~17–21 s | hook (1.5 s) · question read by the app voice with word captions · 5 s countdown, monkey thinking · answer + one line why · end card |
| `ABC` | 1080×1920 | same, with the options on the card and "Comment A, B or C" during the countdown; the right option lights up |
| `CarouselSlide` | 1080×1350 still | `cover` · then `question` and its `answer` right after it (founder 2026-11-04; max 4 questions, Instagram takes 10 slides) |
| `Pinned` | 1080×1920, ~14 s, silent | pinned launch reel: "now on the App Store" line · the App Store screenshots (`public/store/`, copied on `npm install` from `apps/ios-app/Hangs/fastlane/screenshots` + the website's badge) · end card |
| `AppDemo` | 1080×1920, = cut length + 3.2 s end card | tap-through promo of a simulator screen recording: phone bezel on a soft tint, cuts/speed-ups, tap marks (iOS show-touches style), a subtle spotlight on the element in focus (soft-edged light dim around it, glides within a shot), spring zooms (a zoom that starts on a cut starts at once), the app's voice clips, kinetic voice captions, player speech bubbles, feature chips, big title words, step lines (what happens on screen, up to two lines), optional hook + shared end card (optional `endWord`, `endAudio`). All text stays inside SAFE with a clear gap above the phone; zooms bring their point up under the caption band and the phone is clipped well below it. Script JSON in recording time, types in `src/demoTypes.ts`, example `demo/example-en.json` (placeholder recording from the store screenshots): `npx remotion render src/index.ts AppDemo out/demo.mp4 --props=demo/example-en.json`. Real scripts `demo/round-en.json` (a round in 25 s: Reads. Listens. Explains. Or tap. Scores. Free., with the player's own voice) `demo/fourwords-en.json` (Reads. Listens. Explains. Free.) `demo/round-en-v3.json` (a round step by step, then Together, ordered packs and fun questions in 34 s) `demo/round-en-v4.json` (Home and Start, the round step by step, then narrated stills of Together, packs and fun questions in 27.7 s) `demo/round-en-v5.json` (the round step by step, then Together on the guest's phone, narrated, in 23 s) and `demo/round-en-v6.json` (the round, then one crossfaded run of local multiplayer, the reveal and a custom pack, all voices normalised to -16 LUFS, in 29.5 s) play footage from `public/demo/rec/` (gitignored: trimmed recordings `round6.mp4` / `round5.mp4` / `round4.mp4` / `round3.mp4` / `round2.mp4` / `round.mp4`, the app's voice clips, the player's answer clip, the narrator clips) |

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
EXTRA_VOICES=3 npm run batch -- --seed   # launch posts: 6 per account on the weekend before, added to that week's manifest
```

- **Week per account** (content plan): Mon 5 Seconds · Tue Road Trip Round (4-question carousel, each answer on the next slide) · Wed A, B or C · Fri 5 Seconds, for Instagram EN and Instagram SK/CZ (one language per post, sk/cs alternating, flipped weekly). Thu "How it plays" is not built yet. EN reels also go to YouTube Shorts.
- **Picks**: approved native rows (`--candidates` in `scripts/fetch_question.py`, read-only), founder/rater score first, then fresh pop culture; the EN account skips local questions, SK/CZ keeps sk/cz ones. Reels need a voice clip: existing ones are used first, the slots with the fewest clips (MCQ, cs) get the weekly voice budget.
- **Never repeat**: `batches/*.json` are committed and are the posted log; a question in any earlier manifest is never picked again. `batches/voice-ledger.json` (committed) holds the 5-clips-per-7-days cap.
- **Captions**: fixed per-language templates in `cli/captions.ts` (question first, prompt, app named every 3rd post, 3–5 hashtags), no model.
- **Approval page**: `review/index.html`, published as the claude.ai artifact https://claude.ai/artifact/TmE5zjEF8kn1yKyFMpzzj5 (same URL every week) with `capabilities: {db: {}}` and files `batch.json` ← `batches/<week>.json`, `media/<file>` ← `out/<week>/<file>` (drop last week's media with `null`). The founder's decisions land in the artifact's `decisions` collection (doc `<week>_<key>`: status `approved` / `rejected` / null, note), read back with ArtifactData.

## Publishing to Instagram (210.5)

The Instagram API (with Instagram Login, own Meta app, Standard Access) has no scheduling, so we schedule ourselves:

```sh
# after the founder approved the week (decisions read with ArtifactData into a JSON list), from the main checkout:
uv run --no-sync python apps/social-studio/scripts/stage_week.py 2026-W44 decisions.json [media dir]   # add --wrangler where .env R2 keys are stale (uses `wrangler login`)
uv run --no-sync python apps/social-studio/scripts/ig_tokens.py   # refresh tokens, copy to GitHub secrets
# commit batches/<week>.json through a PR before Monday
```

- **Stage**: approved posts' media go to the public `quiz-images` R2 bucket under `social/<week>/`; the manifest gets `status`, `publish_at` (18:00 London for EN, 18:00 Bratislava for SK/CZ, stored in UTC) and `media_urls`.
- **Carousels are posted by hand** (founder 2026-11-04): they get music, which only the Instagram app can add (the API's audio is for reels only, and only with Facebook Login). `stage_week.py` marks them `manual`; `python3 apps/social-studio/scripts/export_manual.py <week>` puts each one into iCloud Drive/Trubbo Instagram/<week>/ (slides 01.jpg… + popis.txt with caption and time). The accounts are business accounts, so the app offers Meta's royalty-free Sound Collection.
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
