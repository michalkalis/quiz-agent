// The phone of AppDemo: a drawn iPhone-style bezel around the cut recording, with the spotlight and
// the tap marks on the screen. Everything inside moves with the camera (the group is transformed by AppDemo).
import React from 'react';
import {AbsoluteFill, OffthreadVideo, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {BEZEL, PHONE_CX, PHONE_CY, type PhoneBox} from './demoLayout';
import type {Timeline} from './demoTimeline';

export const RIPPLE_S = 0.7;
export type Ripple = {frame: number; x: number; y: number};
/** One accent for "look here": the spotlight ring and the tap ring. */
const MARK = '#FFD23F';
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

/** A tap: a fingertip dot that presses in and lifts, and an accent ring that spreads from it. */
const RippleDot: React.FC<{x: number; y: number}> = ({x, y}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const t = frame / fps;
	const press = interpolate(t, [0, 0.08, 0.2, RIPPLE_S], [0.6, 1.08, 1, 0.9], clamp);
	const dotO = interpolate(t, [0, 0.06, RIPPLE_S - 0.2, RIPPLE_S], [0, 1, 1, 0], clamp);
	const p = interpolate(t, [0.04, RIPPLE_S], [0, 1], clamp);
	const ring = 60 + (1 - (1 - p) ** 3) * 150;
	const dot = 62 * press;
	return (
		<>
			<div style={{position: 'absolute', left: x - ring / 2, top: y - ring / 2, width: ring, height: ring, borderRadius: ring / 2, border: `${7 - 4 * p}px solid ${MARK}`, opacity: 1 - p, boxShadow: '0 0 0 2px rgba(17,18,22,.25)'}} />
			<div style={{position: 'absolute', left: x - dot / 2, top: y - dot / 2, width: dot, height: dot, borderRadius: dot / 2, background: 'rgba(17,18,22,.38)', border: '5px solid #fff', boxShadow: '0 4px 16px rgba(17,18,22,.35)', opacity: dotO}} />
		</>
	);
};

/** Highlights in output frames and screen pixels. */
export type Spot = {start: number; end: number; x: number; y: number; w: number; h: number; glide?: boolean};
const DIM = 0.45;
const PAD = 8;

/**
 * The element in focus: the rest of the screen dims, a rounded accent ring marks it. A highlight with
 * `glide` moves over from the one before; back-to-back ones keep the dim on; a lone one fades in and out.
 */
const Spotlight: React.FC<{spots: Spot[]}> = ({spots}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const i = spots.findIndex((s) => frame >= s.start && frame < s.end);
	if (i < 0) return null;
	const s = spots[i];
	const before = i > 0 && s.start - spots[i - 1].end <= 1;
	const prev = before && s.glide ? spots[i - 1] : null;
	const next = i + 1 < spots.length && spots[i + 1].start - s.end <= 1;
	const p = prev ? spring({frame: frame - s.start, fps, config: {damping: 22, stiffness: 90}}) : 1;
	const r = prev ? {x: prev.x + (s.x - prev.x) * p, y: prev.y + (s.y - prev.y) * p, w: prev.w + (s.w - prev.w) * p, h: prev.h + (s.h - prev.h) * p} : s;
	const o = Math.min(before ? 1 : interpolate(frame, [s.start, s.start + 8], [0, 1], clamp), next ? 1 : interpolate(frame, [s.end - 6, s.end], [1, 0], clamp));
	// A lone highlight lands with a small settle of the ring.
	const grow = prev ? 0 : (1 - spring({frame: frame - s.start, fps, config: {damping: 14, stiffness: 140}})) * 18;
	const radius = Math.min(26, r.h / 2 + PAD);
	return (
		<>
			<div style={{position: 'absolute', left: r.x - PAD, top: r.y - PAD, width: r.w + 2 * PAD, height: r.h + 2 * PAD, borderRadius: radius, boxShadow: `0 0 0 3000px rgba(12,14,22,${DIM * o})`}} />
			<div
				style={{
					position: 'absolute',
					left: r.x - PAD - 6 - grow,
					top: r.y - PAD - 6 - grow,
					width: r.w + 2 * PAD + 12 + 2 * grow,
					height: r.h + 2 * PAD + 12 + 2 * grow,
					borderRadius: radius + 6 + grow,
					border: `6px solid ${MARK}`,
					boxShadow: '0 0 0 1.5px rgba(17,18,22,.35), 0 0 22px rgba(255,210,63,.55)',
					opacity: o,
				}}
			/>
		</>
	);
};

export const DemoPhone: React.FC<{src: string; rec: {w: number; h: number}; box: PhoneBox; timeline: Timeline; ripples: Ripple[]; spots: Spot[]; fps: number}> = ({src, rec, box, timeline, ripples, spots, fps}) => {
	const k = box.screenW / rec.w;
	return (
		<div
			style={{
				position: 'absolute',
				left: PHONE_CX - box.outerW / 2,
				top: PHONE_CY - box.outerH / 2,
				width: box.outerW,
				height: box.outerH,
				borderRadius: box.radius + BEZEL,
				background: '#16171B',
				boxShadow: '0 0 0 2px #2D2F36, 0 46px 90px rgba(17,18,22,.30), 0 10px 26px rgba(17,18,22,.20)',
			}}
		>
			<div style={{position: 'absolute', left: BEZEL, top: BEZEL, width: box.screenW, height: box.screenH, borderRadius: box.radius, overflow: 'hidden', background: '#000'}}>
				{timeline.segments.map((s, i) => (
					<Sequence key={i} from={s.startFrame} durationInFrames={Math.max(1, s.endFrame - s.startFrame)}>
						<OffthreadVideo src={staticFile(src)} trimBefore={Math.round(s.from * fps)} playbackRate={s.speed} muted style={{width: '100%', height: '100%', objectFit: 'cover'}} />
					</Sequence>
				))}
				<AbsoluteFill>
					<Spotlight spots={spots.map((h) => ({...h, x: h.x * k, y: h.y * k, w: h.w * k, h: h.h * k}))} />
				</AbsoluteFill>
				<AbsoluteFill>
					{ripples.map((r, i) => (
						<Sequence key={i} from={r.frame} durationInFrames={Math.round(fps * RIPPLE_S) + 1} layout="none">
							<RippleDot x={r.x * k} y={r.y * k} />
						</Sequence>
					))}
				</AbsoluteFill>
			</div>
		</div>
	);
};
