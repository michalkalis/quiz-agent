// npm run render -- <question-id | question.json> [--format five|abc] [--lang en|sk|cs] [--hook N] [--out DIR] [--make-voice]
//                    [--opening intro|fused|plain] [--explain line|parts|captions]
// npm run render -- --carousel <id,id,id> [--part N] [--lang en|sk|cs] [--out DIR]
// npm run render -- --round <id,id,id> [--lang en|sk|cs] [--out DIR] [--make-voice]   (easiest first)
//
// Fetches approved rows read-only from prod (or reads a JSON file), reuses the
// question's existing app voice clip if there is one (--make-voice: has the
// app's own TTS on prod make a missing one, at most 5 a week), times
// the caption words with local whisper.cpp, and renders mp4 + cover jpg (reels)
// or jpg slides (carousel). Chrome = Remotion's own chrome-headless-shell.
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {existsSync, mkdirSync, readFileSync, statSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {parseArgs} from 'node:util';
import {bundle} from '@remotion/bundler';
import {renderMedia, renderStill, selectComposition} from '@remotion/renderer';
import {ANSWERS_PER_SLIDE} from '../src/CarouselSlide';
import {LEAD_MS, eyeOpenAt, reelTimeline, roundTimeline} from '../src/timing';
import type {CarouselSlideProps, ExplainTrack, Language, ReelProps, ReelQuestion, ReelStyle, RoundProps, TimedWord} from '../src/types';
import {APP_DIR, CACHE_DIR, PUBLIC_AUDIO_DIR, VOICE_CHARS_PER_WEEK, VOICE_LEDGER, voiceCharsLeft} from './paths';
import {explainParts, shapeQuestion, type QuestionInput} from './shape';
import {audioDurationMs, ensureWhisper, timeWords} from './whisper';

const {values, positionals} = parseArgs({
	allowPositionals: true,
	options: {
		format: {type: 'string'},
		lang: {type: 'string'},
		hook: {type: 'string'},
		out: {type: 'string'},
		carousel: {type: 'string'},
		round: {type: 'string'},
		part: {type: 'string', default: '1'},
		'make-voice': {type: 'boolean', default: false},
		opening: {type: 'string', default: 'fused'},
		explain: {type: 'string', default: 'parts'},
	},
});
const OUT = path.resolve(values.out ?? path.join(APP_DIR, 'out'));
const LANG = values.lang as Language | undefined;

// A missing clip may be made through the app's own TTS path within the
// weekly character budget (cli/paths.ts, founder 2026-10-22 / 2026-10-24).
type LedgerEntry = {at: string; id: string; language: string; chars: number; what?: string};

const ledger = (): LedgerEntry[] => (existsSync(VOICE_LEDGER) ? JSON.parse(readFileSync(VOICE_LEDGER, 'utf8')) : []);

function logVoice(entry: LedgerEntry) {
	writeFileSync(VOICE_LEDGER, JSON.stringify([...ledger(), entry], null, 1));
}

/** Cached rows outlive one batch run only: approved question text can be
 * rewritten in place (#211 naturalness pass), so an old copy would render
 * wording the app no longer uses. */
const ROW_CACHE_MS = 6 * 60 * 60 * 1000;

/** Prod fetch: pipes scripts/fetch_question.py into the API machine. Read-only
 * unless `ensureAudio`, which lets the app's own TTS make a missing clip. */
/** `questionOnly`: a round's first questions show their explanation as text, so only the question clip is needed. */
function fetchFromProd(id: string, lang?: Language, ensureAudio = false, questionOnly = false): QuestionInput {
	const cacheFile = path.join(CACHE_DIR, 'rows', `${id}.${lang ?? 'native'}.json`);
	if (existsSync(cacheFile) && Date.now() - statSync(cacheFile).mtimeMs < ROW_CACHE_MS) {
		const cached: QuestionInput = JSON.parse(readFileSync(cacheFile, 'utf8'));
		if ((cached.audio_b64 && (questionOnly || cached.explanation_audio_b64 || !cached.explanation)) || !ensureAudio) return cached;
	}
	if (ensureAudio && voiceCharsLeft(ledger()) <= 0)
		throw new Error(`${id}: the weekly voice budget (${VOICE_CHARS_PER_WEEK} characters) is used up`);
	const args = `python - ${id}${lang ? ` ${lang}` : ''}${ensureAudio ? ' --ensure-audio' : ''}${ensureAudio && questionOnly ? ' --question-only' : ''}`;
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
		const g = row.generated as {chars: number; credits_left_before: number; clips: {what: string; chars: number; r2_key: string}[]};
		for (const c of g.clips) logVoice({at: new Date().toISOString(), id, language: row.language, chars: c.chars, what: c.what});
		console.log(
			`  voice made by the app TTS: ${g.clips.map((c) => `${c.what} ${c.chars}`).join(', ')} characters (ElevenLabs had ${g.credits_left_before} credits left, ${voiceCharsLeft(ledger())} characters left this week)`,
		);
		delete row.generated;
	}
	mkdirSync(path.dirname(cacheFile), {recursive: true});
	writeFileSync(cacheFile, JSON.stringify(row));
	return row;
}

function loadInput(arg: string, questionOnly = false): QuestionInput {
	if (arg.endsWith('.json')) return JSON.parse(readFileSync(path.resolve(arg), 'utf8'));
	if (/^[0-9a-f-]{36}$/i.test(arg)) return fetchFromProd(arg, LANG, values['make-voice'] && !values.carousel, questionOnly);
	throw new Error(`expected a question id or a .json file, got "${arg}"`);
}

/** Puts clip bytes under public/audio/ and returns their staticFile path. */
function stageBytes(bytes: Buffer): string {
	mkdirSync(PUBLIC_AUDIO_DIR, {recursive: true});
	const name = `${createHash('sha1').update(bytes).digest('hex').slice(0, 16)}.mp3`;
	writeFileSync(path.join(PUBLIC_AUDIO_DIR, name), bytes);
	return `audio/${name}`;
}

/** Puts the existing question clip under public/audio/ and returns its staticFile path, or null. */
async function stageAudio(raw: QuestionInput): Promise<string | null> {
	let bytes: Buffer | null = null;
	if (raw.audio_b64) bytes = Buffer.from(raw.audio_b64, 'base64');
	else if (raw.audio && /^https?:\/\//.test(raw.audio)) {
		const res = await fetch(raw.audio);
		if (!res.ok) throw new Error(`audio ${raw.audio}: HTTP ${res.status}`);
		bytes = Buffer.from(await res.arrayBuffer());
	} else if (raw.audio) bytes = readFileSync(path.resolve(raw.audio));
	return bytes ? stageBytes(bytes) : null;
}

const WORD_MS = 320; // silent reading pace when there is no voice
const PART_PAUSE_MS = 500; // silent pace: a breath between explanation parts

/** The whole explanation in parts, timed to its app clip, or at reading pace without one. */
async function explainTrack(raw: QuestionInput, q: ReelQuestion): Promise<ExplainTrack> {
	const parts = explainParts(q.explanation);
	const split = parts.map((p) => p.split(/\s+/).filter(Boolean));
	const flat = split.flat();
	let n = 0;
	const indexed = parts.map((text, i) => {
		const firstWord = n;
		n += split[i].length;
		return {text, firstWord};
	});
	const audio = raw.explanation_audio_b64 ? stageBytes(Buffer.from(raw.explanation_audio_b64, 'base64')) : null;
	if (!audio || !flat.length) {
		let t = 0;
		const words = split.flatMap((ws) => {
			const timed = ws.map((text, i) => ({text, startMs: t + i * WORD_MS}));
			t += ws.length * WORD_MS + PART_PAUSE_MS;
			return timed;
		});
		return {audio: null, words, parts: indexed, ms: t};
	}
	const file = path.join(PUBLIC_AUDIO_DIR, path.basename(audio));
	await ensureWhisper();
	const {words} = await timeWords(file, q.language, flat);
	return {audio, words, parts: indexed, ms: audioDurationMs(file)};
}

type QuestionTrack = Pick<ReelProps, 'audio' | 'words' | 'questionMs' | 'optionsAtMs'>;

/** The question phase: the app clip timed word by word, or reading pace without one. */
async function questionTrack(raw: QuestionInput, q: ReelQuestion): Promise<QuestionTrack> {
	const displayWords = q.question.split(/\s+/).filter(Boolean);
	const audio = await stageAudio(raw);
	if (!audio) {
		const words: TimedWord[] = displayWords.map((text, i) => ({text, startMs: i * WORD_MS}));
		const optionsAtMs = displayWords.length * WORD_MS + 300;
		const questionMs = q.options.length ? optionsAtMs + q.options.length * 500 + 900 : Math.max(3500, optionsAtMs + 900);
		return {audio: null, words, questionMs, optionsAtMs};
	}
	const file = path.join(PUBLIC_AUDIO_DIR, path.basename(audio));
	await ensureWhisper();
	// MCQ clips also read the options: the stem is only the first part of them.
	const spoken = raw.spoken_text ?? [q.question, ...q.options].join(' ');
	const share = q.options.length ? Math.min(1, raw.question.length / spoken.length) : 1;
	const {words, optionsAtMs} = await timeWords(file, q.language, displayWords, share);
	return {audio, words, questionMs: audioDurationMs(file) + 400, optionsAtMs};
}

async function reelProps(raw: QuestionInput, q: ReelQuestion, hookIndex: number, style: ReelStyle): Promise<ReelProps> {
	return {q, ...(await questionTrack(raw, q)), hookIndex, style, explain: await explainTrack(raw, q)};
}

const slug = (s: string) => s.slice(0, 8);

async function main() {
	mkdirSync(OUT, {recursive: true});
	// Stage everything that goes into public/ before bundling (the bundle copies it).
	const jobs: {composition: string; props: ReelProps | RoundProps | CarouselSlideProps; name: string; still?: boolean; coverMs?: number}[] = [];

	if (values.round) {
		const ids = values.round.split(',').map((s) => s.trim());
		const raws = ids.map((id, k) => loadInput(id, k < ids.length - 1));
		const qs = raws.map((r) => ({...shapeQuestion(r), options: [], correctIndex: null}));
		const items = [];
		for (const [k, q] of qs.entries()) {
			const {audio, words, questionMs} = await questionTrack(raws[k], q);
			if (!audio) console.warn(`! ${q.id}: no existing app clip, rendering without voice (--make-voice makes one)`);
			items.push({q, audio, words, questionMs});
		}
		const explain = await explainTrack(raws[raws.length - 1], qs[qs.length - 1]);
		if (!explain.audio) console.warn(`! ${qs[qs.length - 1].id}: no explanation clip, explanation shown at reading pace`);
		const props: RoundProps = {items, hookIndex: 0, explain};
		const timeline = roundTimeline(
			items.map((it) => it.questionMs),
			explain.ms,
		);
		let coverMs = timeline.steps[0].cdStart - 200;
		while (eyeOpenAt(coverMs / 1000) < 1) coverMs -= 100;
		jobs.push({composition: 'Round', props, name: `round-${qs[0].language}-${slug(qs[0].id)}`, coverMs});
		console.log(`  ${(timeline.totalMs / 1000).toFixed(1)} s, ${items.length} questions`);
	} else if (values.carousel) {
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
		const style = {opening: values.opening, explain: values.explain} as ReelStyle;
		if (!['intro', 'fused', 'plain'].includes(style.opening) || !['line', 'parts', 'captions'].includes(style.explain))
			throw new Error('--opening intro|fused|plain, --explain line|parts|captions');
		const props = await reelProps(raw, format === 'five' ? {...q, options: [], correctIndex: null} : q, hook, style);
		if (!props.audio) console.warn(`! ${q.id}: no existing app clip, rendering without voice (--make-voice makes one)`);
		if (style.explain !== 'line' && !props.explain.audio) console.warn(`! ${q.id}: no explanation clip, explanation shown at reading pace (--make-voice makes one)`);
		const lead = style.opening === 'intro' ? 0 : LEAD_MS;
		const timeline = reelTimeline(style, props.questionMs + lead, props.explain.ms);
		// Cover = the question fully on screen, just before the countdown,
		// nudged back if the monkey happens to blink on that frame.
		let coverMs = timeline.cdStart - 200;
		while (eyeOpenAt(coverMs / 1000) < 1) coverMs -= 100;
		jobs.push({
			composition: format === 'abc' ? 'ABC' : 'FiveSeconds',
			props,
			name: `${format}-${q.language}-${slug(q.id)}`,
			coverMs,
		});
		console.log(`  ${(timeline.totalMs / 1000).toFixed(1)} s, voice: ${props.audio ? 'app clip' : 'none'}, explanation voice: ${props.explain.audio ? 'app clip' : 'none'}`);
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
