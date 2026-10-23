// npm run render -- <question-id | question.json> [--format five|abc] [--lang en|sk|cs] [--hook N] [--out DIR] [--make-voice]
// npm run render -- --carousel <id,id,id> [--part N] [--lang en|sk|cs] [--out DIR]
//
// Fetches approved rows read-only from prod (or reads a JSON file), reuses the
// question's existing app voice clip if there is one (--make-voice: has the
// app's own TTS on prod make a missing one, at most 5 a week), times
// the caption words with local whisper.cpp, and renders mp4 + cover jpg (reels)
// or jpg slides (carousel). Chrome = Remotion's own chrome-headless-shell.
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {existsSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {parseArgs} from 'node:util';
import {bundle} from '@remotion/bundler';
import {renderMedia, renderStill, selectComposition} from '@remotion/renderer';
import {ANSWERS_PER_SLIDE} from '../src/CarouselSlide';
import {HOOK_MS, eyeOpenAt, reelDurationMs} from '../src/timing';
import type {CarouselSlideProps, Language, ReelProps, ReelQuestion, TimedWord} from '../src/types';
import {APP_DIR, CACHE_DIR, PUBLIC_AUDIO_DIR, VOICE_LEDGER, VOICES_PER_WEEK} from './paths';
import {shapeQuestion, type QuestionInput} from './shape';
import {audioDurationMs, ensureWhisper, timeWords} from './whisper';

const {values, positionals} = parseArgs({
	allowPositionals: true,
	options: {
		format: {type: 'string'},
		lang: {type: 'string'},
		hook: {type: 'string'},
		out: {type: 'string'},
		carousel: {type: 'string'},
		part: {type: 'string', default: '1'},
		'make-voice': {type: 'boolean', default: false},
	},
});
const OUT = path.resolve(values.out ?? path.join(APP_DIR, 'out'));
const LANG = values.lang as Language | undefined;

// Founder 2026-10-22: a missing clip may be made through the app's own TTS
// path, about 5 questions a week (ElevenLabs Starter, no top-ups).
type LedgerEntry = {at: string; id: string; language: string; chars: number};

function voicesThisWeek(): LedgerEntry[] {
	if (!existsSync(VOICE_LEDGER)) return [];
	const weekAgo = Date.now() - 7 * 24 * 3600 * 1000;
	return (JSON.parse(readFileSync(VOICE_LEDGER, 'utf8')) as LedgerEntry[]).filter((e) => Date.parse(e.at) >= weekAgo);
}

function logVoice(entry: LedgerEntry) {
	const all: LedgerEntry[] = existsSync(VOICE_LEDGER) ? JSON.parse(readFileSync(VOICE_LEDGER, 'utf8')) : [];
	writeFileSync(VOICE_LEDGER, JSON.stringify([...all, entry], null, 1));
}

/** Prod fetch: pipes scripts/fetch_question.py into the API machine. Read-only
 * unless `ensureAudio`, which lets the app's own TTS make a missing clip. */
function fetchFromProd(id: string, lang?: Language, ensureAudio = false): QuestionInput {
	const cacheFile = path.join(CACHE_DIR, 'rows', `${id}.${lang ?? 'native'}.json`);
	if (existsSync(cacheFile)) {
		const cached: QuestionInput = JSON.parse(readFileSync(cacheFile, 'utf8'));
		if (cached.audio_b64 || !ensureAudio) return cached;
	}
	if (ensureAudio) {
		const used = voicesThisWeek().length;
		if (used >= VOICES_PER_WEEK) throw new Error(`${id}: ${used} clips made in the last 7 days, the weekly limit is ${VOICES_PER_WEEK}`);
	}
	const args = `python - ${id}${lang ? ` ${lang}` : ''}${ensureAudio ? ' --ensure-audio' : ''}`;
	const out = execFileSync('fly', ['ssh', 'console', '-a', 'quiz-agent-api', '-C', args], {
		input: readFileSync(path.join(APP_DIR, 'scripts', 'fetch_question.py')),
		maxBuffer: 64 * 1024 * 1024,
		stdio: ['pipe', 'pipe', 'ignore'],
	}).toString();
	const marker = out.indexOf('@@JSON@@');
	if (marker < 0) throw new Error(`prod fetch for ${id} returned no data`);
	const row = JSON.parse(out.slice(marker + 8).trim());
	if (row.error) throw new Error(row.error);
	if (row.generated) {
		const g = row.generated;
		logVoice({at: new Date().toISOString(), id, language: row.language, chars: g.chars});
		console.log(`  voice made by the app TTS: ${g.chars} characters (ElevenLabs had ${g.credits_left_before} credits left), R2 ${g.r2_key}`);
		delete row.generated;
	}
	mkdirSync(path.dirname(cacheFile), {recursive: true});
	writeFileSync(cacheFile, JSON.stringify(row));
	return row;
}

function loadInput(arg: string): QuestionInput {
	if (arg.endsWith('.json')) return JSON.parse(readFileSync(path.resolve(arg), 'utf8'));
	if (/^[0-9a-f-]{36}$/i.test(arg)) return fetchFromProd(arg, LANG, values['make-voice'] && !values.carousel);
	throw new Error(`expected a question id or a .json file, got "${arg}"`);
}

/** Puts the existing clip under public/audio/ and returns its staticFile path, or null. */
async function stageAudio(raw: QuestionInput): Promise<string | null> {
	let bytes: Buffer | null = null;
	if (raw.audio_b64) bytes = Buffer.from(raw.audio_b64, 'base64');
	else if (raw.audio && /^https?:\/\//.test(raw.audio)) {
		const res = await fetch(raw.audio);
		if (!res.ok) throw new Error(`audio ${raw.audio}: HTTP ${res.status}`);
		bytes = Buffer.from(await res.arrayBuffer());
	} else if (raw.audio) bytes = readFileSync(path.resolve(raw.audio));
	if (!bytes) return null;
	mkdirSync(PUBLIC_AUDIO_DIR, {recursive: true});
	const name = `${createHash('sha1').update(bytes).digest('hex').slice(0, 16)}.mp3`;
	writeFileSync(path.join(PUBLIC_AUDIO_DIR, name), bytes);
	return `audio/${name}`;
}

const WORD_MS = 320; // silent reading pace when there is no voice

async function reelProps(raw: QuestionInput, q: ReelQuestion, hookIndex: number): Promise<ReelProps> {
	const displayWords = q.question.split(/\s+/).filter(Boolean);
	const audio = await stageAudio(raw);
	if (!audio) {
		const words: TimedWord[] = displayWords.map((text, i) => ({text, startMs: i * WORD_MS}));
		const optionsAtMs = displayWords.length * WORD_MS + 300;
		const questionMs = q.options.length ? optionsAtMs + q.options.length * 500 + 900 : Math.max(3500, optionsAtMs + 900);
		return {q, audio: null, words, questionMs, optionsAtMs, hookIndex};
	}
	const file = path.join(PUBLIC_AUDIO_DIR, path.basename(audio));
	await ensureWhisper();
	// MCQ clips also read the options: the stem is only the first part of them.
	const spoken = raw.spoken_text ?? [q.question, ...q.options].join(' ');
	const share = q.options.length ? Math.min(1, raw.question.length / spoken.length) : 1;
	const {words, optionsAtMs} = await timeWords(file, q.language, displayWords, share);
	return {q, audio, words, questionMs: audioDurationMs(file) + 400, optionsAtMs, hookIndex};
}

const slug = (s: string) => s.slice(0, 8);

async function main() {
	mkdirSync(OUT, {recursive: true});
	// Stage everything that goes into public/ before bundling (the bundle copies it).
	const jobs: {composition: string; props: ReelProps | CarouselSlideProps; name: string; still?: boolean; coverMs?: number}[] = [];

	if (values.carousel) {
		const ids = values.carousel.split(',').map((s) => s.trim());
		const qs = ids.map((id) => shapeQuestion(loadInput(id)));
		const language = qs[0].language;
		const part = Number(values.part);
		const base = {language, part, questions: qs, index: 0};
		jobs.push({composition: 'CarouselSlide', props: {...base, kind: 'cover'}, name: `carousel-${language}-p${part}-0-cover`, still: true});
		qs.forEach((_, i) =>
			jobs.push({composition: 'CarouselSlide', props: {...base, kind: 'question', index: i}, name: `carousel-${language}-p${part}-${i + 1}`, still: true}),
		);
		for (let i = 0; i * ANSWERS_PER_SLIDE < qs.length; i++)
			jobs.push({composition: 'CarouselSlide', props: {...base, kind: 'answers', index: i}, name: `carousel-${language}-p${part}-${qs.length + 1 + i}-answers`, still: true});
	} else {
		if (positionals.length !== 1) throw new Error('usage: npm run render -- <question-id | file.json> [--format five|abc]');
		const raw = loadInput(positionals[0]);
		const q = shapeQuestion(raw);
		const format = values.format ?? (q.options.length ? 'abc' : 'five');
		if (format === 'abc' && !q.options.length) throw new Error('--format abc needs a question with options');
		const hook = values.hook ? Number(values.hook) : parseInt(q.id.replace(/-/g, '').slice(0, 6), 16);
		const props = await reelProps(raw, format === 'five' ? {...q, options: [], correctIndex: null} : q, hook);
		if (!props.audio) console.warn(`! ${q.id}: no existing app clip, rendering without voice (--make-voice makes one)`);
		// Cover = the question fully on screen, just before the countdown,
		// nudged back if the monkey happens to blink on that frame.
		let coverMs = HOOK_MS + props.questionMs - 200;
		while (eyeOpenAt(coverMs / 1000) < 1) coverMs -= 100;
		jobs.push({
			composition: format === 'abc' ? 'ABC' : 'FiveSeconds',
			props,
			name: `${format}-${q.language}-${slug(q.id)}`,
			coverMs,
		});
		console.log(`  ${(reelDurationMs(props.questionMs) / 1000).toFixed(1)} s, voice: ${props.audio ? 'app clip' : 'none'}`);
	}

	const serveUrl = await bundle({entryPoint: path.join(APP_DIR, 'src', 'index.ts')});
	for (const job of jobs) {
		const inputProps = job.props as unknown as Record<string, unknown>;
		const composition = await selectComposition({serveUrl, id: job.composition, inputProps});
		if (job.still) {
			const output = path.join(OUT, `${job.name}.jpg`);
			await renderStill({serveUrl, composition, inputProps, output, imageFormat: 'jpeg', jpegQuality: 92});
			console.log(`✓ ${output}`);
			continue;
		}
		const output = path.join(OUT, `${job.name}.mp4`);
		await renderMedia({serveUrl, composition, inputProps, codec: 'h264', outputLocation: output, crf: 18});
		const cover = path.join(OUT, `${job.name}.jpg`);
		await renderStill({serveUrl, composition, inputProps, output: cover, frame: Math.round(((job.coverMs ?? 0) / 1000) * composition.fps), imageFormat: 'jpeg', jpegQuality: 92});
		console.log(`✓ ${output}\n✓ ${cover}`);
	}
}

main().catch((e) => {
	console.error(e instanceof Error ? e.message : e);
	process.exit(1);
});
