// Round reel (9:16): 3 or 5 open questions in a row, easiest first, each read
// by the app voice with a short countdown (founder 2026-10-25: answers only at
// the end). Then every answer pops in on one card, and the last (hardest)
// question's whole explanation is read aloud. A tally (2/5) shows how far in
// the viewer is.
import React from 'react';
import {AbsoluteFill, Audio, Sequence, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {COPY} from './copy';
import {ExplainPhase} from './Explain';
import {Monkey} from './Monkey';
import {Countdown, EndCard, HOOK_HOLD_MS, HookLine, Logo, QuestionCard, SAFE, SMALL_Q, f, ms} from './ReelParts';
import {FONT, INK, INK2, OK, SURF, tintFor} from './theme';
import {ANSWER_STEP_MS, roundTimeline} from './timing';
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

/** All answers on one card, popping in one after another. */
const Answers: React.FC<{items: RoundProps['items']; startMs: number; nowMs: number}> = ({items, startMs, nowMs}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const five = items.length >= 5;
	const copy = COPY[items[0].q.language];
	return (
		<div style={{background: SURF, borderRadius: 44, padding: five ? '36px 44px' : '44px 48px', boxShadow: '0 22px 44px rgba(17,18,22,.18)', display: 'flex', flexDirection: 'column', gap: five ? 22 : 34}}>
			<div style={{fontSize: 34, fontWeight: 700, color: OK, textTransform: 'uppercase', letterSpacing: 2}}>{copy.answersTitle}</div>
			{items.map((it, k) => {
				const at = startMs + 600 + k * ANSWER_STEP_MS;
				const pop = spring({frame: frame - f(at, fps), fps, config: {damping: 15, mass: 0.6}});
				const shown = nowMs >= at;
				return (
					<div key={k} style={{display: 'flex', gap: 24, alignItems: 'flex-start'}}>
						<div
							style={{
								width: 58,
								height: 58,
								borderRadius: 29,
								flexShrink: 0,
								background: shown ? OK : '#E6E8EE',
								color: SURF,
								fontSize: 32,
								fontWeight: 800,
								display: 'flex',
								justifyContent: 'center',
								alignItems: 'center',
							}}
						>
							{k + 1}
						</div>
						<div style={{flex: 1, minWidth: 0}}>
							<div style={{fontSize: five ? 26 : 30, lineHeight: 1.25, color: INK2, fontWeight: 500, display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', overflow: 'hidden'}}>
								{it.q.question}
							</div>
							<div style={{fontSize: five ? 46 : 54, fontWeight: 800, letterSpacing: -0.8, lineHeight: 1.1, marginTop: 4, opacity: shown ? pop : 0.25, transform: `translateY(${(1 - pop) * 16}px)`}}>
								{shown ? it.q.answer : '?'}
							</div>
						</div>
					</div>
				);
			})}
		</div>
	);
};

export const Round: React.FC<RoundProps> = ({items, explain}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const now = ms(frame, fps);
	const t = roundTimeline(
		items.map((it) => it.questionMs),
		explain.ms,
	);
	const last = items[items.length - 1];
	const enter = (atMs: number, damping = 18) => spring({frame: frame - f(atMs, fps), fps, config: {damping, mass: 0.7}});
	const audio = items.map((it, k) =>
		it.audio ? (
			<Sequence key={k} from={f(t.steps[k].voiceStart, fps)} durationInFrames={Math.max(1, f(t.steps[k].cdStart - t.steps[k].voiceStart, fps))}>
				<Audio src={staticFile(it.audio)} />
			</Sequence>
		) : null,
	);

	if (now >= t.endStart) {
		return (
			<AbsoluteFill style={{backgroundColor: tintFor(last.q.category).bg, fontFamily: FONT, color: INK}}>
				<EndCard q={last.q} appear={enter(t.endStart)} startFrame={f(t.endStart, fps)} />
			</AbsoluteFill>
		);
	}

	// Answers card, then the last question's explanation: in the last question's colour.
	if (now >= t.answersStart) {
		const tint = tintFor(last.q.category);
		return (
			<AbsoluteFill style={{backgroundColor: tint.bg, fontFamily: FONT, color: INK}}>
				{audio}
				<Logo color={tint.onBg} />
				<div style={{position: 'absolute', top: SAFE.top + 140, left: SAFE.left, right: SAFE.right - 50, bottom: SAFE.bottom}}>
					{now < t.revealStart ? (
						<div style={{opacity: enter(t.answersStart), transform: `scale(${0.95 + 0.05 * enter(t.answersStart)})`}}>
							<Answers items={items} startMs={t.answersStart} nowMs={now} />
						</div>
					) : (
						<ExplainPhase
							q={last.q}
							abc={false}
							style="parts"
							track={explain}
							revealFrame={f(t.revealStart, fps)}
							whyFrame={f(t.whyStart, fps)}
							appear={enter(t.revealStart, 16)}
							markBg={tint.bg}
							markInk={tint.onBg}
						/>
					)}
				</div>
			</AbsoluteFill>
		);
	}

	const i = Math.max(0, t.steps.findIndex((s) => now < s.end));
	const step = t.steps[i];
	const item = items[i];
	const tint = tintFor(item.q.category);
	// The first question opens under the fixed hook line, then grows (as in the one-question reel).
	const grow = i === 0 ? spring({frame: frame - f(HOOK_HOLD_MS, fps), fps, config: {damping: 20, mass: 0.8}}) : 1;
	return (
		<AbsoluteFill style={{backgroundColor: tint.bg, fontFamily: FONT, color: INK}}>
			{audio}
			<Logo color={tint.onBg} />
			<Tally n={i} of={items.length} color={tint.onBg} />
			<div style={{position: 'absolute', top: SAFE.top + 140, left: SAFE.left, right: SAFE.right - 50, bottom: SAFE.bottom, display: 'flex', flexDirection: 'column', gap: 44}}>
				{i === 0 ? <HookLine text={COPY[item.q.language].roundHook(items.length)} color={tint.onBg} grow={grow} /> : null}
				<QuestionCard
					q={item.q}
					words={item.words}
					tMs={now - step.voiceStart}
					optionsAtMs={step.cdStart - step.voiceStart}
					revealed={false}
					appear={i === 0 ? 1 : enter(step.start)}
					readable
					scale={i === 0 ? SMALL_Q + (1 - SMALL_Q) * grow : 1}
					markBg={tint.bg}
					markInk={tint.onBg}
				/>
				{now >= step.cdStart ? <Countdown startFrame={f(step.cdStart, fps)} onBg={tint.onBg} deep={tint.deep} comment={null} seconds={t.countdownMs / 1000} /> : null}
			</div>
			{now < step.cdStart ? (
				<div style={{position: 'absolute', right: SAFE.right + 10, bottom: SAFE.bottom - 40, opacity: i === 0 ? enter(200) : 1}}>
					<Monkey size={190} mood="idle" />
				</div>
			) : null}
		</AbsoluteFill>
	);
};
