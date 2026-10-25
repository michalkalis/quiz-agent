// npm run batch -- [--monday YYYY-MM-DD] [--seed] [--dry-run]
//
// Weekly batch (#210 sub-task 210.4): picks approved questions for next week's
// posts on both Instagram accounts (EN, SK/CZ), renders them with cli/render.ts,
// writes captions + hashtags, and saves batches/<week>.json. The manifests are
// the posted log: a question in any earlier manifest is never picked again.
// Week per account (founder 2026-10-24: 5 reels + 2 carousels): Mon, Thu, Fri,
// Sun 5 Seconds · Wed A, B or C · Tue and Sat Road Trip Round (carousel).
// Only questions that passed the content review (batches/content-review.json,
// verdict "keep") are picked, strongest first.
// --seed (founder 2026-10-23): six launch posts per account on the weekend
// before that Monday, 10:00 / 14:00 / 18:00, added to the week's existing
// manifest so one approval page shows them all.
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {parseArgs} from 'node:util';
import type {Language} from '../src/types';
import {caption, youtubeTitle, type PostFormat} from './captions';
import {APP_DIR, BATCH_DIR, CACHE_DIR, VOICE_LEDGER, voiceCharsLeft} from './paths';
import {shapeQuestion, type QuestionInput} from './shape';

const {values} = parseArgs({
	options: {monday: {type: 'string'}, seed: {type: 'boolean', default: false}, 'dry-run': {type: 'boolean', default: false}},
});
const SEED = values.seed;

type Candidate = {
	id: string;
	language: Language;
	category: string;
	chars: number;
	answer_chars: number;
	mcq: boolean;
	local_scope: string | null;
	topicality: string | null;
	rating: number | null;
	has_clip: boolean;
	options: Record<string, string> | null;
	explanation: string | null;
};
type Account = 'ig_en' | 'ig_skcz';
type Day = 'Mon' | 'Tue' | 'Wed' | 'Thu' | 'Fri' | 'Sat' | 'Sun';
/** Seed slots are the weekend before Monday; weekly slots run Mon..Sun. */
type Slot = {account: Account; day: Day; format: PostFormat; language: Language; time?: string; n?: number; before?: boolean};

const CAROUSEL_SIZE = 7;
// Founder 2026-10-24: a reel question reads in under ~6 s of voice.
const REEL_MAX_CHARS = 90;
const MCQ_MAX_CHARS = 70;
const MCQ_MAX_OPTION = 22;
const CAROUSEL_MAX_CHARS = 120;
const CAROUSEL_MAX_ANSWER = 30;

function nextMonday(): string {
	const d = new Date();
	d.setUTCDate(d.getUTCDate() + ((8 - d.getUTCDay()) % 7 || 7));
	return d.toISOString().slice(0, 10);
}
const MONDAY = values.monday ?? nextMonday();

function isoWeek(day: string): {id: string; n: number} {
	const d = new Date(`${day}T00:00:00Z`);
	d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay() || 7));
	const yearStart = Date.UTC(d.getUTCFullYear(), 0, 1);
	const n = Math.ceil(((d.getTime() - yearStart) / 86400000 + 1) / 7);
	return {id: `${d.getUTCFullYear()}-W${String(n).padStart(2, '0')}`, n};
}
const WEEK = isoWeek(MONDAY);
const DAYS: Day[] = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const dayOffset = (s: {day: Day; before?: boolean}) => DAYS.indexOf(s.day) - (s.before ? 7 : 0);
const dayDate = (s: {day: Day; before?: boolean}) => {
	const d = new Date(`${MONDAY}T00:00:00Z`);
	d.setUTCDate(d.getUTCDate() + dayOffset(s));
	return d.toISOString().slice(0, 10);
};

type Manifest = {week: string; monday: string; created: string; posts: {key: string; format: PostFormat; language: Language; status?: string; questions: {id: string}[]}[]};
const WEEK_FILE = path.join(BATCH_DIR, `${WEEK.id}.json`);
const earlier: Manifest[] = existsSync(BATCH_DIR)
	? readdirSync(BATCH_DIR)
			.filter((f) => /^\d{4}-W\d{2}\.json$/.test(f) && f !== `${WEEK.id}.json`)
			.map((f) => JSON.parse(readFileSync(path.join(BATCH_DIR, f), 'utf8')))
	: [];
// --seed adds to this week's manifest, so its questions are taken too. A
// re-run of a week keeps only its posts that already went out (the posted log).
const existing: Manifest | null = existsSync(WEEK_FILE) ? JSON.parse(readFileSync(WEEK_FILE, 'utf8')) : null;
const current: Manifest | null = existing && (SEED ? existing : {...existing, posts: existing.posts.filter((p) => p.status === 'published')});
const used = new Set([...earlier, ...(current ? [current] : [])].flatMap((m) => m.posts.flatMap((p) => p.questions.map((q) => q.id))));

function voiceCharsAvailable(): number {
	return voiceCharsLeft(existsSync(VOICE_LEDGER) ? JSON.parse(readFileSync(VOICE_LEDGER, 'utf8')) : []);
}

/** Characters a reel's new clips cost: the question when the app has no clip
 * yet, plus the explanation (rarely voiced by players, so assumed missing). */
const voiceCost = (c: Candidate) => (c.has_clip ? 0 : c.chars) + (c.explanation?.length ?? 0);

function loadCandidates(): Candidate[] {
	const file = path.join(CACHE_DIR, `candidates-${new Date().toISOString().slice(0, 10)}.json`);
	if (existsSync(file)) return JSON.parse(readFileSync(file, 'utf8'));
	const out = execFileSync('fly', ['ssh', 'console', '-a', 'quiz-agent-api', '-C', 'python - --candidates'], {
		input: readFileSync(path.join(APP_DIR, 'scripts', 'fetch_question.py')),
		maxBuffer: 64 * 1024 * 1024,
		stdio: ['pipe', 'pipe', 'ignore'],
	}).toString();
	const marker = out.indexOf('@@JSON@@');
	if (marker < 0) throw new Error('prod candidates fetch returned no data');
	mkdirSync(CACHE_DIR, {recursive: true});
	writeFileSync(file, out.slice(marker + 8).trim());
	return JSON.parse(out.slice(marker + 8));
}

/** Content review before a batch (founder 2026-10-24: approved is not enough
 * for Instagram). Only "keep" is picked; "drop" and "hold" (a defect to fix
 * in the app first) never are. Unreviewed questions are not picked either. */
type Review = {verdict: 'keep' | 'drop' | 'hold'; stop_power: number; note: string};
const REVIEW: Record<string, Review> = JSON.parse(readFileSync(path.join(BATCH_DIR, 'content-review.json'), 'utf8'));

// Reviewer's stop power first (would a stranger stop scrolling), then the
// founder/rater score; a per-week jitter keeps equal rows from always winning.
function score(c: Candidate): number {
	const jitter = parseInt(createHash('sha1').update(c.id + WEEK.id).digest('hex').slice(0, 6), 16) / 0xffffff;
	return (REVIEW[c.id]?.stop_power ?? 0) / 10 + (c.rating ?? 0.7) * 0.3 + jitter * 0.05;
}

const fitsAccount = (c: Candidate, s: Slot) =>
	c.language === s.language && (s.account === 'ig_en' ? c.local_scope === null : [null, 'sk', 'cz'].includes(c.local_scope));

function plan(): Slot[] {
	// SK/CZ: one language per post, alternating, flipped every week.
	const [a, b]: Language[] = WEEK.n % 2 ? ['sk', 'cs'] : ['cs', 'sk'];
	const week: [Day, PostFormat, Language, Language][] = [
		['Mon', 'five', 'en', a],
		['Tue', 'carousel', 'en', b],
		['Wed', 'abc', 'en', a],
		['Thu', 'five', 'en', b],
		['Fri', 'five', 'en', a],
		['Sat', 'carousel', 'en', a],
		['Sun', 'five', 'en', b],
	];
	return week.flatMap(([day, format, en, skcz]) => [
		{account: 'ig_en' as const, day, format, language: en},
		{account: 'ig_skcz' as const, day, format, language: skcz},
	]);
}

// Launch posts. EN reels only: its clips are there and its carousel part 1
// runs Tuesday. SK/CZ carousels in cs only (no cs carousel yet; the sk part 1
// runs Tuesday), so part numbers go up in posting order.
function seedPlan(): Slot[] {
	const en: PostFormat[] = ['five', 'five', 'abc', 'five', 'five', 'five'];
	const skcz: [PostFormat, Language][] = [['five', 'sk'], ['carousel', 'cs'], ['five', 'cs'], ['abc', 'sk'], ['carousel', 'cs'], ['five', 'sk']];
	return en.flatMap((format, i) => {
		const at = {day: (i < 3 ? 'Sat' : 'Sun') as Day, before: true, time: ['10:00', '14:00', '18:00'][i % 3], n: (i % 3) + 1};
		return [
			{account: 'ig_en' as const, ...at, format, language: 'en' as Language},
			{account: 'ig_skcz' as const, ...at, format: skcz[i][0], language: skcz[i][1]},
		];
	});
}

type Pick = {slot: Slot; ids: string[]; makeVoice: boolean};

function pick(cands: Candidate[]): Pick[] {
	const taken = new Set(used);
	const byScore = cands.filter((c) => REVIEW[c.id]?.verdict === 'keep').sort((x, y) => score(y) - score(x));
	let voiceChars = voiceCharsAvailable();
	const picks: Pick[] = [];
	const reelCategories: Record<Account, Record<string, number>> = {ig_en: {}, ig_skcz: {}};
	// Slots with the fewest existing clips first (MCQ, then cs), so they get
	// the weekly voice budget and the others use clips the app already made.
	const clips = (s: Slot) => cands.filter((c) => c.has_clip && c.mcq === (s.format === 'abc') && fitsAccount(c, s)).length;
	// Reels pick first: carousels can use the longer questions a reel cannot.
	const rank = (s: Slot) => ({abc: 0, five: 1, carousel: 2})[s.format];
	const order = (SEED ? seedPlan() : plan()).sort((x, y) => rank(x) - rank(y) || clips(x) - clips(y));
	for (const slot of order) {
		const pool = byScore.filter((c) => !taken.has(c.id) && fitsAccount(c, slot));
		if (slot.format === 'carousel') {
			const ids: string[] = [];
			const perCategory: Record<string, number> = {};
			// Questions too long for a reel first, so short ones stay for the reels.
			const longFirst = [...pool.filter((c) => c.chars > REEL_MAX_CHARS), ...pool.filter((c) => c.chars <= REEL_MAX_CHARS)];
			for (const c of longFirst) {
				if (c.mcq || c.chars > CAROUSEL_MAX_CHARS || c.answer_chars > CAROUSEL_MAX_ANSWER || (perCategory[c.category] ?? 0) >= 2) continue;
				ids.push(c.id);
				perCategory[c.category] = (perCategory[c.category] ?? 0) + 1;
				if (ids.length === CAROUSEL_SIZE) break;
			}
			if (ids.length < CAROUSEL_SIZE) throw new Error(`${slot.account} ${slot.day}: only ${ids.length} carousel questions left`);
			ids.forEach((id) => taken.add(id));
			picks.push({slot, ids, makeVoice: false});
			continue;
		}
		const short = (c: Candidate) =>
			c.mcq ? c.chars <= MCQ_MAX_CHARS && Object.values(c.options ?? {}).every((o) => o.length <= MCQ_MAX_OPTION) : c.chars <= REEL_MAX_CHARS;
		// At most two reels of one category a week per account, so the colours vary.
		const fits = (c: Candidate) => c.mcq === (slot.format === 'abc') && short(c) && (reelCategories[slot.account][c.category] ?? 0) < 2;
		// An existing clip first, so the voice budget goes where there is none.
		const c = pool.find((c) => fits(c) && voiceCost(c) <= voiceChars);
		if (!c) {
			console.warn(`! ${slot.account} ${slot.day} ${slot.format} ${slot.language}: no reviewed question fits (or the weekly voice budget is used up), slot skipped`);
			continue;
		}
		voiceChars -= voiceCost(c);
		taken.add(c.id);
		reelCategories[slot.account][c.category] = (reelCategories[slot.account][c.category] ?? 0) + 1;
		picks.push({slot, ids: [c.id], makeVoice: true});
	}
	return picks.sort(
		(x, y) => dayOffset(x.slot) - dayOffset(y.slot) || (x.slot.n ?? 0) - (y.slot.n ?? 0) || x.slot.account.localeCompare(y.slot.account),
	);
}

const row = (id: string): QuestionInput => JSON.parse(readFileSync(path.join(CACHE_DIR, 'rows', `${id}.native.json`), 'utf8'));

function render(args: string[]): string[] {
	const out = execFileSync('npx', ['tsx', path.join(APP_DIR, 'cli', 'render.ts'), ...args], {cwd: APP_DIR, stdio: ['ignore', 'pipe', 'inherit']}).toString();
	process.stdout.write(out);
	return [...out.matchAll(/^✓ (.+)$/gm)].map((m) => path.basename(m[1]));
}

function main() {
	const picks = pick(loadCandidates());
	console.log(`${WEEK.id} (from ${MONDAY}): ${picks.length} posts, voice budget ${voiceCharsAvailable()} characters left this week`);
	for (const p of picks) console.log(`  ${p.slot.day} ${p.slot.account} ${p.slot.format} ${p.slot.language}: ${p.ids.join(',')}`);
	if (values['dry-run']) return;

	const outDir = path.join(APP_DIR, 'out', WEEK.id);
	const carouselParts: Partial<Record<Language, number>> = {};
	for (const m of [...earlier, ...(current ? [current] : [])]) for (const p of m.posts) if (p.format === 'carousel') carouselParts[p.language] = (carouselParts[p.language] ?? 0) + 1;
	const posts = [];
	let n = 0;
	for (const {slot, ids, makeVoice} of picks) {
		let files: string[];
		let firstLine: string;
		if (slot.format === 'carousel') {
			const part = (carouselParts[slot.language] = (carouselParts[slot.language] ?? 0) + 1);
			files = render(['--carousel', ids.join(','), '--part', String(part), '--out', outDir]);
			firstLine = {en: `Road trip round, part ${part}.`, sk: `Kvíz na cestu, ${part}. diel.`, cs: `Kvíz na cestu, ${part}. díl.`}[slot.language];
		} else {
			files = render([ids[0], '--format', slot.format, '--out', outDir, ...(makeVoice ? ['--make-voice'] : [])]);
			firstLine = row(ids[0]).question;
		}
		const rows = ids.map(row);
		const questions = rows.map((r) => {
			const q = shapeQuestion(r);
			return {id: q.id, category: q.category, question: q.question, answer: q.answer, options: q.options, explanation: r.explanation ?? '', source_url: r.source_url ?? null};
		});
		const text = caption({language: slot.language, format: slot.format, firstLine, categories: questions.map((q) => q.category), nameApp: ++n % 3 === 0, options: questions[0].options.length});
		posts.push({
			key: `${slot.day.toLowerCase()}${slot.n ?? ''}-${slot.account}`,
			...slot,
			date: dayDate(slot),
			files,
			caption: text,
			// Shorts: the EN account's reels only (one YouTube channel, English).
			youtube: slot.account === 'ig_en' && slot.format !== 'carousel' ? {title: youtubeTitle(questions[0].question), description: text} : null,
			voice: slot.format === 'carousel' ? null : 'app voice: question + explanation',
			questions,
		});
	}
	mkdirSync(BATCH_DIR, {recursive: true});
	const manifest = current ? {...current, posts: [...posts, ...current.posts]} : {week: WEEK.id, monday: MONDAY, created: new Date().toISOString(), posts};
	writeFileSync(WEEK_FILE, JSON.stringify(manifest, null, 1));
	console.log(`✓ ${WEEK_FILE}\n  media in ${outDir}`);
}

main();
