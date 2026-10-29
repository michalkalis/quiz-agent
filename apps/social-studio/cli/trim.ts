// A round's answer clip says "Otázka číslo dva: Polsko"; the reel plays it
// right after its question, so the number is cut off (founder 2026-10-29).
// No new clip: the cut falls in the pause the voice makes after the colon,
// found by loudness (whisper's sk/cs word timings are too rough for this).
import {execFileSync} from 'node:child_process';
import {readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {APP_DIR} from './paths';

const REMOTION = path.join(APP_DIR, 'node_modules', '.bin', 'remotion');
const RATE = 44100;
const WIN_MS = 10;
/** Quieter than this share of the clip's peak counts as a pause. */
const QUIET = 0.05;
/** The pause after the colon; pauses inside "Otázka číslo dva" are shorter. */
const MIN_PAUSE_MS = 120;
/** Where the number can end: never before "Question" is said, never deep into the answer. */
const NUMBER_END_MS = [400, 2200];
/** Kept before the answer's first sound. */
const LEAD_MS = 40;

const wavHeader = (bytes: number) => {
	const h = Buffer.alloc(44);
	h.write('RIFF', 0);
	h.writeUInt32LE(36 + bytes, 4);
	h.write('WAVEfmt ', 8);
	h.writeUInt32LE(16, 16);
	h.writeUInt16LE(1, 20); // PCM
	h.writeUInt16LE(1, 22); // mono
	h.writeUInt32LE(RATE, 24);
	h.writeUInt32LE(RATE * 2, 28);
	h.writeUInt16LE(2, 32);
	h.writeUInt16LE(16, 34);
	h.write('data', 36);
	h.writeUInt32LE(bytes, 40);
	return h;
};

/** Writes `out` (wav) = the clip at `mp3` from the answer on; null when no cut point is found (`out` then holds the whole clip). */
export function cutAnswerNumber(mp3: string, out: string): number | null {
	// Remotion's ffmpeg has no raw output format: decode to wav, then read its samples.
	execFileSync(REMOTION, ['ffmpeg', '-y', '-loglevel', 'error', '-i', mp3, '-ar', String(RATE), '-ac', '1', '-c:a', 'pcm_s16le', out]);
	const wav = readFileSync(out);
	const pcm = wav.subarray(wav.indexOf('data') + 8);
	const per = (RATE * WIN_MS) / 1000;
	const rms: number[] = [];
	for (let i = 0; (i + per) * 2 <= pcm.length; i += per) {
		let s = 0;
		for (let j = 0; j < per; j++) s += (pcm.readInt16LE((i + j) * 2) / 32768) ** 2;
		rms.push(Math.sqrt(s / per));
	}
	const peak = Math.max(...rms);
	const [from, to] = NUMBER_END_MS.map((ms) => ms / WIN_MS);
	let cut = -1;
	for (let i = from; i < Math.min(to, rms.length) && cut < 0; i++) {
		if (rms[i] >= peak * QUIET) continue;
		let j = i;
		while (j < rms.length && rms[j] < peak * QUIET) j++;
		if ((j - i) * WIN_MS >= MIN_PAUSE_MS && j < rms.length) cut = j - LEAD_MS / WIN_MS;
		i = j;
	}
	// No clean pause (an answer that opens with a hiss, "Sleď"): the quietest moment after the number.
	if (cut < 0) {
		const start = Math.round(800 / WIN_MS);
		// ... before the answer itself: not in the silence after the last sound.
		let lastSound = rms.length - 1;
		while (lastSound > 0 && rms[lastSound] < peak * QUIET) lastSound--;
		const window = rms.slice(start, Math.min(to, lastSound - 300 / WIN_MS));
		if (!window.length) return null;
		const low = Math.min(...window);
		if (low >= peak * 0.1) return null;
		cut = start + window.indexOf(low);
	}
	const body = pcm.subarray(cut * per * 2);
	writeFileSync(out, Buffer.concat([wavHeader(body.length), body]));
	return cut * WIN_MS;
}
