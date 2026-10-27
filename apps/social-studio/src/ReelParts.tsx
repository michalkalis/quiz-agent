// Pieces shared by the one-question reel (Reel.tsx) and the three-question
// round (Round.tsx): safe area, logo, hook line, question card, countdown,
// v1 reveal, end card.
import React from 'react';
import {AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {COPY} from './copy';
import {fitWhy} from './fitWhy';
import {Monkey} from './Monkey';
import {FONT, INK, INK2, OK, OK_BG, SURF, tintFor} from './theme';
import {COUNTDOWN_MS} from './timing';
import type {ReelProps} from './types';

export const ms = (frame: number, fps: number) => (frame / fps) * 1000;
export const f = (millis: number, fps: number) => Math.round((millis / 1000) * fps);

// Platform UI covers a reel's edges: top bar (Reels/For You tabs, camera,
// search), the account name and caption at the bottom, the like/comment/share
// column on the lower right (Instagram, TikTok, YouTube Shorts, Facebook).
// Everything important stays inside this box; nothing small sits right of
// x 880 below y 800. No logo on screen: the account name is always shown.
export const SAFE = {top: 260, bottom: 480, left: 80, right: 130};

/** The MCQ option being read: neutral grey (founder 2026-10-25: a colour reads as "the right one"). */
const READING_BG = '#D9DCE3';

/** How long the fused hook line holds before the question grows. */
export const HOOK_HOLD_MS = 1400;
/** Question text size under the hook line, relative to full size. */
export const SMALL_Q = 0.66;

/** Hook line on screen together with the question from frame 1; it folds away as `grow` goes 0 → 1. */
export const HookLine: React.FC<{text: string; color: string; grow: number}> = ({text, color, grow}) =>
	grow >= 1 ? null : (
		<div style={{height: 230 * (1 - grow), marginBottom: -44 * grow, overflow: 'hidden', opacity: Math.max(0, 1 - 2.5 * grow), display: 'flex', alignItems: 'flex-end'}}>
			<div style={{fontSize: 92, fontWeight: 800, lineHeight: 1.05, color, letterSpacing: -2, transform: `translateY(${-40 * grow}px)`}}>{text}</div>
		</div>
	);

/** The hook alone before the question (founder 2026-10-26: on its own it is
 * clear what the reel is about), big and centred in the safe area, gone at
 * `endMs`. The monkey and a line that names the quiz say what it is (founder 2026-10-27).
 * Fully drawn from frame 0: the first frame and the cover show it, not an empty fade. */
export const HookSolo: React.FC<{line: string; color: string; endMs: number}> = ({line, color, endMs}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const now = ms(frame, fps);
	if (now >= endMs) return null;
	const out = interpolate(now, [endMs - 250, endMs], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
	return (
		<div
			style={{
				position: 'absolute',
				left: SAFE.left,
				right: SAFE.right - 50,
				top: (SAFE.top + 1920 - SAFE.bottom) / 2,
				display: 'flex',
				flexDirection: 'column',
				alignItems: 'center',
				gap: 40,
				color,
				opacity: out,
				transform: 'translateY(-50%)',
			}}
		>
			<div style={{width: 280, height: 280, borderRadius: 140, background: SURF, display: 'flex', justifyContent: 'center', alignItems: 'center'}}>
				<Monkey size={220} mood="happy" />
			</div>
			{/* Each sentence starts its own line, so balancing never splits the question across them. */}
			<div style={{fontSize: 124, fontWeight: 800, lineHeight: 1.04, letterSpacing: -2.5, textAlign: 'center'}}>
				{line.split(/(?<=[.?!])\s+/).map((part) => (
					<div key={part} style={{textWrap: 'balance'}}>
						{part}
					</div>
				))}
			</div>
		</div>
	);
};

export const QuestionCard: React.FC<{
	q: ReelProps['q'];
	words: ReelProps['words'];
	tMs: number;
	optionsAtMs: number;
	/** When the voice starts each option, then when it stops; an option is marked while being read. */
	optionAtMs?: number[];
	revealed: boolean;
	appear: number;
	/** true: every word readable from frame 1, the word being said marked (v1 dims unsaid words). */
	readable: boolean;
	/** Size of the whole card (the fused opening starts it small). The card is laid out
	 * at full size and scaled as one piece, so lines never re-wrap while it grows. */
	scale?: number;
	markBg: string;
	markInk: string;
	/** A round question's number, shown above it. */
	number?: number;
}> = ({q, words, tMs, optionsAtMs, optionAtMs = [], revealed, appear, readable, scale = 1, markBg, markInk, number}) => {
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
				transform: `translateY(${(1 - appear) * 60}px) scale(${scale})`,
				transformOrigin: 'top left',
			}}
		>
			{number !== undefined ? (
				<div style={{fontSize: 30, fontWeight: 700, color: INK2, textTransform: 'uppercase', letterSpacing: 2, marginBottom: 14}}>{`${COPY[q.language].question} ${number}`}</div>
			) : null}
			<div style={{fontSize: long || mcq ? 56 : 66, fontWeight: 700, lineHeight: 1.18, letterSpacing: -0.6}}>
				{words.map((w, i) => {
					const saying = readable && tMs >= w.startMs && (i === words.length - 1 ? tMs < optionsAtMs : tMs < words[i + 1].startMs);
					return (
						<React.Fragment key={i}>
							<span
								style={
									readable
										? {background: saying ? markBg : 'transparent', color: saying ? markInk : INK, borderRadius: 12, padding: '0 6px', margin: '0 -6px'}
										: {opacity: tMs >= w.startMs ? 1 : 0.18}
								}
							>
								{w.text}
							</span>
							{i < words.length - 1 ? ' ' : ''}
						</React.Fragment>
					);
				})}
			</div>
			{q.options.length > 0 ? (
				<div style={{display: 'flex', flexDirection: 'column', gap: 14, marginTop: 32}}>
					{q.options.map((opt, i) => {
						// Each option comes up when the voice starts reading it (founder 2026-10-25), not all at once.
						const at = optionAtMs[i] ?? optionsAtMs + i * 350;
						const reached = interpolate(tMs, [at - 120, at + 130], [0, 1], {
							extrapolateLeft: 'clamp',
							extrapolateRight: 'clamp',
						});
						const reading = readable && optionAtMs.length > i + 1 && tMs >= at && tMs < optionAtMs[i + 1] && !revealed;
						// Readable reels show the options faintly from frame 1 (no empty card); v1 slides them in.
						const shown = readable ? 0.35 + 0.65 * reached : reached;
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
									background: revealed && right ? OK_BG : reading ? READING_BG : '#F1F2F5',
									opacity: shown * (dim ? 0.38 : 1),
									transform: `translateX(${(1 - reached) * 30}px)`,
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
									{q.labels[i]}
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

/** `note`: a line under the countdown (a round says the answers come at the end). */
export const Countdown: React.FC<{startFrame: number; onBg: string; note?: string; seconds?: number}> = ({startFrame, onBg, note, seconds = COUNTDOWN_MS / 1000}) => {
	const frame = useCurrentFrame() - startFrame;
	const {fps} = useVideoConfig();
	const total = seconds * fps;
	const left = Math.max(1, Math.ceil(seconds - frame / fps));
	const progress = Math.min(1, frame / total);
	const R = 112;
	const C = 2 * Math.PI * R;
	const pop = spring({frame: frame % fps, fps, config: {damping: 14, mass: 0.5}});
	return (
		<div style={{flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 36}}>
			<div style={{display: 'flex', alignItems: 'center', gap: 56}}>
				<Monkey size={310} mood="thinking" delay={startFrame} />
				<svg width={2 * R + 30} height={2 * R + 30} viewBox={`${-R - 15} ${-R - 15} ${2 * R + 30} ${2 * R + 30}`}>
					<circle r={R} fill="none" stroke={onBg} strokeOpacity={0.22} strokeWidth={16} />
					<circle
						r={R}
						fill="none"
						stroke={onBg}
						strokeWidth={16}
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
						fontSize={116 * (0.85 + 0.15 * pop)}
						fill={onBg}
					>
						{left}
					</text>
				</svg>
			</div>
			{note ? <div style={{fontSize: 46, fontWeight: 700, color: onBg, opacity: 0.9}}>{note}</div> : null}
		</div>
	);
};

export const Reveal: React.FC<{q: ReelProps['q']; appear: number; variant: 'five' | 'abc'; startFrame: number}> = ({q, appear, variant, startFrame}) => {
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
					{abc ? ` ${q.labels[q.correctIndex!]}` : ''}
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

export const EndCard: React.FC<{q: ReelProps['q']; appear: number; startFrame: number}> = ({q, appear, startFrame}) => {
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
			<div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 20}}>
				<div style={{fontSize: 120, fontWeight: 800, color: tint.onBg, letterSpacing: -2}}>Trubbo</div>
				<div style={{fontSize: 60, fontWeight: 700, lineHeight: 1.1, textAlign: 'center', color: tint.onBg}}>{copy.tagline}</div>
				<div style={{fontSize: 38, fontWeight: 600, color: tint.onBg, opacity: 0.85, marginTop: 24}}>{copy.soon}</div>
			</div>
		</AbsoluteFill>
	);
};
