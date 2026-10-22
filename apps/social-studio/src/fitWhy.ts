// Fits the "why" sentence onto a card without cutting it mid-sentence: the
// whole sentence at the largest font size that keeps it within `maxLines`,
// down to `minSize`; only if it still does not fit, the longest part of it
// that ends at a comma. The text itself is never rewritten.
import {FONT} from './theme';

type Fit = {text: string; size: number};
type Box = {width: number; maxLines: number; size: number; minSize: number; weight?: number};

let ctx: CanvasRenderingContext2D | null = null;

/** Lines the text wraps to at this size (greedy word wrap, like the browser). */
const lineCount = (text: string, size: number, width: number, weight: number): number => {
	ctx ??= document.createElement('canvas').getContext('2d');
	if (!ctx) return 1;
	ctx.font = `${weight} ${size}px ${FONT}`;
	let lines = 1;
	let line = '';
	for (const word of text.split(' ')) {
		const next = line ? `${line} ${word}` : word;
		if (line && ctx.measureText(next).width > width) {
			lines++;
			line = word;
		} else line = next;
	}
	return lines;
};

/** The sentence up to each comma, longest first, without the comma. */
const commaClauses = (sentence: string): string[] =>
	[...sentence.matchAll(/,(?=\s)/g)]
		.map((m) => sentence.slice(0, m.index).trim())
		.filter(Boolean)
		.reverse();

export const fitWhy = (sentence: string, {width, maxLines, size, minSize, weight = 500}: Box): Fit => {
	if (!sentence || typeof document === 'undefined') return {text: sentence, size};
	const usable = width * 0.97; // canvas vs layout rounding
	for (const text of [sentence, ...commaClauses(sentence)]) {
		for (let s = size; s >= minSize; s -= 2) {
			if (lineCount(text, s, usable, weight) <= maxLines) return {text, size: s};
		}
	}
	const clauses = commaClauses(sentence);
	return {text: clauses.length ? clauses[clauses.length - 1] : sentence, size: minSize};
};
