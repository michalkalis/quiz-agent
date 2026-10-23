// npm run batch -- [--monday YYYY-MM-DD] [--dry-run]
//
// Weekly batch (#210 sub-task 210.4): picks approved questions for next week's
// posts on both Instagram accounts (EN, SK/CZ), renders them with cli/render.ts,
// writes captions + hashtags, and saves batches/<week>.json. The manifests are
// the posted log: a question in any earlier manifest is never picked again.
// Week per account (content plan): Mon 5 Seconds · Tue Road Trip Round
// (carousel) · Wed A, B or C · Fri 5 Seconds. Thu "How it plays" is not built
// yet, so that slot stays empty.
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {parseArgs} from 'node:util';
import type {Language} from '../src/types';
import {caption, youtubeTitle, type PostFormat} from './captions';
import {APP_DIR, BATCH_DIR, CACHE_DIR, VOICE_LEDGER, VOICES_PER_WEEK} from './paths';
import {shapeQuestion, type QuestionInput} from './shape';

const {values} = parseArgs({options: {monday: {type: 'string'}, 'dry-run': {type: 'boolean', default: false}}});

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
};
type Account = 'ig_en' | 'ig_skcz';
type Slot = {account: Account; day: 'Mon' | 'Tue' | 'Wed' | 'Fri'; format: PostFormat; language: Language};

const CAROUSEL_SIZE = 7;
const REEL_MAX_CHARS = 150; // longer questions do not read well in a ~17 s reel
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
const dayDate = (day: Slot['day']) => {
	const d = new Date(`${MONDAY}T00:00:00Z`);
	d.setUTCDate(d.getUTCDate() + {Mon: 0, Tue: 1, Wed: 2, Fri: 4}[day]);
	return d.toISOString().slice(0, 10);
};

type Manifest = {week: string; posts: {format: PostFormat; language: Language; questions: {id: string}[]}[]};
const earlier: Manifest[] = existsSync(BATCH_DIR)
	? readdirSync(BATCH_DIR)
			.filter((f) => /^\d{4}-W\d{2}\.json$/.test(f) && f !== `${WEEK.id}.json`)
			.map((f) => JSON.parse(readFileSync(path.join(BATCH_DIR, f), 'utf8')))
	: [];
const used = new Set(earlier.flatMap((m) => m.posts.flatMap((p) => p.questions.map((q) => q.id))));

function voicesLeft(): number {
	if (!existsSync(VOICE_LEDGER)) return VOICES_PER_WEEK;
	const weekAgo = Date.now() - 7 * 24 * 3600 * 1000;
	const recent = (JSON.parse(readFileSync(VOICE_LEDGER, 'utf8')) as {at: string}[]).filter((e) => Date.parse(e.at) >= weekAgo);
	return Math.max(0, VOICES_PER_WEEK - recent.length);
}

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

// Founder/rater score first (unrated = a little under the 8/10 bar), then
// fresh pop culture; a per-week jitter keeps equal rows from always winning.
function score(c: Candidate): number {
	const jitter = parseInt(createHash('sha1').update(c.id + WEEK.id).digest('hex').slice(0, 6), 16) / 0xffffff;
	return (c.rating ?? 0.7) + (c.topicality ? 0.1 : 0) + (['entertainment', 'movies-music'].includes(c.category) ? 0.05 : 0) + jitter * 0.1;
}

const fitsAccount = (c: Candidate, s: Slot) =>
	c.language === s.language && (s.account === 'ig_en' ? c.local_scope === null : [null, 'sk', 'cz'].includes(c.local_scope));

function plan(): Slot[] {
	// SK/CZ: one language per post, alternating, flipped every week.
	const [a, b]: Language[] = WEEK.n % 2 ? ['sk', 'cs'] : ['cs', 'sk'];
	const week: [Slot['day'], PostFormat, Language, Language][] = [
		['Mon', 'five', 'en', a],
		['Tue', 'carousel', 'en', b],
		['Wed', 'abc', 'en', a],
		['Fri', 'five', 'en', b],
	];
	return week.flatMap(([day, format, en, skcz]) => [
		{account: 'ig_en' as const, day, format, language: en},
		{account: 'ig_skcz' as const, day, format, language: skcz},
	]);
}

type Pick = {slot: Slot; ids: string[]; makeVoice: boolean};

function pick(cands: Candidate[]): Pick[] {
	const taken = new Set(used);
	const byScore = [...cands].sort((x, y) => score(y) - score(x));
	let voices = voicesLeft();
	const picks: Pick[] = [];
	const reelCategories: Record<Account, Set<string>> = {ig_en: new Set(), ig_skcz: new Set()};
	// Slots with the fewest existing clips first (MCQ, then cs), so they get
	// the weekly voice budget and the others use clips the app already made.
	const clips = (s: Slot) => cands.filter((c) => c.has_clip && c.mcq === (s.format === 'abc') && fitsAccount(c, s)).length;
	const order = plan().sort((x, y) => Number(y.format === 'abc') - Number(x.format === 'abc') || clips(x) - clips(y));
	for (const slot of order) {
		const pool = byScore.filter((c) => !taken.has(c.id) && fitsAccount(c, slot));
		if (slot.format === 'carousel') {
			const ids: string[] = [];
			const perCategory: Record<string, number> = {};
			for (const c of pool) {
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
		const c = pool.find(
			(c) =>
				c.mcq === (slot.format === 'abc') &&
				c.chars <= REEL_MAX_CHARS &&
				!reelCategories[slot.account].has(c.category) &&
				(c.has_clip || voices > 0),
		);
		if (!c) {
			console.warn(`! ${slot.account} ${slot.day} ${slot.format} ${slot.language}: no question with a voice clip left this week, slot skipped`);
			continue;
		}
		if (!c.has_clip) voices--;
		taken.add(c.id);
		reelCategories[slot.account].add(c.category);
		picks.push({slot, ids: [c.id], makeVoice: !c.has_clip});
	}
	const dayOrder = ['Mon', 'Tue', 'Wed', 'Fri'];
	return picks.sort((x, y) => dayOrder.indexOf(x.slot.day) - dayOrder.indexOf(y.slot.day) || x.slot.account.localeCompare(y.slot.account));
}

const row = (id: string): QuestionInput => JSON.parse(readFileSync(path.join(CACHE_DIR, 'rows', `${id}.native.json`), 'utf8'));

function render(args: string[]): string[] {
	const out = execFileSync('npx', ['tsx', path.join(APP_DIR, 'cli', 'render.ts'), ...args], {cwd: APP_DIR, stdio: ['ignore', 'pipe', 'inherit']}).toString();
	process.stdout.write(out);
	return [...out.matchAll(/^✓ (.+)$/gm)].map((m) => path.basename(m[1]));
}

function main() {
	const picks = pick(loadCandidates());
	console.log(`${WEEK.id} (from ${MONDAY}): ${picks.length} posts, ${picks.filter((p) => p.makeVoice).length} new voice clips (${voicesLeft()} left this week)`);
	for (const p of picks) console.log(`  ${p.slot.day} ${p.slot.account} ${p.slot.format} ${p.slot.language}: ${p.ids.join(',')}${p.makeVoice ? ' (new voice)' : ''}`);
	if (values['dry-run']) return;

	const outDir = path.join(APP_DIR, 'out', WEEK.id);
	const carouselParts: Partial<Record<Language, number>> = {};
	for (const m of earlier) for (const p of m.posts) if (p.format === 'carousel') carouselParts[p.language] = (carouselParts[p.language] ?? 0) + 1;
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
			key: `${slot.day.toLowerCase()}-${slot.account}`,
			...slot,
			date: dayDate(slot.day),
			files,
			caption: text,
			// Shorts: the EN account's reels only (one YouTube channel, English).
			youtube: slot.account === 'ig_en' && slot.format !== 'carousel' ? {title: youtubeTitle(questions[0].question), description: text} : null,
			voice: slot.format === 'carousel' ? null : makeVoice ? 'made this week' : 'existing app clip',
			questions,
		});
	}
	mkdirSync(BATCH_DIR, {recursive: true});
	const file = path.join(BATCH_DIR, `${WEEK.id}.json`);
	writeFileSync(file, JSON.stringify({week: WEEK.id, monday: MONDAY, created: new Date().toISOString(), posts}, null, 1));
	console.log(`✓ ${file}\n  media in ${outDir}`);
}

main();
