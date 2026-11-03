// Caption layers of AppDemo. Each is rendered inside a Sequence that starts at the caption's
// first frame, so useCurrentFrame() is local. `lift` (0..1) is how far the camera has zoomed in:
// the zoomed phone can reach under the text, so the text then gets a soft backing.
import React from 'react';
import {interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {BUBBLE_BOTTOM, H, LABEL_CY, TEXT_W, TOP_BAND, W} from './demoLayout';
import {lineCount} from './fitWhy';
import {FONT, INK, SURF, tintFor} from './theme';

type Tint = ReturnType<typeof tintFor>;

const BAND_H = TOP_BAND.bottom - TOP_BAND.top;
const LINE = 1.08;

/** Largest size at which `text` fits the top band (as many lines as the band holds). */
const fitBand = (text: string, sizes: number[]): number => {
	if (typeof document === 'undefined') return sizes[0];
	for (const s of sizes) {
		if (lineCount(text, s, TEXT_W * 0.95, 800) * s * LINE <= BAND_H) return s;
	}
	return sizes[sizes.length - 1];
};

const fadeOut = (frame: number, frames: number, fps: number) => interpolate(frame, [frames - fps * 0.25, frames], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

const bandStyle = (): React.CSSProperties => ({
	position: 'absolute',
	top: TOP_BAND.top,
	height: BAND_H,
	left: 0,
	width: W,
	display: 'flex',
	justifyContent: 'center',
	alignItems: 'center',
	fontFamily: FONT,
	color: INK,
});

const Backing: React.FC<{lift: number; children: React.ReactNode}> = ({lift, children}) => (
	<div
		style={{
			maxWidth: TEXT_W + 60,
			padding: '14px 30px',
			borderRadius: 44,
			background: `rgba(255,255,255,${0.88 * lift})`,
			boxShadow: `0 10px 30px rgba(17,18,22,${0.16 * lift})`,
		}}
	>
		{children}
	</div>
);

/** Large bold text under/over the phone's top edge, one word at a time evenly across `frames`. */
export const KineticText: React.FC<{text: string; frames: number; lift: number}> = ({text, frames, lift}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const words = text.split(/\s+/).filter(Boolean);
	const size = fitBand(text, [88, 80, 72, 66, 60]);
	const per = frames / words.length;
	return (
		<div style={{...bandStyle(), opacity: fadeOut(frame, frames, fps)}}>
			<Backing lift={lift}>
				<div style={{fontSize: size, fontWeight: 800, lineHeight: LINE, textAlign: 'center', letterSpacing: -1, width: 'fit-content', maxWidth: TEXT_W}}>
					{words.map((w, i) => {
						const p = spring({frame: frame - i * per, fps, config: {damping: 20, stiffness: 120}, durationInFrames: Math.round(fps * 0.4)});
						return (
							<span key={i} style={{display: 'inline-block', marginRight: i < words.length - 1 ? '0.26em' : 0, opacity: p, transform: `translateY(${(1 - p) * 20}px)`}}>
								{w}
							</span>
						);
					})}
				</div>
			</Backing>
		</div>
	);
};

/** The title over the first seconds: fades in as one block, no word pacing. */
export const HookText: React.FC<{text: string; frames: number; lift: number}> = ({text, frames, lift}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const size = fitBand(text, [88, 80, 72, 66, 60]);
	const p = spring({frame, fps, config: {damping: 22, stiffness: 100}});
	return (
		<div style={{...bandStyle(), opacity: Math.min(p, fadeOut(frame, frames, fps)), transform: `translateY(${(1 - p) * 16}px)`}}>
			<Backing lift={lift}>
				<div style={{fontSize: size, fontWeight: 800, lineHeight: LINE, textAlign: 'center', letterSpacing: -1, maxWidth: TEXT_W}}>{text}</div>
			</Backing>
		</div>
	);
};

/** What the player says: a speech bubble below the phone that pops in, tail pointing up at it. */
export const PlayerBubble: React.FC<{text: string; frames: number; tint: Tint}> = ({text, frames, tint}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const pad = 44;
	let size = 50;
	if (typeof document !== 'undefined') {
		while (size > 44 && lineCount(text, size, TEXT_W - 2 * pad - 10, 700) > 1) size -= 2;
	}
	const p = spring({frame, fps, config: {damping: 13, stiffness: 150}});
	return (
		<div style={{position: 'absolute', left: 0, width: W, bottom: H - BUBBLE_BOTTOM, display: 'flex', justifyContent: 'center', fontFamily: FONT, opacity: Math.min(1, p * 1.6) * fadeOut(frame, frames, fps)}}>
			<div style={{position: 'relative', transform: `scale(${0.55 + 0.45 * p})`, transformOrigin: '50% 0%'}}>
				<div
					style={{
						position: 'absolute',
						top: -10,
						left: '50%',
						marginLeft: -14,
						width: 28,
						height: 28,
						background: tint.bg,
						borderRadius: 4,
						transform: 'rotate(45deg)',
					}}
				/>
				<div
					style={{
						position: 'relative',
						padding: `16px ${pad}px`,
						borderRadius: 60,
						background: tint.bg,
						color: tint.onBg,
						fontSize: size,
						fontWeight: 700,
						whiteSpace: 'nowrap',
						lineHeight: 1.1,
						boxShadow: '0 12px 30px rgba(17,18,22,.22)',
					}}
				>
					{text}
				</div>
			</div>
		</div>
	);
};

/** Feature chip: slides up from below the phone, rests, slides back down. */
export const LabelChip: React.FC<{text: string; frames: number; tint: Tint}> = ({text, frames, tint}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const inP = spring({frame, fps, config: {damping: 20, stiffness: 110}});
	const outP = interpolate(frame, [frames - fps * 0.3, frames], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
	const size = 44;
	return (
		<div style={{position: 'absolute', left: 0, width: W, top: LABEL_CY - 34, height: 68, display: 'flex', justifyContent: 'center', fontFamily: FONT}}>
			<div
				style={{
					display: 'flex',
					alignItems: 'center',
					gap: 18,
					padding: '0 36px',
					height: 68,
					borderRadius: 34,
					background: SURF,
					color: INK,
					fontSize: size,
					fontWeight: 700,
					whiteSpace: 'nowrap',
					boxShadow: '0 10px 28px rgba(17,18,22,.16)',
					opacity: inP * (1 - outP),
					transform: `translateY(${(1 - inP) * 70 + outP * 40}px)`,
				}}
			>
				<span style={{width: 20, height: 20, borderRadius: 10, background: tint.bg}} />
				{text}
			</div>
		</div>
	);
};
