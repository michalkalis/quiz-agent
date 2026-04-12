# Issue #5: Improve Slovak Transcription Quality

## Status: IMPLEMENTED

## Findings
- ElevenLabs `language_code` IS correctly passed to WebSocket (QuizViewModel line 474)
- `languageCode = currentSession?.language ?? settings.language`
- Issue is likely ElevenLabs Scribe v2's Slovak support quality vs OpenAI Whisper
- Whisper generally has better multilingual support for European languages

## Possible fixes (ranked by feasibility)
1. **Switch to Whisper for Slovak** — Add language-based STT routing: ElevenLabs for English, Whisper for others
2. **Improve ElevenLabs config** — Ensure language parameter is correctly set
3. **Add answer normalization** — Post-processing for common Slovak transcription errors
4. **Hybrid approach** — Use ElevenLabs for real-time display, Whisper for final answer

## Files to investigate/modify
- `apps/ios-app/CarQuiz/CarQuiz/Services/ElevenLabsSTTService.swift` — Language config, WebSocket params
- `apps/quiz-agent/app/voice/transcriber.py` (lines 248-292) — Whisper context improvement
- `apps/ios-app/CarQuiz/CarQuiz/Utilities/Config.swift` — Add per-language STT routing
- `apps/ios-app/CarQuiz/CarQuiz/ViewModels/QuizViewModel.swift` — STT service selection logic

## Implementation (2026-04-03)
- Switched `Config.useElevenLabsSTT` to `false` — all languages now use Whisper (server-side)
- Language-agnostic: same STT path regardless of selected language
- ElevenLabs streaming path preserved in code, re-enable by flipping the flag

## Remaining
- Manual testing: verify Slovak transcription quality improvement with Whisper
- Re-enable ElevenLabs when Scribe v2 multilingual support improves
