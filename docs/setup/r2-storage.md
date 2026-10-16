# Súbory v Cloudflare R2

Od 2026-10-16 sú všetky súbory appky vo **firemnom** Cloudflare účte `hello@missinghue.com` (account `bff6d086844b7b18fbb5065d179f1fcf`, endpoint `https://bff6d086844b7b18fbb5065d179f1fcf.r2.cloudflarestorage.com`). Rozhodnutie foundera, #207 — pripravenosť na produkciu.

| Bucket | Prístup | Čo v ňom je | Kto zapisuje |
|---|---|---|---|
| `quiz-images` | verejný cez r2.dev: `https://pub-93c1fbd068fe48a6848d4e647fe1596e.r2.dev` | obrázky obrázkových otázok (`silhouettes/`, `blind_maps/`, `hint_images/`) | lokálne skripty `apps/quiz-pack-api/scripts/generate_*.py` cez `app/image_generation/r2_uploader.py` |
| `trubbo-voice-samples` | súkromný | nahrávky odpovedí z TestFlight (#197 — korpus nahrávok na prehrávanie hlasovej cesty) | `quiz-agent-api` (`app/voice/sample_storage.py`) |

Jeden token (Object Read & Write na oba buckety) je v root `.env` ako `R2_COMPANY_*` a skopírovaný do mien, ktoré čítá kód:

- `quiz-agent-api` (Fly secrets): `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `VOICE_SAMPLES_R2_BUCKET=trubbo-voice-samples`.
- root `.env` pre skripty: `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET=quiz-images`, `R2_PUBLIC_URL` (základ verejných URL, ktoré sa ukladajú do `questions.media_url`); `VOICE_SAMPLES_R2_*` na ručné čítanie nahrávok.
- `quiz-pack-api` R2 nepoužíva (obrázky generujú len lokálne skripty).

iOS nemá žiadnu R2 adresu natvrdo: URL obrázka príde v odpovedi API (`media_url`).

## Presun z osobného účtu (2026-10-16)

Predtým boli oba buckety v osobnom účte `michal.kalis@gmail.com` (account `a4575c47…`, verejná URL `pub-2f9ac644….r2.dev`).

- Skopírované všetky objekty (`quiz-images` 45, `trubbo-voice-samples` všetky vrátane nahrávok pribudnutých počas prepnutia), overené počty, veľkosti a ETag (MD5).
- `questions.media_url` + `reveal_url` v `questions.provenance` prepísané na novú verejnú URL v `quiz_pack` aj `quiz_pack_staging` (25 riadkov v každej, všetky `archived`). Záloha pôvodných hodnôt: tabuľka `r2_move_backup.questions_20261016` v oboch databázach; návrat = `update questions q set media_url = b.media_url, provenance = b.provenance from r2_move_backup.questions_20261016 b where b.id = q.id`.
- Staré prihlasovacie údaje ostávajú v root `.env` ako `R2_PERSONAL_*` len na dobu odkladu; nič do starých bucketov už nezapisuje.
- **Po 2026-10-23:** zmazať staré buckety v osobnom účte, riadky `R2_PERSONAL_*` z `.env` a schému `r2_move_backup` (krok v #207 → Founder kroky).
