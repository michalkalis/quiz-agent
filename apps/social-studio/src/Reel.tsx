// "5 Seconds" and "A, B or C" reels (9:16). One timeline, two variants:
// hook → question read by the app voice with word captions → 5 s countdown
// with the monkey thinking → answer + one line why → end card.
import React from 'react';
import {AbsoluteFill, Audio, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {COPY, LETTERS, hookFor} from './copy';
import {fitWhy} from './fitWhy';
import {Monkey} from './Monkey';
import {FONT, INK, INK2, OK, OK_BG, SURF, tintFor} from './theme';
import {COUNTDOWN_MS, HOOK_MS, REVEAL_MS} from './timing';
import type {ReelProps} from './types';


const ms = (frame: number, fps: number) => (frame / fps) * 1000;
const f = (millis: number, fps: number) => Math.round((millis / 1000) * fps);

// Platform UI (captions, buttons) covers the bottom and right edge of a reel;
// everything important stays inside this box.
const SAFE = {top: 170, bottom: 400, left: 80, right: 130};

export const Reel: React.FC<ReelProps & {variant: 'five' | 'abc'}> = ({q, audio, words, questionMs, optionsAtMs, hookIndex, variant}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const tint = tintFor(q.category);
	const copy = COPY[q.language];

	const qStart = HOOK_MS;
	const cdStart = qStart + questionMs;
	const revealStart = cdStart + COUNTDOWN_MS;
	const endStart = revealStart + REVEAL_MS;
	const now = ms(frame, fps);

	const enter = (atMs: number, damping = 18) =>
		spring({frame: frame - f(atMs, fps), fps, config: {damping, mass: 0.7}});

	const inEnd = now >= endStart;
	const hookOut = interpolate(now, [qStart - 250, qStart], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

	return (
		<AbsoluteFill style={{backgroundColor: tint.bg, fontFamily: FONT, color: INK}}>
			{audio ? (
				<Sequence from={f(qStart, fps)}>
					<Audio src={staticFile(audio)} />
				</Sequence>
			) : null}

			{!inEnd ? (
				<>
					<Logo color={tint.onBg} />

					{/* Hook */}
					{now < qStart ? (
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

					{/* Question card, countdown, reveal */}
					{now >= qStart ? (
						<div
							style={{
								position: 'absolute',
								top: SAFE.top + 140,
								left: SAFE.left,
								right: SAFE.right - 50,
								bottom: SAFE.bottom,
								display: 'flex',
								flexDirection: 'column',
								gap: 44,
							}}
						>
							<QuestionCard
								q={q}
								words={words}
								tMs={now - qStart}
								optionsAtMs={optionsAtMs}
								revealed={now >= revealStart}
								appear={enter(qStart)}
							/>
							{now >= cdStart && now < revealStart ? (
								<Countdown
									startFrame={f(cdStart, fps)}
									onBg={tint.onBg}
									deep={tint.deep}
									comment={variant === 'abc' ? copy.comment(LETTERS.slice(0, q.options.length)) : null}
								/>
							) : null}
							{now >= revealStart ? <Reveal q={q} appear={enter(revealStart, 16)} variant={variant} startFrame={f(revealStart, fps)} /> : null}
						</div>
					) : null}

					{/* The monkey listens while the question is read, then sits in the countdown. */}
					{now < cdStart ? (
						<div style={{position: 'absolute', right: SAFE.right + 10, bottom: SAFE.bottom - 40, opacity: enter(200)}}>
							<Monkey size={190} mood="idle" />
						</div>
					) : null}
				</>
			) : (
				<EndCard q={q} appear={enter(endStart)} startFrame={f(endStart, fps)} />
			)}
		</AbsoluteFill>
	);
};

const Logo: React.FC<{color: string}> = ({color}) => (
	<div style={{position: 'absolute', top: SAFE.top, left: SAFE.left, display: 'flex', alignItems: 'center', gap: 18}}>
		<div style={{width: 76, height: 76, borderRadius: 38, background: SURF, display: 'flex', justifyContent: 'center', alignItems: 'center'}}>
			<Monkey size={58} />
		</div>
		<div style={{fontSize: 46, fontWeight: 800, color, letterSpacing: -0.5}}>Trubbo</div>
	</div>
);

const QuestionCard: React.FC<{
	q: ReelProps['q'];
	words: ReelProps['words'];
	tMs: number;
	optionsAtMs: number;
	revealed: boolean;
	appear: number;
}> = ({q, words, tMs, optionsAtMs, revealed, appear}) => {
	const long = q.question.length > 110;
	const mcq = q.options.length > 0;
	return (
		<div
			style={{
				background: SURF,
				borderRadius: 44,
				padding: mcq ? '48px 48px 44px' : '56px 56px 60px',
				boxShadow: '0 22px 44px rgba(17,18,22,.18)',
				opacity: appear,
				transform: `translateY(${(1 - appear) * 60}px)`,
			}}
		>
			<div style={{fontSize: long || mcq ? 56 : 66, fontWeight: 700, lineHeight: 1.18, letterSpacing: -0.6}}>
				{words.map((w, i) => (
					<span key={i} style={{opacity: tMs >= w.startMs ? 1 : 0.18}}>
						{w.text}
						{i < words.length - 1 ? ' ' : ''}
					</span>
				))}
			</div>
			{q.options.length > 0 ? (
				<div style={{display: 'flex', flexDirection: 'column', gap: 14, marginTop: 32}}>
					{q.options.map((opt, i) => {
						const shown = interpolate(tMs, [optionsAtMs + i * 350, optionsAtMs + i * 350 + 250], [0, 1], {
							extrapolateLeft: 'clamp',
							extrapolateRight: 'clamp',
						});
						const right = i === q.correctIndex;
						const dim = revealed && !right;
						return (
							<div
								key={i}
								style={{
									display: 'flex',
									alignItems: 'center',
									gap: 24,
									padding: '16px 24px',
									borderRadius: 28,
									background: revealed && right ? OK_BG : '#F1F2F5',
									opacity: shown * (dim ? 0.38 : 1),
									transform: `translateX(${(1 - shown) * 30}px)`,
								}}
							>
								<div
									style={{
										width: 58,
										height: 58,
										borderRadius: 29,
										flexShrink: 0,
										background: revealed && right ? OK : INK,
										color: SURF,
										fontSize: 36,
										fontWeight: 800,
										display: 'flex',
										justifyContent: 'center',
										alignItems: 'center',
									}}
								>
									{LETTERS[i]}
								</div>
								<div style={{fontSize: 44, fontWeight: 600}}>{opt}</div>
							</div>
						);
					})}
				</div>
			) : null}
		</div>
	);
};

const Countdown: React.FC<{startFrame: number; onBg: string; deep: string; comment: string | null}> = ({startFrame, onBg, deep, comment}) => {
	const frame = useCurrentFrame() - startFrame;
	const {fps} = useVideoConfig();
	const total = (COUNTDOWN_MS / 1000) * fps;
	const left = Math.max(1, Math.ceil(5 - frame / fps));
	const progress = Math.min(1, frame / total);
	const compact = comment !== null;
	const R = compact ? 64 : 112;
	const C = 2 * Math.PI * R;
	const pop = spring({frame: frame % fps, fps, config: {damping: 14, mass: 0.5}});
	return (
		<div style={{flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center'}}>
			<div style={{display: 'flex', alignItems: 'center', gap: compact ? 28 : 56}}>
				<Monkey size={compact ? 150 : 310} mood="thinking" delay={startFrame} />
				<svg width={2 * R + 30} height={2 * R + 30} viewBox={`${-R - 15} ${-R - 15} ${2 * R + 30} ${2 * R + 30}`}>
					<circle r={R} fill="none" stroke={onBg} strokeOpacity={0.22} strokeWidth={compact ? 12 : 16} />
					<circle
						r={R}
						fill="none"
						stroke={onBg}
						strokeWidth={compact ? 12 : 16}
						strokeLinecap="round"
						strokeDasharray={C}
						strokeDashoffset={C * progress}
						transform="rotate(-90)"
					/>
					<text
						textAnchor="middle"
						dominantBaseline="central"
						fontFamily={FONT}
						fontWeight={800}
						fontSize={(compact ? 68 : 116) * (0.85 + 0.15 * pop)}
						fill={onBg}
					>
						{left}
					</text>
				</svg>
				{comment ? (
					<div style={{fontSize: 40, fontWeight: 700, color: SURF, background: deep, borderRadius: 999, padding: '18px 32px'}}>{comment}</div>
				) : null}
			</div>
		</div>
	);
};

const Reveal: React.FC<{q: ReelProps['q']; appear: number; variant: 'five' | 'abc'; startFrame: number}> = ({q, appear, variant, startFrame}) => {
	const copy = COPY[q.language];
	const abc = variant === 'abc' && q.correctIndex !== null;
	// Text column = reel width (920) − card padding − gap − monkey.
	const why = fitWhy(q.why, abc ? {width: 920 - 96 - 28 - 110, maxLines: 4, size: 38, minSize: 30} : {width: 920 - 112 - 28 - 150, maxLines: 4, size: 40, minSize: 30});
	return (
		<div
			style={{
				background: SURF,
				borderRadius: 44,
				padding: abc ? '36px 48px 40px' : '48px 56px 52px',
				boxShadow: '0 22px 44px rgba(17,18,22,.18)',
				opacity: appear,
				transform: `scale(${0.94 + 0.06 * appear})`,
				display: 'flex',
				gap: 28,
				alignItems: 'flex-start',
			}}
		>
			<div style={{flex: 1}}>
				<div style={{fontSize: 34, fontWeight: 700, color: OK, textTransform: 'uppercase', letterSpacing: 2}}>
					{copy.answer}
					{abc ? ` ${LETTERS[q.correctIndex!]}` : ''}
				</div>
				{abc ? null : <div style={{fontSize: 80, fontWeight: 800, lineHeight: 1.05, marginTop: 10, letterSpacing: -1}}>{q.answer}</div>}
				{why.text ? <div style={{fontSize: why.size, lineHeight: 1.3, color: INK2, marginTop: abc ? 12 : 24, fontWeight: 500}}>{why.text}</div> : null}
			</div>
			<div style={{marginTop: -6}}>
				<Monkey size={abc ? 110 : 150} mood="happy" delay={startFrame} />
			</div>
		</div>
	);
};

const EndCard: React.FC<{q: ReelProps['q']; appear: number; startFrame: number}> = ({q, appear, startFrame}) => {
	const tint = tintFor(q.category);
	const copy = COPY[q.language];
	return (
		<AbsoluteFill
			style={{
				justifyContent: 'center',
				alignItems: 'center',
				flexDirection: 'column',
				gap: 56,
				padding: `${SAFE.top}px ${SAFE.right}px ${SAFE.bottom - 120}px ${SAFE.left}px`,
				opacity: appear,
			}}
		>
			<div style={{width: 340, height: 340, borderRadius: 170, background: SURF, display: 'flex', justifyContent: 'center', alignItems: 'center'}}>
				<Monkey size={260} mood="happy" delay={startFrame} />
			</div>
			<div style={{fontSize: 84, fontWeight: 800, lineHeight: 1.08, textAlign: 'center', color: tint.onBg, letterSpacing: -1.2}}>{copy.send}</div>
			<div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14}}>
				<div style={{fontSize: 64, fontWeight: 800, color: tint.onBg}}>Trubbo</div>
				<div style={{fontSize: 38, fontWeight: 600, color: tint.onBg, opacity: 0.85}}>{copy.soon}</div>
			</div>
		</AbsoluteFill>
	);
};
