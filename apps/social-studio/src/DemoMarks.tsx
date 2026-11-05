// Marker-style highlights of AppDemo: a light, hand-drawn mark on the element the voice talks about,
// drawn on the screen (it moves with the camera). Much lighter than the old dim spotlight.
import React from 'react';
import {Easing, interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import type {DemoMarkStyle} from './demoTypes';

/** A mark in output frames (relative to its Sequence) and screen pixels. */
export type MarkBox = {start: number; frames: number; x: number; y: number; w: number; h: number; style: DemoMarkStyle};

const ORANGE = '#FF6B2C';
const INDIGO = '#3B3FD8';
const HIGHLIGHTER = '#FFD23F';
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

/** 0..1 draw progress over `s` seconds (eased out), and the fade at the end. */
const useDraw = (frames: number, s: number, delay = 0) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const p = interpolate(frame, [delay * fps, (delay + s) * fps], [0, 1], {...clamp, easing: Easing.out(Easing.cubic)});
	const o = interpolate(frame, [frames - fps * 0.3, frames], [1, 0], clamp);
	return {p, o};
};

/** Loose marker loop around the box: a bit more than one turn, uneven radius, the end overshooting the start. */
const loopPath = (b: MarkBox): string => {
	const cx = b.x + b.w / 2;
	const cy = b.y + b.h / 2;
	const rx = b.w / 2 + 22;
	const ry = b.h / 2 + 18;
	const pts: string[] = [];
	const n = 64;
	const turn = 1.12;
	for (let i = 0; i <= n; i++) {
		const u = i / n;
		const a = -2.5 + u * turn * 2 * Math.PI;
		const wob = 1 + 0.035 * Math.sin(3 * a + 0.7) + 0.02 * Math.sin(5 * a) + 0.05 * u;
		pts.push(`${(cx + rx * wob * Math.cos(a)).toFixed(1)},${(cy + ry * wob * Math.sin(a) - 4 * u).toFixed(1)}`);
	}
	return `M${pts.join(' L')}`;
};

/** Marker underline: slightly rising, slightly bowed, with a small flick at the end. */
const underlinePath = (b: MarkBox): string => {
	const y = b.y + b.h + 16;
	const x0 = b.x + 2;
	const x1 = b.x + b.w + 6;
	return `M${x0},${y + 3} Q${(x0 + x1) / 2},${y + 8} ${x1},${y - 2} L${x1 - 14},${y + 5}`;
};

const roundRectPath = (b: MarkBox, pad: number): string => {
	const x = b.x - pad;
	const y = b.y - pad;
	const w = b.w + 2 * pad;
	const h = b.h + 2 * pad;
	const r = Math.min(h / 2, 30);
	return `M${x + w / 2},${y} H${x + w - r} A${r},${r} 0 0 1 ${x + w},${y + r} V${y + h - r} A${r},${r} 0 0 1 ${x + w - r},${y + h} H${x + r} A${r},${r} 0 0 1 ${x},${y + h - r} V${y + r} A${r},${r} 0 0 1 ${x + r},${y} Z`;
};

const Stroke: React.FC<{d: string; p: number; o: number; color: string; width: number; opacity: number}> = ({d, p, o, color, width, opacity}) => (
	<svg style={{position: 'absolute', left: 0, top: 0, width: '100%', height: '100%', overflow: 'visible'}}>
		<path d={d} pathLength={1} fill="none" stroke={color} strokeWidth={width} strokeLinecap="round" strokeLinejoin="round" strokeDasharray="1 1" strokeDashoffset={1 - p} opacity={opacity * o} />
	</svg>
);

export const DemoMark: React.FC<{m: MarkBox}> = ({m}) => {
	const draw = useDraw(m.frames, m.style === 'highlighter' ? 0.3 : m.style === 'ring' ? 0.4 : m.style === 'underline' ? 0.35 : 0.4, m.style === 'ring' ? 0.1 : 0);
	if (m.style === 'circle') return <Stroke d={loopPath(m)} {...draw} color={ORANGE} width={5} opacity={0.85} />;
	if (m.style === 'underline') return <Stroke d={underlinePath(m)} {...draw} color={ORANGE} width={6} opacity={0.85} />;
	if (m.style === 'ring') return <Stroke d={roundRectPath(m, 10)} {...draw} color={INDIGO} width={2.5} opacity={0.55} />;
	// Highlighter: a translucent band a little larger than the element, swiped left to right, ragged ends.
	const padX = 16;
	const padY = 10;
	return (
		<div
			style={{
				position: 'absolute',
				left: m.x - padX,
				top: m.y - padY,
				width: m.w + 2 * padX,
				height: m.h + 2 * padY,
				background: HIGHLIGHTER,
				opacity: 0.35 * draw.o,
				borderRadius: '10px 18px 12px 20px / 14px 10px 18px 12px',
				transform: 'rotate(-1.2deg)',
				clipPath: `inset(0 ${(1 - draw.p) * 100}% 0 0)`,
			}}
		/>
	);
};
