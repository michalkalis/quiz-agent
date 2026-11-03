// End card shared by the Pinned launch reel and the AppDemo reel: monkey, "Trubbo",
// tagline, App Store badge (English only; sk/cs show the line) and `copy.soon`.
import React from 'react';
import {AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {COPY} from './copy';
import {Monkey} from './Monkey';
import {SAFE} from './ReelParts';
import {INK, SURF, tintFor} from './theme';
import type {Language} from './types';

export const END_CARD_S = 3.2;
export const END_TINT = tintFor('science-nature');

export const Fade: React.FC<{frames: number; children: React.ReactNode; bg: string; out?: boolean}> = ({frames, children, bg, out = true}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const fadeIn = interpolate(frame, [0, fps * 0.25], [0, 1], {extrapolateRight: 'clamp'});
	const fadeOut = out ? interpolate(frame, [frames - fps * 0.2, frames], [1, 0], {extrapolateLeft: 'clamp'}) : 1;
	return <AbsoluteFill style={{background: bg, opacity: Math.min(fadeIn, fadeOut)}}>{children}</AbsoluteFill>;
};

/** Fades in over whatever is underneath; place it in a Sequence of `frames` frames. */
export const EndCard: React.FC<{language: Language; frames: number}> = ({language, frames}) => {
	const copy = COPY[language];
	return (
		<Fade frames={frames} bg={END_TINT.bg} out={false}>
			<AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', flexDirection: 'column', gap: 56, padding: `${SAFE.top}px ${SAFE.right}px ${SAFE.bottom - 120}px ${SAFE.left}px`}}>
				<div style={{width: 340, height: 340, borderRadius: 170, background: SURF, display: 'flex', justifyContent: 'center', alignItems: 'center'}}>
					<Monkey size={260} mood="happy" />
				</div>
				<div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 20}}>
					<div style={{fontSize: 120, fontWeight: 800, color: INK, letterSpacing: -2}}>Trubbo</div>
					<div style={{fontSize: 60, fontWeight: 700, lineHeight: 1.1, textAlign: 'center', color: INK}}>{copy.tagline}</div>
					{/* Apple's badge exists in English here; sk/cs show the line only. */}
					{language === 'en' ? (
						<Img src={staticFile('store/app-store-badge.svg')} style={{height: 120, marginTop: 40}} />
					) : null}
					<div style={{fontSize: 44, fontWeight: 600, color: INK, opacity: 0.85, marginTop: language === 'en' ? 12 : 32}}>{copy.soon}</div>
				</div>
			</AbsoluteFill>
		</Fade>
	);
};
