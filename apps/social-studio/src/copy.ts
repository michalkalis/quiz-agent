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
	/** Under a round's countdown: the answers come only at the end (founder 2026-10-25). */
	answersAtEnd: string;
	/** Fixed hook line of a round reel (research 2026-10-25: true by construction). */
	roundHook: (n: number) => string;
};

export const COPY: Record<Language, Copy> = {
	en: {
		// One fixed line (founder 2026-10-25); the second is the challenger for the weeks 4 to 6 test.
		hooks: ['Bet you know this one.', 'Can you get it right?'],
		answer: 'Answer',
		tagline: 'Trivia you answer out loud',
		soon: 'Coming soon to the App Store · trubbo.app',
		roundTitle: (p) => `Road trip round, part ${p}.`,
		roundSub: (n) => `${n} questions. Answers on the last slide.`,
		answersTitle: 'Answers',
		swipe: 'Swipe',
		answersAtEnd: 'Answers at the end',
		roundHook: (n) => `Can you get ${n} out of ${n}?`,
	},
	sk: {
		hooks: ['Stavím sa, že toto vieš.', 'Trafíš to?'],
		answer: 'Odpoveď',
		tagline: 'Kvíz, ktorý hráš hlasom',
		soon: 'Čoskoro v App Store · trubbo.app',
		roundTitle: (p) => `Kvíz na cestu, ${p}. diel.`,
		roundSub: (n) => `${n} ${n < 5 ? 'otázky' : 'otázok'}. Odpovede nájdeš na konci.`,
		answersTitle: 'Odpovede',
		swipe: 'Posuň',
		answersAtEnd: 'Odpovede na konci',
		roundHook: (n) => (n === 3 ? 'Trafíš všetky tri?' : n === 5 ? 'Trafíš všetkých päť?' : `Trafíš všetkých ${n}?`),
	},
	cs: {
		hooks: ['Vsadím se, že tohle víš.', 'Trefíš to?'],
		answer: 'Odpověď',
		tagline: 'Kvíz, který hraješ hlasem',
		soon: 'Brzy v App Store · trubbo.app',
		roundTitle: (p) => `Kvíz na cestu, ${p}. díl.`,
		roundSub: (n) => `${n} ${n < 5 ? 'otázky' : 'otázek'}. Odpovědi najdeš na konci.`,
		answersTitle: 'Odpovědi',
		swipe: 'Posuň',
		answersAtEnd: 'Odpovědi na konci',
		roundHook: (n) => (n === 3 ? 'Trefíš všechny tři?' : n === 5 ? 'Trefíš všech pět?' : `Trefíš všech ${n}?`),
	},
};

export const hookFor = (language: Language, index: number) => {
	const hooks = COPY[language].hooks;
	return hooks[((index % hooks.length) + hooks.length) % hooks.length];
};
