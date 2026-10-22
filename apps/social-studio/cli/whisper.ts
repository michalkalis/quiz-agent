// Word timings for the question clip, from whisper.cpp running locally (free,
// no API). Installed once into .cache/ by Remotion's own installer; the
// pre-cmake 1.5.5 release builds with plain `make`, so no extra toolchain.
import {execFileSync} from 'node:child_process';
import {existsSync, mkdirSync} from 'node:fs';
import path from 'node:path';
import {
	downloadWhisperModel,
	installWhisperCpp,
	transcribe,
	toCaptions,
} from '@remotion/install-whisper-cpp';
import type {Language, TimedWord} from '../src/types';
import {APP_DIR, CACHE_DIR} from './paths';

// Remotion's bundled ffmpeg/ffprobe: no dependency on a system install.
const REMOTION = path.join(APP_DIR, 'node_modules', '.bin', 'remotion');

const WHISPER_VERSION = '1.5.5';
// Multilingual base model (~140 MB): good enough for timings, we never use
// the transcript text itself, only when each word was said.
const MODEL = 'base' as const;
const WHISPER_DIR = path.join(CACHE_DIR, 'whisper.cpp');

export async function ensureWhisper(): Promise<void> {
	mkdirSync(CACHE_DIR, {recursive: true});
	await installWhisperCpp({to: WHISPER_DIR, version: WHISPER_VERSION, printOutput: false});
	await downloadWhisperModel({folder: WHISPER_DIR, model: MODEL, printOutput: false});
}

type Spoken = {text: string; startMs: number; endMs: number};

async function spokenWords(audioPath: string, language: Language): Promise<Spoken[]> {
	mkdirSync(path.join(CACHE_DIR, 'wav'), {recursive: true});
	const wav = path.join(CACHE_DIR, 'wav', path.basename(audioPath).replace(/\.[a-z0-9]+$/i, '.16k.wav'));
	if (!existsSync(wav)) {
		execFileSync(REMOTION, ['ffmpeg', '-y', '-loglevel', 'error', '-i', audioPath, '-ar', '16000', '-ac', '1', wav]);
	}
	const output = await transcribe({
		inputPath: wav,
		whisperPath: WHISPER_DIR,
		whisperCppVersion: WHISPER_VERSION,
		model: MODEL,
		tokenLevelTimestamps: true,
		language,
		printOutput: false,
	});
	const {captions} = toCaptions({whisperCppOutput: output});
	return captions
		.map((c) => ({text: c.text.trim(), startMs: c.startMs, endMs: c.endMs}))
		.filter((c) => c.text.length > 0);
}

/**
 * Time each on-screen word by where it falls in the spoken audio.
 *
 * The clip reads a normalised text (digits spelled out, MCQ options appended),
 * so on-screen words and whisper words never match one to one. Instead both
 * sides are mapped onto "fraction of characters said": a display word that
 * starts 40 % into the display text appears when 40 % of the spoken
 * characters (up to `spokenShare` for MCQ, where the stem is only part of the
 * clip) have been said.
 */
export async function timeWords(
	audioPath: string,
	language: Language,
	displayWords: string[],
	spokenShare = 1,
): Promise<{words: TimedWord[]; optionsAtMs: number}> {
	const spoken = await spokenWords(audioPath, language);
	if (spoken.length === 0) throw new Error('whisper found no speech in the clip');
	const total = spoken.reduce((n, w) => n + w.text.length, 0);
	const marks: {frac: number; ms: number}[] = [];
	let acc = 0;
	for (const w of spoken) {
		marks.push({frac: acc / total, ms: w.startMs});
		acc += w.text.length;
	}
	marks.push({frac: 1, ms: spoken[spoken.length - 1].endMs});
	const at = (frac: number) => {
		const i = marks.findIndex((m) => m.frac >= frac);
		if (i <= 0) return marks[0].ms;
		const a = marks[i - 1];
		const b = marks[i];
		return a.ms + ((frac - a.frac) / Math.max(1e-6, b.frac - a.frac)) * (b.ms - a.ms);
	};
	const displayTotal = displayWords.reduce((n, w) => n + w.length, 0);
	let pos = 0;
	const words = displayWords.map((text) => {
		const startMs = Math.round(at((pos / displayTotal) * spokenShare));
		pos += text.length;
		return {text, startMs};
	});
	return {words, optionsAtMs: Math.round(at(spokenShare))};
}

export function audioDurationMs(audioPath: string): number {
	const out = execFileSync(REMOTION, [
		'ffprobe',
		'-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', audioPath,
	]).toString();
	return Math.round(parseFloat(out) * 1000);
}
