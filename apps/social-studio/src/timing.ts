// Reel timeline (ms). The question phase length comes from the voice clip,
// or from reading time when there is no clip.
export const HOOK_MS = 1500;
export const COUNTDOWN_MS = 5000;
export const REVEAL_MS = 4000;
export const END_MS = 2500;

export const reelDurationMs = (questionMs: number) => HOOK_MS + questionMs + COUNTDOWN_MS + REVEAL_MS + END_MS;

/** Monkey eyelid openness (1 = open) at `t` seconds: a ~0.2 s blink every 2.6 s. */
export const eyeOpenAt = (t: number) => {
	const phase = (((t + 0.6) % 2.6) + 2.6) % 2.6;
	if (phase >= 0.2) return 1;
	return phase < 0.07 ? 1 - (phase / 0.07) * 0.88 : phase < 0.13 ? 0.12 : 0.12 + ((phase - 0.13) / 0.07) * 0.88;
};
