import path from 'node:path';
import {fileURLToPath} from 'node:url';

export const APP_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
/** whisper.cpp + model + fetched rows/clips. Gitignored. */
export const CACHE_DIR = path.join(APP_DIR, '.cache');
/** Clips are copied here so the composition can load them via staticFile. Gitignored. */
export const PUBLIC_AUDIO_DIR = path.join(APP_DIR, 'public', 'audio');
/** Weekly batch manifests (= the posted log) and the voice ledger. Committed,
 * so "never repeat a question" and the weekly voice cap hold across checkouts. */
export const BATCH_DIR = path.join(APP_DIR, 'batches');
export const VOICE_LEDGER = path.join(BATCH_DIR, 'voice-ledger.json');
/** Clips the app's TTS may make for social posts per rolling 7 days (founder
 * 2026-10-22: ElevenLabs Starter, no top-ups). EXTRA_VOICES raises it for one
 * run when the founder okays more (2026-10-23: the launch posts). */
export const VOICES_PER_WEEK = 5 + Number(process.env.EXTRA_VOICES ?? 0);
