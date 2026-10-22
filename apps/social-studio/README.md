# social-studio

Renders Trubbo's social posts from approved questions (#210 — Marketing on social networks, sub-task 210.3). Remotion + TypeScript, everything local and free: no paid API is ever called.

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
npm run render -- question.json  # hand-written input, see cli/shape.ts (QuestionInput)
npm run render -- --carousel <id>,<id>,<id> --part 4
npm run coverage                 # how many approved questions already have a voice clip
npm run studio                   # Remotion preview
```

A question id is fetched **read-only** from prod: `scripts/fetch_question.py` is piped into the `quiz-agent-api` machine over `fly ssh console` (SELECT in a read-only transaction, R2 GET only), so no prod secret leaves Fly. Only `review_status = 'approved'` rows (and approved translations for `--lang`) are accepted. Rows are cached in `.cache/rows/`.

## Voice and captions

- **Voice** = the clip the app already made for that question, looked up in the private R2 TTS store under the app's own cache key (spoken text + voice). If there is no clip, the reel is rendered **without voice** (silent reading pace) and the CLI says so. It never synthesizes.
- **Word captions**: whisper.cpp runs locally (`@remotion/install-whisper-cpp`, release 1.5.5, multilingual `base` model, installed into `.cache/` on first use). Its word timestamps are mapped onto the on-screen words by character position, so spelled-out numbers and read-aloud MCQ options in the clip still line up.
- ffmpeg/ffprobe and Chrome come from Remotion itself (chrome-headless-shell), not from the system.

## Licence note

Remotion is free for companies of up to 3 people (our case); re-check the [licence](https://www.remotion.dev/license) if the team grows.
