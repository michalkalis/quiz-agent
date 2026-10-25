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

/** Round reel (3 questions, founder asked 2026-10-24; research 2026-10-25):
 * 4 s countdown before the last question, 5 s on it; only the last answer
 * gets the whole explanation, the others their first sentence on screen. */
export const ROUND_COUNTDOWN_MS = 4000;
export const shortRevealMs = (why: string) => Math.min(6000, Math.max(3000, 1500 + why.split(/\s+/).filter(Boolean).length * 300));

export const roundTimeline = (items: {questionMs: number; why: string}[], explainMs: number) => {
	let start = 0;
	const steps = items.map((it, i) => {
		const last = i === items.length - 1;
		const voiceStart = start + LEAD_MS;
		const cdStart = voiceStart + it.questionMs;
		const countdownMs = last ? COUNTDOWN_MS : ROUND_COUNTDOWN_MS;
		const revealStart = cdStart + countdownMs;
		const end = last ? revealStart + ANSWER_MS + explainMs + WHY_TAIL_MS : revealStart + shortRevealMs(it.why);
		const step = {start, voiceStart, cdStart, countdownMs, revealStart, whyStart: revealStart + ANSWER_MS, end};
		start = end;
		return step;
	});
	return {steps, endStart: start, totalMs: start + END_MS};
};
