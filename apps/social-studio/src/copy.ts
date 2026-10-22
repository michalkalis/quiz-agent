// On-screen copy per language. Hooks come from the #210 content plan
// (docs/issues/issue-210-content-plan.md); never invent numbers here, and no
// dashes as punctuation (copy-style rule for public text).
import type {Language} from './types';

type Copy = {
	hooks: string[];
	answer: string;
	/** End card line under the logo (founder pick 2026-10-22: no call to action). */
	tagline: string;
	soon: string;
	roundTitle: (part: number) => string;
	roundSub: (n: number) => string;
	answersTitle: string;
	swipe: string;
	/** "Comment A, B or C" for however many options there are. */
	comment: (letters: string[]) => string;
};

const list = (letters: string[], or: string) =>
	letters.length < 2 ? letters.join('') : `${letters.slice(0, -1).join(', ')} ${or} ${letters[letters.length - 1]}`;

export const COPY: Record<Language, Copy> = {
	en: {
		hooks: [
			'Say it out loud. 5 seconds.',
			'Answer before the monkey does.',
			'One question. No googling.',
		],
		answer: 'Answer',
		tagline: 'Trivia you answer out loud',
		soon: 'Coming soon to the App Store · trubbo.app',
		roundTitle: (p) => `Road trip round, part ${p}.`,
		roundSub: (n) => `${n} questions. Answers on the last slide.`,
		answersTitle: 'Answers',
		swipe: 'Swipe',
		comment: (l) => `Comment ${list(l, 'or')}`,
	},
	sk: {
		hooks: [
			'Povedz to nahlas. Máš 5 sekúnd.',
			'Odpovedz skôr ako opička.',
			'Jedna otázka, bez googlenia.',
		],
		answer: 'Odpoveď',
		tagline: 'Kvíz, ktorý hráš hlasom',
		soon: 'Čoskoro v App Store · trubbo.app',
		roundTitle: (p) => `Kvíz na cestu, ${p}. diel.`,
		roundSub: (n) => `${n} ${n < 5 ? 'otázky' : 'otázok'}. Odpovede nájdeš na konci.`,
		answersTitle: 'Odpovede',
		swipe: 'Posuň',
		comment: (l) => `Napíš do komentára ${list(l, 'alebo')}`,
	},
	cs: {
		hooks: [
			'Řekni to nahlas. Máš 5 vteřin.',
			'Odpověz dřív než opička.',
			'Jedna otázka, bez googlení.',
		],
		answer: 'Odpověď',
		tagline: 'Kvíz, který hraješ hlasem',
		soon: 'Brzy v App Store · trubbo.app',
		roundTitle: (p) => `Kvíz na cestu, ${p}. díl.`,
		roundSub: (n) => `${n} ${n < 5 ? 'otázky' : 'otázek'}. Odpovědi najdeš na konci.`,
		answersTitle: 'Odpovědi',
		swipe: 'Posuň',
		comment: (l) => `Napiš do komentáře ${list(l, 'nebo')}`,
	},
};

export const LETTERS = ['A', 'B', 'C', 'D', 'E'];

export const hookFor = (language: Language, index: number) => {
	const hooks = COPY[language].hooks;
	return hooks[((index % hooks.length) + hooks.length) % hooks.length];
};
