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
	/** Pinned launch reel, opening line (founder 2026-11-02: one pinned reel per account once 1.1 is live). */
	live: string;
	roundTitle: (part: number) => string;
	roundSub: (n: number) => string;
	answersTitle: string;
	swipe: string;
	/** Fixed hook line of a round reel (research 2026-10-25: true by construction). */
	roundHook: (n: number) => string;
	/** Opening line that says on its own what the reel is (founder 2026-10-27, variant A): `n` questions in a round, null = one question. */
	openLine: (n: number | null) => string;
};

export const COPY: Record<Language, Copy> = {
	en: {
		// One fixed line (founder 2026-10-25); the second is the challenger for the weeks 4 to 6 test.
		hooks: ['Bet you know this one.', 'Can you get it right?'],
		answer: 'Answer',
		tagline: 'Trivia you answer out loud',
		soon: 'Free on the App Store',
		live: 'Trubbo is now on the App Store.',
		roundTitle: (p) => `Quiz round, part ${p}.`,
		roundSub: (n) => `${n} questions. Answers on the last slide.`,
		answersTitle: 'Answers',
		swipe: 'Swipe',
		roundHook: (n) => `Can you get ${n} out of ${n}?`,
		openLine: (n) => (n === null ? 'One trivia question. Can you get it?' : `${n}\u00a0trivia questions. Can you get all ${n}?`),
	},
	sk: {
		hooks: ['Stavím sa, že toto vieš.', 'Trafíš to?'],
		answer: 'Odpoveď',
		tagline: 'Kvíz, ktorý hráš hlasom',
		soon: 'Zadarmo v App Store',
		live: 'Trubbo je už v App Store.',
		roundTitle: (p) => `Kvízové kolo, ${p}. diel.`,
		roundSub: (n) => `${n} ${n < 5 ? 'otázky' : 'otázok'}. Odpovede nájdeš na konci.`,
		answersTitle: 'Odpovede',
		swipe: 'Potiahni',
		roundHook: (n) => (n === 3 ? 'Trafíš všetky tri?' : n === 5 ? 'Trafíš všetkých päť?' : `Trafíš všetkých ${n}?`),
		openLine: (n) => (n === null ? 'Kvízová otázka. Trafíš ju?' : `${n}\u00a0${n < 5 ? 'kvízové otázky' : 'kvízových otázok'}. Trafíš všetky?`),
	},
	cs: {
		hooks: ['Vsadím se, že tohle víš.', 'Trefíš to?'],
		answer: 'Odpověď',
		tagline: 'Kvíz, který hraješ hlasem',
		soon: 'Zdarma v App Store',
		live: 'Trubbo je už v App Store.',
		roundTitle: (p) => `Kvízové kolo, ${p}. díl.`,
		roundSub: (n) => `${n} ${n < 5 ? 'otázky' : 'otázek'}. Odpovědi najdeš na konci.`,
		answersTitle: 'Odpovědi',
		swipe: 'Přejeď',
		roundHook: (n) => (n === 3 ? 'Trefíš všechny tři?' : n === 5 ? 'Trefíš všech pět?' : `Trefíš všech ${n}?`),
		openLine: (n) => (n === null ? 'Kvízová otázka. Trefíš ji?' : `${n}\u00a0${n < 5 ? 'kvízové otázky' : 'kvízových otázek'}. Trefíš všechny?`),
	},
};

export const hookFor = (language: Language, index: number) => {
	const hooks = COPY[language].hooks;
	return hooks[((index % hooks.length) + hooks.length) % hooks.length];
};

