// When points of the spoken text were said, by aligning it letter by letter
// with whisper's transcript. Whisper writes number words as digits ("Dva:
// Asi třetina" → "2, asi 3"), so counting characters drifts by whole options;
// an edit-distance alignment lets the unchanged words around them anchor
// every point to the right moment.

import type {Language} from '../src/types';

export type Spoken = {text: string; startMs: number; endMs: number};

// Whisper's digits back as the words the voice said ("2" → "dva"), so a label
// ("Dva:") lines up with its own word, not with a fraction like "třetina" → "3".
const NUMBER_WORDS: Record<Language, string[]> = {
	en: ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten'],
	sk: ['nula', 'jedna', 'dva', 'tri', 'štyri', 'päť', 'šesť', 'sedem', 'osem', 'deväť', 'desať'],
	cs: ['nula', 'jedna', 'dva', 'tři', 'čtyři', 'pět', 'šest', 'sedm', 'osm', 'devět', 'deset'],
};

const keep = (s: string) => s.toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');

/** For each character offset in `text`, when the voice reached it (ms). */
export function alignTimes(text: string, spoken: Spoken[], offsets: number[], language: Language): number[] {
	// The spoken text as letters/digits, each remembering its offset in `text`.
	const s: string[] = [];
	const sAt: number[] = [];
	for (let i = 0; i < text.length; i++) {
		const c = keep(text[i]);
		for (const ch of c) {
			s.push(ch);
			sAt.push(i);
		}
	}
	// The transcript the same way, each letter timed within its token.
	const w: string[] = [];
	const wMs: number[] = [];
	for (const t of spoken) {
		const word = keep(t.text);
		const cs = [...(/^\d+$/.test(word) ? (NUMBER_WORDS[language][Number(word)] ?? word) : word)];
		cs.forEach((ch, k) => {
			w.push(ch);
			wMs.push(t.startMs + ((t.endMs - t.startMs) * k) / cs.length);
		});
	}
	const endMs = spoken.length ? spoken[spoken.length - 1].endMs : 0;
	const n = s.length;
	const m = w.length;
	// Levenshtein table, then walk back to pair each spoken letter with a transcript letter.
	const d: Uint32Array[] = Array.from({length: n + 1}, () => new Uint32Array(m + 1));
	for (let i = 0; i <= n; i++) d[i][0] = i;
	for (let j = 0; j <= m; j++) d[0][j] = j;
	for (let i = 1; i <= n; i++) {
		for (let j = 1; j <= m; j++) {
			d[i][j] = Math.min(d[i - 1][j - 1] + (s[i - 1] === w[j - 1] ? 0 : 1), d[i - 1][j] + 1, d[i][j - 1] + 1);
		}
	}
	// pair[i] = transcript letter index the i-th spoken letter lines up with (a dropped letter
	// lines up with the next transcript letter, so it is timed when the voice moves on).
	const pair = new Array<number>(n).fill(m);
	let i = n;
	let j = m;
	while (i > 0 && j > 0) {
		if (d[i][j] === d[i - 1][j - 1] + (s[i - 1] === w[j - 1] ? 0 : 1)) {
			pair[--i] = --j;
		} else if (d[i][j] === d[i - 1][j] + 1) {
			pair[--i] = j;
		} else {
			j--;
		}
	}
	while (i > 0) pair[--i] = 0;
	return offsets.map((off) => {
		const k = sAt.findIndex((at) => at >= off);
		if (k < 0) return Math.round(endMs);
		return Math.round(pair[k] < m ? wMs[pair[k]] : endMs);
	});
}
