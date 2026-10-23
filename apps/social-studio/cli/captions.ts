// Post captions from fixed per-language templates (#210 content plan,
// "Captions"): line 1 = the question (platform search), line 2 = the prompt,
// the app named in every 3rd post, 3–5 hashtags. No model writes captions;
// copy-style rules apply (no dashes as punctuation, gender-neutral sk/cs).
import type {Language} from '../src/types';
import {LETTERS} from '../src/copy';
import {noDashes} from './shape';

export type PostFormat = 'five' | 'abc' | 'carousel';

// `abc` gets the option letters already joined ("A, B or C", "A, B, C or D").
const T: Record<Language, {five: string; abc: (letters: string) => string; carousel: string; app: string; or: string; tags: string[]}> = {
	en: {
		five: 'Your answer in the comments before the reveal.',
		abc: (l) => `${l}? Comment before the reveal.`,
		or: 'or',
		carousel: 'How many did you get right? Comment your score.',
		app: 'Trubbo, trivia you answer out loud. Coming soon to the App Store, link in bio.',
		tags: ['#trivia', '#quiz'],
	},
	sk: {
		five: 'Napíš odpoveď do komentára skôr, ako ju prezradíme.',
		abc: (l) => `${l}? Napíš do komentára skôr, ako prezradíme odpoveď.`,
		or: 'alebo',
		carousel: 'Koľko máš správne? Napíš do komentára.',
		app: 'Trubbo, kvíz, ktorý hráš hlasom. Čoskoro v App Store, odkaz v profile.',
		tags: ['#kvíz', '#kviz'],
	},
	cs: {
		five: 'Napiš odpověď do komentáře dřív, než ji prozradíme.',
		abc: (l) => `${l}? Napiš do komentáře dřív, než prozradíme odpověď.`,
		or: 'nebo',
		carousel: 'Kolik máš správně? Napiš do komentáře.',
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

/** `firstLine` = the question (reels) or the round title (carousel). */
export function caption(o: {language: Language; format: PostFormat; firstLine: string; categories: string[]; nameApp: boolean; options?: number}): string {
	const t = T[o.language];
	const letters = LETTERS.slice(0, o.options ?? 3);
	const prompt = o.format === 'abc' ? t.abc(`${letters.slice(0, -1).join(', ')} ${t.or} ${letters[letters.length - 1]}`) : t[o.format];
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
