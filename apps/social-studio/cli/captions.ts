// Post captions from fixed per-language templates (#210 content plan,
// "Captions"): line 1 = the question (platform search), line 2 = an open question,
// the app named in every 3rd post, 3–5 hashtags. No model writes captions;
// copy-style rules apply (no dashes as punctuation, gender-neutral sk/cs).
import type {Language} from '../src/types';
import {noDashes} from './shape';

/** `round` = 3 or 5 questions in one reel, answers at the end. */
export type PostFormat = 'five' | 'abc' | 'carousel' | 'round';

// Open questions, never "comment A or B" or "comment your score": Instagram does not
// recommend posts that ask for a specific comment (founder 2026-10-25 + research).
const T: Record<Language, {five: string; abc: string; carousel: string; app: string; tags: string[]}> = {
	en: {
		five: 'Did you know it before the reveal?',
		abc: 'Which one is it? The answer comes at the end.',
		carousel: 'How many did you get right?',
		app: 'Trubbo, trivia you answer out loud. Coming soon to the App Store, link in bio.',
		tags: ['#trivia', '#quiz'],
	},
	sk: {
		five: 'Vieš to skôr, ako prezradíme odpoveď?',
		abc: 'Ktorá je správna? Odpoveď je na konci.',
		carousel: 'Koľko máš správne?',
		app: 'Trubbo, kvíz, ktorý hráš hlasom. Čoskoro v App Store, odkaz v profile.',
		tags: ['#kvíz', '#kviz'],
	},
	cs: {
		five: 'Víš to dřív, než prozradíme odpověď?',
		abc: 'Která je správná? Odpověď je na konci.',
		carousel: 'Kolik máš správně?',
		app: 'Trubbo, kvíz, který hraješ hlasem. Brzy v App Store, odkaz v profilu.',
		tags: ['#kvíz', '#kviz'],
	},
};

// One topical tag per category, per language.
const CATEGORY_TAG: Record<string, Record<Language, string>> = {
	entertainment: {en: '#popculture', sk: '#popkultúra', cs: '#popkultura'},
	'movies-music': {en: '#movies', sk: '#filmy', cs: '#filmy'},
	'science-nature': {en: '#science', sk: '#veda', cs: '#věda'},
	'geography-world': {en: '#geography', sk: '#cestovanie', cs: '#cestování'},
	history: {en: '#history', sk: '#história', cs: '#historie'},
	sports: {en: '#sports', sk: '#šport', cs: '#sport'},
	'food-everyday': {en: '#food', sk: '#jedlo', cs: '#jídlo'},
	general: {en: '#funfacts', sk: '#zaujímavosti', cs: '#zajímavosti'},
};

export function hashtags(language: Language, categories: string[], format: PostFormat): string[] {
	const tags = [...T[language].tags];
	for (const c of new Set(categories)) {
		const t = CATEGORY_TAG[c]?.[language];
		if (t && !tags.includes(t) && tags.length < 4) tags.push(t);
	}
	if (format === 'carousel') tags.push(language === 'en' ? '#roadtrip' : language === 'sk' ? '#naceste' : '#nacestu');
	else if (tags.length < 4) tags.push(language === 'en' ? '#didyouknow' : language === 'sk' ? '#vedomosti' : '#vědomosti');
	return tags.slice(0, 5);
}

/** `firstLine` = the question (reels), the round title (carousel) or the hook line (round). */
export function caption(o: {language: Language; format: PostFormat; firstLine: string; categories: string[]; nameApp: boolean}): string {
	const t = T[o.language];
	// A round asks for a score, like the carousel.
	const prompt = o.format === 'round' ? t.carousel : t[o.format];
	const parts = [noDashes(o.firstLine), prompt];
	if (o.nameApp) parts.push(t.app);
	parts.push(hashtags(o.language, o.categories, o.format).join(' '));
	return parts.join('\n\n');
}

/** YouTube Shorts title: the question, cut at a word under 100 characters. */
export function youtubeTitle(question: string): string {
	const q = noDashes(question);
	if (q.length <= 100) return q;
	return `${q.slice(0, 97).replace(/\s+\S*$/, '')}…`;
}
