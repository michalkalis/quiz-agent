// "5 Seconds" and "A, B or C" reels (9:16). One timeline, two variants:
// question read by the app voice (with a hook card before it, a hook line
// above it, or alone) → 5 s countdown with the monkey thinking → answer +
// the explanation (one line, read aloud part by part, or, since 2026-10-25,
// one card: the answer read aloud and the whole explanation shown) → end card.
import React from 'react';
import {AbsoluteFill, Audio, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {COPY, hookFor} from './copy';
import {AnswerReveal} from './AnswerReveal';
import {ExplainPhase} from './Explain';
import {Countdown, EndCard, HOOK_HOLD_MS, HookLine, HookSolo, QuestionCard, Reveal, SAFE, SMALL_Q, f, ms} from './ReelParts';
import {FONT, INK, tintFor} from './theme';
import {ANSWER_LEAD_MS, LEAD_MS, reelTimeline} from './timing';
import type {ReelProps} from './types';

export const Reel: React.FC<ReelProps & {variant: 'five' | 'abc'}> = ({q, audio, words, questionMs, optionsAtMs, optionAtMs, hookIndex, variant, style, explain, answer}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const tint = tintFor(q.category);

	const intro = style.opening === 'intro';
	const solo = style.opening === 'solo';
	// Without the intro card the question is complete on frame 1 and the voice follows.
	const lead = intro ? 0 : LEAD_MS;
	const {qStart, cdStart, revealStart, whyStart, endStart} = reelTimeline(style, questionMs + lead, explain.ms, answer.ms, q.explanation.length);
	const now = ms(frame, fps);
	// Fused opening (founder pick 2026-10-24): big hook line over a small but readable
	// question; when the line leaves, the question grows to full size.
	const grow = style.opening === 'fused' ? spring({frame: frame - f(HOOK_HOLD_MS, fps), fps, config: {damping: 20, mass: 0.8}}) : 1;

	const enter = (atMs: number, damping = 18) =>
		spring({frame: frame - f(atMs, fps), fps, config: {damping, mass: 0.7}});

	const inEnd = now >= endStart;
	const hookOut = interpolate(now, [qStart - 250, qStart], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

	return (
		<AbsoluteFill style={{backgroundColor: tint.bg, fontFamily: FONT, color: INK}}>
			{audio ? (
				<Sequence from={f(qStart + lead, fps)}>
					<Audio src={staticFile(audio)} />
				</Sequence>
			) : null}
			{style.explain === 'card' && answer.audio ? (
				<Sequence from={f(revealStart + ANSWER_LEAD_MS, fps)}>
					<Audio src={staticFile(answer.audio)} />
				</Sequence>
			) : null}

			{!inEnd ? (
				<>
					{/* Hook card before the question (v1) */}
					{intro && now < qStart ? (
						<AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', padding: `0 ${SAFE.right}px 0 ${SAFE.left}px`}}>
							<div
								style={{
									fontSize: 96,
									fontWeight: 800,
									lineHeight: 1.08,
									textAlign: 'center',
									color: tint.onBg,
									opacity: enter(0) * hookOut,
									transform: `translateY(${(1 - enter(0)) * 40}px)`,
									letterSpacing: -1.5,
								}}
							>
								{hookFor(q.language, hookIndex)}
							</div>
						</AbsoluteFill>
					) : null}

					{solo ? <HookSolo line={COPY[q.language].openLine(null)} color={tint.onBg} endMs={qStart} /> : null}

					{/* Question card, countdown, reveal */}
					{now >= qStart ? (
						<div
							style={{
								position: 'absolute',
								top: SAFE.top + 40,
								left: SAFE.left,
								right: SAFE.right - 50,
								bottom: SAFE.bottom,
								display: 'flex',
								flexDirection: 'column',
								gap: 44,
							}}
						>
							{style.opening === 'fused' ? <HookLine text={hookFor(q.language, hookIndex)} color={tint.onBg} grow={grow} /> : null}
							{style.explain !== 'line' && now >= revealStart ? null : (
								<QuestionCard
									q={q}
									words={words}
									tMs={now - qStart - lead}
									optionsAtMs={optionsAtMs}
									optionAtMs={optionAtMs}
									revealed={now >= revealStart}
									appear={intro || solo ? enter(qStart) : 1}
									readable={!intro}
									scale={style.opening === 'fused' ? SMALL_Q + (1 - SMALL_Q) * grow : 1}
									markBg={tint.bg}
									markInk={tint.onBg}
								/>
							)}
							{now >= cdStart && now < revealStart ? (
								<Countdown startFrame={f(cdStart, fps)} onBg={tint.onBg} />
							) : null}
							{now >= revealStart && style.explain === 'line' ? <Reveal q={q} appear={enter(revealStart, 16)} variant={variant} startFrame={f(revealStart, fps)} /> : null}
							{now >= revealStart && style.explain === 'card' ? (
								<AnswerReveal q={q} text={q.explanation} appear={enter(revealStart, 16)} why={enter(whyStart, 20)} startFrame={f(revealStart, fps)} />
							) : null}
							{now >= revealStart && style.explain !== 'line' && style.explain !== 'card' ? (
								<ExplainPhase
									q={q}
									abc={variant === 'abc'}
									style={style.explain}
									track={explain}
									revealFrame={f(revealStart, fps)}
									whyFrame={f(whyStart, fps)}
									appear={enter(revealStart, 16)}
									markBg={tint.bg}
									markInk={tint.onBg}
								/>
							) : null}
						</div>
					) : null}

				</>
			) : (
				<EndCard q={q} appear={enter(endStart)} startFrame={f(endStart, fps)} />
			)}
		</AbsoluteFill>
	);
};
