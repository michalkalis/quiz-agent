// Reel timeline (ms). The question phase length comes from the voice clip,
// or from reading time when there is no clip; the explanation phase likewise.
import type {ReelStyle} from './types';

export const HOOK_MS = 1500;
/** The hook alone on screen before the question (`solo` opening). */
export const HOOK_SOLO_MS = 1700;
/** Question shown before the voice starts, so frame 1 already reads. */
export const LEAD_MS = 250;
export const COUNTDOWN_MS = 5000;
/** v1 reveal: answer + first sentence. */
export const REVEAL_MS = 4000;
/** The answer alone before the explanation starts. */
export const ANSWER_MS = 1400;
/** The last explanation words stay up this long after the voice ends. */
export const WHY_TAIL_MS = 900;
export const END_MS = 2000;

/** `card`: the answer is read (`answerMs`), then the whole explanation (`whyChars`) stays up to be read. */
export const reelTimeline = (style: ReelStyle, questionMs: number, explainMs: number, answerMs = 0, whyChars = 0) => {
	const qStart = style.opening === 'intro' ? HOOK_MS : style.opening === 'solo' ? HOOK_SOLO_MS : 0;
	const cdStart = qStart + questionMs;
	const revealStart = cdStart + COUNTDOWN_MS;
	const card = style.explain === 'card';
	const whyStart = card ? revealStart + ANSWER_LEAD_MS + answerMs : revealStart + ANSWER_MS;
	const endStart =
		style.explain === 'line' ? revealStart + REVEAL_MS : card ? whyStart + whyHoldMs(whyChars, 10000) : whyStart + explainMs + WHY_TAIL_MS;
	return {qStart, cdStart, revealStart, whyStart, endStart, totalMs: endStart + END_MS};
};

/** Monkey eyelid openness (1 = open) at `t` seconds: a ~0.2 s blink every 2.6 s. */
export const eyeOpenAt = (t: number) => {
	const phase = (((t + 0.6) % 2.6) + 2.6) % 2.6;
	if (phase >= 0.2) return 1;
	return phase < 0.07 ? 1 - (phase / 0.07) * 0.88 : phase < 0.13 ? 0.12 : 0.12 + ((phase - 0.13) / 0.07) * 0.88;
};

/** Round reel (founder 2026-10-25): 3 or 5 questions in a row, each with a
 * countdown, then its answer right away (founder 2026-10-29: no longer all at
 * the end): the answer read aloud and its explanation shown for a few seconds
 * (not read). */
// Founder 2026-10-25: four seconds for three questions; five for five (two felt rushed).
export const roundCountdownMs = (n: number) => (n >= 5 ? 5000 : 4000);
/** Answer card on screen before the voice says the answer. */
export const ANSWER_LEAD_MS = 300;
/** Reading time for an explanation shown on screen, per character, and its bounds. */
const WHY_MS_PER_CHAR = 50;
export const whyHoldMs = (chars: number, maxMs = 5500) => Math.min(maxMs, Math.max(2800, chars * WHY_MS_PER_CHAR));

/** `startMs`: when the first question comes up (after a `solo` hook). */
export const roundTimeline = (questionMs: number[], answers: {answerMs: number; whyChars: number}[], startMs = 0) => {
	const countdownMs = roundCountdownMs(questionMs.length);
	let start = startMs;
	const steps = [];
	const reveals = [];
	for (const [k, qMs] of questionMs.entries()) {
		const voiceStart = start + LEAD_MS;
		const cdStart = voiceStart + qMs;
		steps.push({start, voiceStart, cdStart, end: cdStart + countdownMs});
		start = cdStart + countdownMs;
		const answerStart = start + ANSWER_LEAD_MS;
		const whyStart = answerStart + answers[k].answerMs;
		reveals.push({start, voiceStart: answerStart, whyStart, end: whyStart + whyHoldMs(answers[k].whyChars)});
		start = reveals[k].end;
	}
	return {steps, countdownMs, reveals, endStart: start, totalMs: start + END_MS};
};
