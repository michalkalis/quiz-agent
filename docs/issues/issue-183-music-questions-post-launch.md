# #183 — Hudobné otázky po prvom App Store release (Apple Music ukážky vs. AI originálna hudba)

**Triage:** enhancement · needs-info (produktové rozhodnutie foundera; **nie pred prvým App Store release**, founder 2026-09-18)

## Smer

Founder 2026-09-16: preveriť, či AI generátor (Suno a pod.) obíde licencie „upravenou“ verziou reálnej pesničky. Verdikt researchu: **nie**, práva ku skladbe ostávajú, GEMA v. Suno (Mníchov 07/2026) zakázal také výstupy, Suno/Udio to zakazujú aj v podmienkach. Founder 2026-09-18: Apple Music ukážky „znejú ideálne“, ale až po prvom App Store release, žiadne veľké zmeny do launch verzie.

Oprava 2026-09-18 (po augustovom researchi): Apple podmienky ukážok zakazujú použitie „na samostatnú zábavnú hodnotu mimo promo účelu“. Kvíz na ukážkach je porušenie na papieri, tolerované v praxi (Intro King, MusIQ, Heard-It! v App Store). Riziko = stiahnutie z App Store, nie súd.

Research: [ai-music-licensing-quiz.md](../research/ai-music-licensing-quiz.md) · [audio-questions-legal-feasibility-2026-08.md](../research/audio-questions-legal-feasibility-2026-08.md)

## Rozhodnutie pre foundera (po launchi)

| Cesta | Čo hráč dostane | Riziko |
|---|---|---|
| A. Apple Music ukážky (MusicKit) | reálne hity, 30 s, bez predplatného | stredné až vysoké: porušenie podmienok ukážok, Apple môže vypnúť; mitigácia = promo obrazovka so store odkazom + atribúcia + streaming bez keše |
| B. AI originálna hudba (ElevenLabs Music) | otázky o štýle/dekáde/nástroji/žánri, žiadne reálne skladby | nízke: licencovaný tréning, výstup čistý na komerčné použitie |
| C. Znelky a stingery (ElevenLabs Music) | zvuková identita appky, nie otázky | nízke; malý krok, dá sa aj samostatne |

Zakázané bez ohľadu na cestu: AI covery/soundalike reálnych skladieb, prompty s menami umelcov/skladieb.

## Tracky (až po rozhodnutí)

- **A – MusicKit prototyp:** vývojársky token, vyhľadanie skladby, streamovaný 30 s prehrávač so store odkazom a atribúciou, nový typ otázky `music_preview`, STT konflikt (mikrofón počas prehrávania) rovnako ako TTS single-flight; TF test + App Store review na skúšku.
- **B – štýlové otázky:** generátor promptov bez mien umelcov, uložené klipy v bundle alebo CDN, nový typ otázky, review flow ako pri texte.
- **C – znelky:** 3 až 5 klipov (štart, správne, nesprávne, recap), bundle, prehrávanie cez existujúci audio engine.

## Otvorené

- Founder: A, B alebo C (kombinácia)? Odpoveď až po prvom App Store release.
- Pri A: akceptuje founder riziko stiahnutia z App Store pre tento typ otázok?
