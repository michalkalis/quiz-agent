// Opening of an AppDemo (`intro`): a few quick full-screen lines on a brand colour, each read by the
// narrator. Hard cuts between the cards; the words turn solid as they are spoken (like the `said` captions).
import React from 'react';
import {AbsoluteFill, Audio, Easing, interpolate, Sequence, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {W} from './demoLayout';
import type {DemoIntroCard} from './demoTypes';
import {lineCount} from './fitWhy';
import {SAFE} from './ReelParts';
import {FONT, tintFor} from './theme';

/** Same inset on both sides (the wider one), so the text is centred on the frame. */
const SIDE = Math.max(SAFE.left, SAFE.right);
const TEXT_W = W - 2 * SIDE;
const SIZES = [150, 140, 130, 120, 110, 100, 92];
const MAX_LINES = 4;

/** One size for every card: the largest at which each fits MAX_LINES lines. */
const fitCards = (texts: string[]): number => {
	if (typeof document === 'undefined') return SIZES[3];
	return SIZES.find((s) => texts.every((t) => lineCount(t, s, TEXT_W * 0.97, 800) <= MAX_LINES)) ?? SIZES[SIZES.length - 1];
};

export const introFrames = (cards: DemoIntroCard[] | undefined, fps: number) => (cards ?? []).reduce((n, c) => n + Math.round(c.seconds * fps), 0);

const Card: React.FC<{card: DemoIntroCard; size: number; bg: string; ink: string}> = ({card, size, bg, ink}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const ease = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic)} as const;
	return (
		<AbsoluteFill style={{background: bg, justifyContent: 'center', alignItems: 'center', padding: `${SAFE.top}px ${SIDE}px ${SAFE.bottom - 120}px ${SIDE}px`}}>
			<div style={{fontFamily: FONT, color: ink, fontSize: size, fontWeight: 800, lineHeight: 1.04, letterSpacing: -2, textAlign: 'center', maxWidth: TEXT_W, textWrap: 'balance'}}>
				{card.words.map((w, i) => {
					const at = Math.round(w.t * fps);
					const p = interpolate(frame, [at, at + fps * 0.12], [0, 1], ease);
					return (
						<span key={i} style={{display: 'inline-block', marginRight: i < card.words.length - 1 ? '0.24em' : 0, opacity: 0.4 + 0.6 * p}}>
							{w.w}
						</span>
					);
				})}
			</div>
		</AbsoluteFill>
	);
};

export const IntroCards: React.FC<{cards: DemoIntroCard[]; category?: string}> = ({cards, category = 'movies-music'}) => {
	const {fps} = useVideoConfig();
	const tint = tintFor(category);
	const size = fitCards(cards.map((c) => c.words.map((w) => w.w).join(' ')));
	let from = 0;
	return (
		<>
			{cards.map((c, i) => {
				const frames = Math.round(c.seconds * fps);
				const start = from;
				from += frames;
				return (
					<Sequence key={i} from={start} durationInFrames={frames} layout="none">
						<Card card={c} size={size} bg={tint.bg} ink={tint.onBg} />
						{c.audio ? (
							<Sequence from={Math.round((c.audioAt ?? 0) * fps)} layout="none">
								<Audio src={staticFile(c.audio)} />
							</Sequence>
						) : null}
					</Sequence>
				);
			})}
		</>
	);
};
