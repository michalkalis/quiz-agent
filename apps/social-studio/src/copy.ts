// On-screen copy per language. Hooks come from the #210 content plan
// (docs/issues/issue-210-content-plan.md); never invent numbers here, and no
// dashes as punctuation (copy-style rule for public text).
import type {Language} from './types';

type Copy = {
	hooks: string[];
	answer: string;
	/** "Question" before a round question's number. */
	question: string;
	/** End card line under the logo (founder pick 2026-10-22: no call to action). */
	tagline: string;
	soon: string;
	roundTitle: (part: number) => string;
	roundSub: (n: number) => string;
	answersTitle: string;
	swipe: string;
	/** Under a round's countdown: the answers come only at the end (founder 2026-10-25). */
	answersAtEnd: string;
	/** Fixed hook line of a round reel (research 2026-10-25: true by construction). */
	roundHook: (n: number) => string;
	/** Label above the opening line (founder 2026-10-27: the hook alone does not say what the reel is). */
	quizLabel: (n: number) => string;
	/** A round's opening line under that label. */
	roundLine: string;
};

export const COPY: Record<Language, Copy> = {
	en: {
		// One fixed line (founder 2026-10-25); the second is the challenger for the weeks 4 to 6 test.
		hooks: ['Bet you know this one.', 'Can you get it right?'],
		answer: 'Answer',
		question: 'Question',
		tagline: 'Trivia you answer out loud',
		soon: 'Coming soon to the App Store · trubbo.app',
		roundTitle: (p) => `Road trip round, part ${p}.`,
		roundSub: (n) => `${n} questions. Answers on the last slide.`,
		answersTitle: 'Answers',
		swipe: 'Swipe',
		answersAtEnd: 'Answers at the end',
		roundHook: (n) => `Can you get ${n} out of ${n}?`,
		quizLabel: (n) => `Quiz · ${n} ${n === 1 ? 'question' : 'questions'}`,
		roundLine: 'Can you get them all?',
	},
	sk: {
		hooks: ['Stavím sa, že toto vieš.', 'Trafíš to?'],
		answer: 'Odpoveď',
		question: 'Otázka',
		tagline: 'Kvíz, ktorý hráš hlasom',
		soon: 'Čoskoro v App Store · trubbo.app',
		roundTitle: (p) => `Kvíz na cestu, ${p}. diel.`,
		roundSub: (n) => `${n} ${n < 5 ? 'otázky' : 'otázok'}. Odpovede nájdeš na konci.`,
		answersTitle: 'Odpovede',
		swipe: 'Posuň',
		answersAtEnd: 'Odpovede na konci',
		roundHook: (n) => (n === 3 ? 'Trafíš všetky tri?' : n === 5 ? 'Trafíš všetkých päť?' : `Trafíš všetkých ${n}?`),
		quizLabel: (n) => `Kvíz · ${n} ${n === 1 ? 'otázka' : n < 5 ? 'otázky' : 'otázok'}`,
		roundLine: 'Trafíš všetky?',
	},
	cs: {
		hooks: ['Vsadím se, že tohle víš.', 'Trefíš to?'],
		answer: 'Odpověď',
		question: 'Otázka',
		tagline: 'Kvíz, který hraješ hlasem',
		soon: 'Brzy v App Store · trubbo.app',
		roundTitle: (p) => `Kvíz na cestu, ${p}. díl.`,
		roundSub: (n) => `${n} ${n < 5 ? 'otázky' : 'otázek'}. Odpovědi najdeš na konci.`,
		answersTitle: 'Odpovědi',
		swipe: 'Posuň',
		answersAtEnd: 'Odpovědi na konci',
		roundHook: (n) => (n === 3 ? 'Trefíš všechny tři?' : n === 5 ? 'Trefíš všech pět?' : `Trefíš všech ${n}?`),
		quizLabel: (n) => `Kvíz · ${n} ${n === 1 ? 'otázka' : n < 5 ? 'otázky' : 'otázek'}`,
		roundLine: 'Trefíš všechny?',
	},
};

export const hookFor = (language: Language, index: number) => {
	const hooks = COPY[language].hooks;
	return hooks[((index % hooks.length) + hooks.length) % hooks.length];
};


/** Opening screen: label + line; `n` = questions in a round, null = a one-question reel. */
export const opener = (language: Language, n: number | null, hookIndex: number) => ({
	kicker: COPY[language].quizLabel(n ?? 1),
	line: n === null ? hookFor(language, hookIndex) : COPY[language].roundLine,
});
