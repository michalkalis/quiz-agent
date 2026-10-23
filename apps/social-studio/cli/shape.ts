// Turns a question row into on-screen text. Deterministic string handling
// only: the "why" line is the first sentence of the question's own
// explanation, never rewritten by a model.
import type {Language, ReelQuestion} from '../src/types';

/** Raw input: a prod row (fetch_question.py) or a hand-written JSON file. */
export type QuestionInput = {
	id: string;
	language: Language;
	category: string;
	question: string;
	/** Prod rows: correct_answer (+ headline_answer); JSON files may use `answer`. */
	answer?: string;
	correct_answer?: unknown;
	correct_answer_key?: string | null;
	headline_answer?: string | null;
	explanation?: string | null;
	/** Prod rows: {"a": "...", "b": "..."}; JSON files may pass a plain list. */
	possible_answers?: Record<string, string> | null;
	options?: string[];
	/** Existing app clip: local path or URL (JSON input), or base64 (prod fetch). */
	audio?: string | null;
	audio_b64?: string | null;
	spoken_text?: string;
	/** Prod rows: the question's source, shown on the approval page. */
	source_url?: string | null;
};

/** Public text rule: no dashes as punctuation (hyphenated words stay). */
export const noDashes = (s: string) =>
	s
		.replace(/\s+[—–-]\s+/g, ', ')
		.replace(/\s*[—–]\s*/g, ', ')
		.replace(/,\s*,/g, ',')
		.trim();

/** First full sentence of the explanation, never cut: the card fits it
 * (src/fitWhy.ts shrinks the font, or falls back to a clause ending at a comma). */
export const oneSentence = (text: string | null | undefined): string => {
	if (!text) return '';
	const clean = noDashes(text.replace(/\s+/g, ' ').trim());
	// A sentence ends at . ! ? followed by a space and an uppercase letter or quote
	// (so "Dr. Who" or "3.5" do not cut it).
	const m = clean.match(/^.+?[.!?](?=\s+["'„“A-ZÁČĎÉÍĽĹŇÓÔŔŠŤÚÝŽ])/u);
	return m ? m[0] : clean;
};

export const shapeQuestion = (raw: QuestionInput): ReelQuestion => {
	const entries = raw.possible_answers ? Object.entries(raw.possible_answers).sort(([a], [b]) => a.localeCompare(b)) : [];
	const options = raw.options ?? entries.map(([, v]) => v);
	const correct = String(
		raw.answer ??
			raw.headline_answer ??
			(Array.isArray(raw.correct_answer) ? raw.correct_answer[0] : raw.correct_answer) ??
			'',
	);
	let correctIndex: number | null = null;
	if (options.length > 0) {
		const byKey = entries.findIndex(([k]) => k === (raw.correct_answer_key ?? correct));
		const byText = options.findIndex((o) => o.trim().toLowerCase() === correct.trim().toLowerCase());
		correctIndex = byKey >= 0 ? byKey : byText >= 0 ? byText : null;
		if (correctIndex === null) throw new Error(`${raw.id}: correct answer "${correct}" is not one of the options`);
	}
	return {
		id: raw.id,
		language: raw.language,
		category: raw.category,
		question: noDashes(raw.question),
		answer: noDashes(correctIndex !== null ? options[correctIndex] : correct),
		why: oneSentence(raw.explanation),
		options: options.map(noDashes),
		correctIndex,
	};
};
