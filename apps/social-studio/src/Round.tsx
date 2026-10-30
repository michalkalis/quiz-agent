// Round reel (9:16): 3 or 5 open questions in a row, easiest first, each read
// by the app voice with a countdown, then its answer right away (founder
// 2026-10-29): read aloud, its explanation shown for a few seconds. A tally
// (2/5) shows how far in the viewer is.
import React from 'react';
import {AbsoluteFill, Audio, Sequence, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {COPY} from './copy';
import {AnswerReveal} from './AnswerReveal';
import {Countdown, EndCard, HOOK_HOLD_MS, HookLine, HookSolo, QuestionCard, SAFE, SMALL_Q, f, ms} from './ReelParts';
import {FONT, INK, INK2, OK, SURF, tintFor} from './theme';
import {HOOK_SOLO_MS, roundTimeline} from './timing';
import type {RoundItem, RoundProps} from './types';

const Tally: React.FC<{n: number; of: number; color: string}> = ({n, of, color}) => (
	<div style={{position: 'absolute', top: SAFE.top, left: SAFE.left, display: 'flex', gap: 10, alignItems: 'center'}}>
		{Array.from({length: of}, (_, i) => (
			<div key={i} style={{width: i === n ? 46 : 18, height: 18, borderRadius: 9, background: color, opacity: i <= n ? 1 : 0.35}} />
		))}
		<div style={{fontSize: 40, fontWeight: 800, color, marginLeft: 6}}>
			{n + 1}/{of}
		</div>
	</div>
);

export const Round: React.FC<RoundProps> = ({items, opening}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const now = ms(frame, fps);
	const solo = opening === 'solo';
	const t = roundTimeline(
		items.map((it) => it.questionMs),
		items.map((it) => ({answerMs: it.answerMs, whyChars: it.q.why.length})),
		solo ? HOOK_SOLO_MS : 0,
	);
	const last = items[items.length - 1];
	const enter = (atMs: number, damping = 18) => spring({frame: frame - f(atMs, fps), fps, config: {damping, mass: 0.7}});
	const clip = (src: string | null, from: number, to: number, key: string) =>
		src ? (
			<Sequence key={key} from={f(from, fps)} durationInFrames={Math.max(1, f(to - from, fps))}>
				<Audio src={staticFile(src)} />
			</Sequence>
		) : null;
	const audio = [
		...items.map((it, k) => clip(it.audio, t.steps[k].voiceStart, t.steps[k].cdStart, `q${k}`)),
		...items.map((it, k) => clip(it.answerAudio, t.reveals[k].voiceStart, t.reveals[k].end, `a${k}`)),
	];

	if (now >= t.endStart) {
		return (
			<AbsoluteFill style={{backgroundColor: tintFor(last.q.category).bg, fontFamily: FONT, color: INK}}>
				<EndCard q={last.q} appear={enter(t.endStart)} startFrame={f(t.endStart, fps)} />
			</AbsoluteFill>
		);
	}

	// Each question, then its answer, in the question's colour.
	const k = Math.max(0, t.reveals.findIndex((r) => now < r.end));
	if (now >= t.steps[k].end) {
		const r = t.reveals[k];
		const it = items[k];
		const tint = tintFor(it.q.category);
		return (
			<AbsoluteFill style={{backgroundColor: tint.bg, fontFamily: FONT, color: INK}}>
				{audio}
				<Tally n={k} of={items.length} color={tint.onBg} />
				<div style={{position: 'absolute', top: SAFE.top + 90, left: SAFE.left, right: SAFE.right - 50, bottom: SAFE.bottom}}>
					<AnswerReveal key={k} q={it.q} round text={it.q.why} appear={enter(r.start, 16)} why={enter(r.whyStart, 20)} startFrame={f(r.start, fps)} />
				</div>
			</AbsoluteFill>
		);
	}
	const i = k;
	const step = t.steps[i];
	const item = items[i];
	const tint = tintFor(item.q.category);
	const hook = COPY[item.q.language].roundHook(items.length);
	// The first question opens under the fixed hook line, then grows (as in the one-question reel).
	const fused = i === 0 && !solo;
	const grow = fused ? spring({frame: frame - f(HOOK_HOLD_MS, fps), fps, config: {damping: 20, mass: 0.8}}) : 1;
	return (
		<AbsoluteFill style={{backgroundColor: tint.bg, fontFamily: FONT, color: INK}}>
			{audio}
			{now >= step.start ? <Tally n={i} of={items.length} color={tint.onBg} /> : null}
			{solo ? <HookSolo line={COPY[item.q.language].openLine(items.length)} color={tint.onBg} endMs={step.start} /> : null}
			{now >= step.start ? (
			<div style={{position: 'absolute', top: SAFE.top + 90, left: SAFE.left, right: SAFE.right - 50, bottom: SAFE.bottom, display: 'flex', flexDirection: 'column', gap: 44}}>
				{fused ? <HookLine text={hook} color={tint.onBg} grow={grow} /> : null}
				<QuestionCard
					q={item.q}
					words={item.words}
					tMs={now - step.voiceStart}
					optionsAtMs={step.cdStart - step.voiceStart}
					revealed={false}
					appear={fused ? 1 : enter(step.start)}
					number={i + 1}
					readable
					scale={fused ? SMALL_Q + (1 - SMALL_Q) * grow : 1}
					markBg={tint.bg}
					markInk={tint.onBg}
				/>
				{now >= step.cdStart ? <Countdown startFrame={f(step.cdStart, fps)} onBg={tint.onBg} seconds={t.countdownMs / 1000} /> : null}
			</div>
			) : null}
		</AbsoluteFill>
	);
};
