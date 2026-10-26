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
/** Characters the app's TTS may speak for social posts per rolling 7 days.
 * Founder 2026-10-24: question + explanation for ~10 reels a week, about
 * 1,000 ElevenLabs credits (~0.4 credit per character, Starter, no top-ups);
 * raised to 4,000 characters (~1,600 credits) for the 3-week reel format
 * test (founder 2026-10-25).
 * Clips logged before that date fell under the old 5-clips rule and do not
 * count. EXTRA_VOICE_CHARS raises it for one run when the founder okays more. */
export const VOICE_CHARS_PER_WEEK = 4000 + Number(process.env.EXTRA_VOICE_CHARS ?? 0);
const CHAR_BUDGET_FROM = Date.parse('2026-10-24T00:00:00Z');

/** Characters still allowed in the rolling 7 days, from the voice ledger entries. */
export const voiceCharsLeft = (ledger: {at: string; chars: number}[]): number => {
	const since = Math.max(CHAR_BUDGET_FROM, Date.now() - 7 * 24 * 3600 * 1000);
	const used = ledger.filter((e) => Date.parse(e.at) >= since).reduce((n, e) => n + e.chars, 0);
	return Math.max(0, VOICE_CHARS_PER_WEEK - used);
};
