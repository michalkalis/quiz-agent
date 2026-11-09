// Pinned launch reel (founder 2026-11-02): the first thing a new profile visitor
// sees once the app is live. Opening line with the monkey, the App Store
// screenshots in order (what the listing shows), then the end card with
// "Free on the App Store". Silent: no voice clip matches the screenshots.
import React from 'react';
import {AbsoluteFill, Img, Sequence, interpolate, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {COPY} from './copy';
import {END_CARD_S, EndCard, Fade} from './EndCard';
import {Monkey} from './Monkey';
import {SAFE} from './ReelParts';
import {FONT, INK, SURF, tintFor} from './theme';
import type {Language} from './types';

export type PinnedProps = {language: Language; shots: string[]};

export const PINNED_OPEN_S = 2.4;
export const PINNED_SHOT_S = 2.2;
export const PINNED_END_S = END_CARD_S;
export const pinnedSeconds = (shots: number) => PINNED_OPEN_S + shots * PINNED_SHOT_S + PINNED_END_S;

const TINT = tintFor('science-nature');
// The listing screenshots' own background, so the frame edges disappear.
const SHOT_BG = '#E9EAEE';

const Shot: React.FC<{src: string}> = ({src}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	// Slow push in, so a still screenshot does not read as a frozen video.
	const scale = interpolate(frame, [0, fps * PINNED_SHOT_S], [1, 1.04]);
	return (
		// The listing screenshots cut the phone off at the bottom by design: sit them on the
		// video's bottom edge so the phone runs out of frame instead of ending mid-screen
		// (founder 2026-11-02). Top 200 keeps the headline clear of the Reels header.
		<AbsoluteFill style={{background: SHOT_BG, alignItems: 'center', justifyContent: 'flex-end'}}>
			<Img src={staticFile(src)} style={{height: 1720, display: 'block', transform: `scale(${scale})`, transformOrigin: 'bottom center'}} />
		</AbsoluteFill>
	);
};

export const Pinned: React.FC<PinnedProps> = ({language, shots}) => {
	const {fps} = useVideoConfig();
	const copy = COPY[language];
	const open = Math.round(PINNED_OPEN_S * fps);
	const shot = Math.round(PINNED_SHOT_S * fps);
	const end = Math.round(PINNED_END_S * fps);
	const endAt = open + shots.length * shot;
	return (
		<AbsoluteFill style={{fontFamily: FONT, background: TINT.bg}}>
			<Sequence durationInFrames={open}>
				<Fade frames={open} bg={TINT.bg}>
					<AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', flexDirection: 'column', gap: 64, padding: `${SAFE.top}px ${SAFE.right}px ${SAFE.bottom - 120}px ${SAFE.left}px`}}>
						<div style={{width: 340, height: 340, borderRadius: 170, background: SURF, display: 'flex', justifyContent: 'center', alignItems: 'center'}}>
							<Monkey size={260} mood="happy" />
						</div>
						<div style={{fontSize: 96, fontWeight: 800, lineHeight: 1.08, textAlign: 'center', color: INK, letterSpacing: -1.5}}>{copy.live}</div>
					</AbsoluteFill>
				</Fade>
			</Sequence>
			<Sequence from={open} durationInFrames={shots.length * shot}>
				<AbsoluteFill style={{background: SHOT_BG}} />
			</Sequence>
			{shots.map((src, i) => (
				<Sequence key={src} from={open + i * shot} durationInFrames={shot + (i < shots.length - 1 ? Math.round(fps * 0.25) : 0)}>
					<Fade frames={shot} bg={SHOT_BG} out={false}>
						<Shot src={src} />
					</Fade>
				</Sequence>
			))}
			<Sequence from={endAt} durationInFrames={end}>
				<EndCard language={language} frames={end} />
			</Sequence>
		</AbsoluteFill>
	);
};
