// Reel timeline (ms). The question phase length comes from the voice clip,
// or from reading time when there is no clip; the explanation phase likewise.
import type {ReelStyle} from './types';

export const HOOK_MS = 1500;
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

export const reelTimeline = (style: ReelStyle, questionMs: number, explainMs: number) => {
	const qStart = style.opening === 'intro' ? HOOK_MS : 0;
	const cdStart = qStart + questionMs;
	const revealStart = cdStart + COUNTDOWN_MS;
	const whyStart = revealStart + ANSWER_MS;
	const endStart = style.explain === 'line' ? revealStart + REVEAL_MS : whyStart + explainMs + WHY_TAIL_MS;
	return {qStart, cdStart, revealStart, whyStart, endStart, totalMs: endStart + END_MS};
};

/** Monkey eyelid openness (1 = open) at `t` seconds: a ~0.2 s blink every 2.6 s. */
export const eyeOpenAt = (t: number) => {
	const phase = (((t + 0.6) % 2.6) + 2.6) % 2.6;
	if (phase >= 0.2) return 1;
	return phase < 0.07 ? 1 - (phase / 0.07) * 0.88 : phase < 0.13 ? 0.12 : 0.12 + ((phase - 0.13) / 0.07) * 0.88;
};

/** Round reel (founder 2026-10-25): 3 or 5 questions in a row, each with a
 * countdown, and every answer only at the end: one by one, the answer read
 * aloud and its explanation shown for a few seconds (not read). */
// Founder 2026-10-25: four seconds for three questions; five for five (two felt rushed).
export const roundCountdownMs = (n: number) => (n >= 5 ? 5000 : 4000);
/** Answer card on screen before the voice says the answer. */
export const ANSWER_LEAD_MS = 300;
/** Reading time for an explanation shown on screen, per character, and its bounds. */
const WHY_MS_PER_CHAR = 50;
export const whyHoldMs = (chars: number) => Math.min(5500, Math.max(2800, chars * WHY_MS_PER_CHAR));

export const roundTimeline = (questionMs: number[], answers: {answerMs: number; whyChars: number}[]) => {
	const countdownMs = roundCountdownMs(questionMs.length);
	let start = 0;
	const steps = questionMs.map((qMs) => {
		const voiceStart = start + LEAD_MS;
		const cdStart = voiceStart + qMs;
		const step = {start, voiceStart, cdStart, end: cdStart + countdownMs};
		start = step.end;
		return step;
	});
	const answersStart = start;
	const reveals = answers.map(({answerMs, whyChars}) => {
		const voiceStart = start + ANSWER_LEAD_MS;
		const whyStart = voiceStart + answerMs;
		const step = {start, voiceStart, whyStart, end: whyStart + whyHoldMs(whyChars)};
		start = step.end;
		return step;
	});
	return {steps, countdownMs, answersStart, reveals, endStart: start, totalMs: start + END_MS};
};
