// The phone of AppDemo: a drawn iPhone-style bezel around the cut recording, with the spotlight and
// the tap marks on the screen. Everything inside moves with the camera (the group is transformed by AppDemo).
import React from 'react';
import {AbsoluteFill, OffthreadVideo, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {BEZEL, PHONE_CX, PHONE_CY, type PhoneBox} from './demoLayout';
import {DemoMark, type MarkBox} from './DemoMarks';
import type {Timeline} from './demoTimeline';

export const RIPPLE_S = 0.6;
export type Ripple = {frame: number; x: number; y: number};
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

/** A tap, like iOS "show touches": a soft grey fingertip that presses in and lifts, and a thin ring that spreads from it. */
const RippleDot: React.FC<{x: number; y: number}> = ({x, y}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const t = frame / fps;
	const press = interpolate(t, [0, 0.1, 0.22, RIPPLE_S], [0.75, 1.04, 1, 0.94], clamp);
	const dotO = interpolate(t, [0, 0.08, RIPPLE_S - 0.25, RIPPLE_S], [0, 1, 1, 0], clamp);
	const p = interpolate(t, [0.08, RIPPLE_S], [0, 1], clamp);
	const ring = 52 + (1 - (1 - p) ** 2) * 70;
	const dot = 50 * press;
	return (
		<>
			<div style={{position: 'absolute', left: x - ring / 2, top: y - ring / 2, width: ring, height: ring, borderRadius: ring / 2, border: '2px solid rgba(255,255,255,.9)', boxShadow: '0 0 0 1px rgba(17,18,22,.12), 0 2px 10px rgba(17,18,22,.18)', opacity: 0.9 * (1 - p)}} />
			<div style={{position: 'absolute', left: x - dot / 2, top: y - dot / 2, width: dot, height: dot, borderRadius: dot / 2, background: 'rgba(60,63,72,.32)', boxShadow: 'inset 0 0 0 2px rgba(255,255,255,.75), 0 3px 12px rgba(17,18,22,.22)', opacity: dotO}} />
		</>
	);
};

/** Highlights in output frames and screen pixels. */
export type Spot = {start: number; end: number; x: number; y: number; w: number; h: number; glide?: boolean};
const DIM = 0.24;
const PAD = 8;

/**
 * The element in focus: the rest of the screen dims a little, with a soft edge (no outline). A highlight
 * with `glide` moves over from the one before; back-to-back ones keep the dim on; a lone one fades in and out.
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
	const o = Math.min(before ? 1 : interpolate(frame, [s.start, s.start + 10], [0, 1], clamp), next ? 1 : interpolate(frame, [s.end - 8, s.end], [1, 0], clamp));
	return (
		<div
			style={{
				position: 'absolute',
				left: r.x - PAD,
				top: r.y - PAD,
				width: r.w + 2 * PAD,
				height: r.h + 2 * PAD,
				borderRadius: Math.min(22, r.h / 2 + PAD),
				boxShadow: `0 0 26px 3000px rgba(12,14,22,${DIM * o})`,
			}}
		/>
	);
};

export const DemoPhone: React.FC<{src: string; rec: {w: number; h: number}; box: PhoneBox; timeline: Timeline; ripples: Ripple[]; spots: Spot[]; marks?: MarkBox[]; fps: number}> = ({src, rec, box, timeline, ripples, spots, marks = [], fps}) => {
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
					{marks.map((m, i) => (
						<Sequence key={i} from={m.start} durationInFrames={Math.max(1, m.frames)} layout="none">
							<DemoMark m={{...m, x: m.x * k, y: m.y * k, w: m.w * k, h: m.h * k, r: m.r === undefined ? undefined : m.r * k, prev: m.prev && {x: m.prev.x * k, y: m.prev.y * k, w: m.prev.w * k, h: m.prev.h * k}}} />
						</Sequence>
					))}
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
