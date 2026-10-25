// Round reel (9:16): three open questions in a row, easiest first. Each one is
// read by the app voice with a countdown and its answer right after; the
// first two show their first explanation sentence, the last one gets the
// whole explanation read aloud. A 1/3 · 2/3 · 3/3 tally gives a reason to stay.
import React from 'react';
import {AbsoluteFill, Audio, Sequence, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {COPY} from './copy';
import {ExplainPhase} from './Explain';
import {Monkey} from './Monkey';
import {Countdown, EndCard, HOOK_HOLD_MS, HookLine, Logo, QuestionCard, Reveal, SAFE, SMALL_Q, f, ms} from './ReelParts';
import {FONT, INK, tintFor} from './theme';
import {roundTimeline} from './timing';
import type {RoundProps} from './types';

const Tally: React.FC<{n: number; of: number; color: string}> = ({n, of, color}) => (
	<div style={{position: 'absolute', top: SAFE.top + 8, right: SAFE.right, display: 'flex', gap: 10, alignItems: 'center'}}>
		{Array.from({length: of}, (_, i) => (
			<div key={i} style={{width: i === n ? 46 : 18, height: 18, borderRadius: 9, background: color, opacity: i <= n ? 1 : 0.35}} />
		))}
		<div style={{fontSize: 40, fontWeight: 800, color, marginLeft: 6}}>
			{n + 1}/{of}
		</div>
	</div>
);

export const Round: React.FC<RoundProps> = ({items, hookIndex, explain}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const now = ms(frame, fps);
	const {steps, endStart} = roundTimeline(
		items.map((it) => ({questionMs: it.questionMs, why: it.q.why})),
		explain.ms,
	);
	const i = Math.max(0, steps.findIndex((s) => now < s.end));
	const step = steps[i];
	const item = items[i];
	const last = i === items.length - 1;
	const tint = tintFor(item.q.category);
	const enter = (atMs: number, damping = 18) => spring({frame: frame - f(atMs, fps), fps, config: {damping, mass: 0.7}});
	// The first question opens under the fixed hook line, then grows (as in the one-question reel).
	const grow = i === 0 ? spring({frame: frame - f(HOOK_HOLD_MS, fps), fps, config: {damping: 20, mass: 0.8}}) : 1;
	const hook = COPY[item.q.language].roundHook(items.length);

	if (now >= endStart) {
		return (
			<AbsoluteFill style={{backgroundColor: tintFor(items[items.length - 1].q.category).bg, fontFamily: FONT, color: INK}}>
				<EndCard q={items[items.length - 1].q} appear={enter(endStart)} startFrame={f(endStart, fps)} />
			</AbsoluteFill>
		);
	}
	return (
		<AbsoluteFill style={{backgroundColor: tint.bg, fontFamily: FONT, color: INK}}>
			{items.map((it, k) =>
				it.audio ? (
					<Sequence key={k} from={f(steps[k].voiceStart, fps)} durationInFrames={f(steps[k].cdStart - steps[k].voiceStart, fps)}>
						<Audio src={staticFile(it.audio)} />
					</Sequence>
				) : null,
			)}
			<Logo color={tint.onBg} />
			<Tally n={i} of={items.length} color={tint.onBg} />
			<div style={{position: 'absolute', top: SAFE.top + 140, left: SAFE.left, right: SAFE.right - 50, bottom: SAFE.bottom, display: 'flex', flexDirection: 'column', gap: 44}}>
				{i === 0 ? <HookLine text={hook} color={tint.onBg} grow={grow} /> : null}
				{last && now >= step.revealStart ? (
					<ExplainPhase
						q={item.q}
						abc={false}
						style="parts"
						track={explain}
						revealFrame={f(step.revealStart, fps)}
						whyFrame={f(step.whyStart, fps)}
						appear={enter(step.revealStart, 16)}
						markBg={tint.bg}
						markInk={tint.onBg}
					/>
				) : (
					<>
						<QuestionCard
							q={item.q}
							words={item.words}
							tMs={now - step.voiceStart}
							optionsAtMs={step.cdStart - step.voiceStart}
							revealed={now >= step.revealStart}
							appear={i === 0 ? 1 : enter(step.start)}
							readable
							scale={i === 0 ? SMALL_Q + (1 - SMALL_Q) * grow : 1}
							markBg={tint.bg}
							markInk={tint.onBg}
						/>
						{now >= step.cdStart && now < step.revealStart ? (
							<Countdown startFrame={f(step.cdStart, fps)} onBg={tint.onBg} deep={tint.deep} comment={null} seconds={step.countdownMs / 1000} />
						) : null}
						{now >= step.revealStart ? <Reveal q={item.q} appear={enter(step.revealStart, 16)} variant="five" startFrame={f(step.revealStart, fps)} /> : null}
					</>
				)}
			</div>
			{now < step.cdStart ? (
				<div style={{position: 'absolute', right: SAFE.right + 10, bottom: SAFE.bottom - 40, opacity: i === 0 ? enter(200) : 1}}>
					<Monkey size={190} mood="idle" />
				</div>
			) : null}
		</AbsoluteFill>
	);
};
