// Caption layers of AppDemo. Each is rendered inside a Sequence that starts at the caption's
// first frame, so useCurrentFrame() is local. The phone never reaches under the caption band
// (AppDemo clips it below the band), so the texts need no backing.
import React from 'react';
import {interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {BUBBLE_BOTTOM, CHIP_H, CHIP_TOP, H, TEXT_W, TOP_BAND, W} from './demoLayout';
import {lineCount} from './fitWhy';
import {FONT, INK, SURF, tintFor} from './theme';

type Tint = ReturnType<typeof tintFor>;

const BAND_H = TOP_BAND.bottom - TOP_BAND.top;
const LINE = 1.08;
/** Text column, a little narrower than TEXT_W so nothing touches the safe edges. */
const INNER_W = TEXT_W - 60;

/** Largest size at which `text` fits the top band (as many lines as the band holds). */
const fitBand = (text: string, sizes: number[]): number => {
	if (typeof document === 'undefined') return sizes[0];
	for (const s of sizes) {
		if (lineCount(text, s, INNER_W * 0.97, 800) * s * LINE <= BAND_H - 28) return s;
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

/** Large bold text under/over the phone's top edge, one word at a time evenly across `frames`. */
export const KineticText: React.FC<{text: string; frames: number}> = ({text, frames}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const words = text.split(/\s+/).filter(Boolean);
	const size = fitBand(text, [88, 80, 72, 66, 60]);
	// Every word is in well before the line fades: the reveal ends ~0.6 s before the line does.
	const per = Math.max(1, frames - fps * 0.6) / words.length;
	return (
		<div style={{...bandStyle(), opacity: fadeOut(frame, frames, fps)}}>
				<div style={{fontSize: size, fontWeight: 800, lineHeight: LINE, textAlign: 'center', letterSpacing: -1, width: 'fit-content', maxWidth: INNER_W, textWrap: 'balance'}}>
					{words.map((w, i) => {
						const p = spring({frame: frame - i * per, fps, config: {damping: 20, stiffness: 120}, durationInFrames: Math.round(fps * 0.4)});
						return (
							<span key={i} style={{display: 'inline-block', marginRight: i < words.length - 1 ? '0.26em' : 0, opacity: p, transform: `translateY(${(1 - p) * 20}px)`}}>
								{w}
							</span>
						);
					})}
				</div>
		</div>
	);
};

/** The title over the first seconds: fades in as one block, no word pacing. */
export const HookText: React.FC<{text: string; frames: number}> = ({text, frames}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const size = fitBand(text, [88, 80, 72, 66, 60]);
	const p = spring({frame, fps, config: {damping: 22, stiffness: 100}});
	return (
		<div style={{...bandStyle(), opacity: Math.min(p, fadeOut(frame, frames, fps)), transform: `translateY(${(1 - p) * 16}px)`}}>
				<div style={{fontSize: size, fontWeight: 800, lineHeight: LINE, textAlign: 'center', letterSpacing: -1, maxWidth: INNER_W, textWrap: 'balance'}}>{text}</div>
		</div>
	);
};

const TITLE_SIZES = [190, 176, 160, 144, 128, 112];
const TITLE_LINE = 1.0;

/** One size for all title words: the largest at which every one of them fits a single line. */
export const fitTitle = (texts: string[]): number => {
	if (typeof document === 'undefined' || texts.length === 0) return TITLE_SIZES[2];
	return TITLE_SIZES.find((s) => texts.every((t) => lineCount(t, s, INNER_W * 0.97, 800) === 1)) ?? TITLE_SIZES[TITLE_SIZES.length - 1];
};

/** A single big word that pops in (slight overshoot) and fades out; shares the band with the voice captions. */
export const TitleWord: React.FC<{text: string; frames: number; size: number}> = ({text, frames, size}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const p = spring({frame, fps, config: {damping: 11, stiffness: 160}});
	return (
		<div style={{...bandStyle(), opacity: Math.min(1, p * 1.5) * fadeOut(frame, frames, fps)}}>
				<TitleText text={text} size={size} scale={0.6 + 0.4 * p} />
		</div>
	);
};

export const TitleText: React.FC<{text: string; size: number; scale?: number}> = ({text, size, scale = 1}) => (
	<div style={{fontSize: size, fontWeight: 800, lineHeight: TITLE_LINE, letterSpacing: -3, whiteSpace: 'nowrap', textAlign: 'center', transform: `scale(${scale})`}}>{text}</div>
);

/** What the player says: a speech bubble at the bottom of the safe area that pops in, tail pointing up at it. */
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

/** Feature chip in the row above the caption band: drops in, rests, fades up and out. */
export const LabelChip: React.FC<{text: string; frames: number; tint: Tint}> = ({text, frames, tint}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const inP = spring({frame, fps, config: {damping: 20, stiffness: 110}});
	const outP = interpolate(frame, [frames - fps * 0.3, frames], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
	const size = 44;
	return (
		<div style={{position: 'absolute', left: 0, width: W, top: CHIP_TOP, height: CHIP_H, display: 'flex', justifyContent: 'center', fontFamily: FONT}}>
			<div
				style={{
					display: 'flex',
					alignItems: 'center',
					gap: 18,
					padding: '0 36px',
					height: CHIP_H,
					borderRadius: CHIP_H / 2,
					background: SURF,
					color: INK,
					fontSize: size,
					fontWeight: 700,
					whiteSpace: 'nowrap',
					boxShadow: '0 10px 28px rgba(17,18,22,.16)',
					opacity: inP * (1 - outP),
					transform: `translateY(${(inP - 1) * 30 - outP * 20}px) scale(${0.9 + 0.1 * inP})`,
				}}
			>
				<span style={{width: 20, height: 20, borderRadius: 10, background: tint.bg}} />
				{text}
			</div>
		</div>
	);
};
