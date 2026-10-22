// The mascot from the master SVG, with code-only motion: a slow bob, a blink
// every ~2.6 s, eyes that drift up while "thinking", a small hop when happy.
import React from 'react';
import {useCurrentFrame, useVideoConfig} from 'remotion';
import {MASCOT_BODY, MASCOT_FACE, MASCOT_VIEWBOX} from './brand/mascot-parts';
import {eyeOpenAt} from './timing';

export type Mood = 'idle' | 'thinking' | 'happy';

const PUPILS = [
	{cx: 81, cy: 103},
	{cx: 123, cy: 103},
];

export const Monkey: React.FC<{size: number; mood?: Mood; delay?: number}> = ({size, mood = 'idle', delay = 0}) => {
	const frame = useCurrentFrame() - delay;
	const {fps} = useVideoConfig();
	const t = frame / fps;

	const bob = Math.sin(t * Math.PI * (mood === 'thinking' ? 0.9 : 0.6)) * size * 0.018;
	const hop = mood === 'happy' ? -Math.abs(Math.sin(Math.min(t, 0.9) * Math.PI * 2.2)) * size * 0.06 * Math.max(0, 1 - t / 0.9) : 0;
	const tilt = mood === 'thinking' ? Math.sin(t * Math.PI * 0.45) * 4 : 0;

	// Timed in seconds so stills (fps 1) never catch a blink.
	const blink = eyeOpenAt(t);

	// Thinking: gaze drifts up and side to side.
	const gx = mood === 'thinking' ? Math.sin(t * Math.PI * 0.5) * 3 : 0;
	const gy = mood === 'thinking' ? -3.2 : mood === 'happy' ? -0.8 : 0;

	const [, , vw, vh] = MASCOT_VIEWBOX.split(' ').map(Number);
	return (
		<svg
			viewBox={MASCOT_VIEWBOX}
			width={size}
			height={(size * vh) / vw}
			style={{transform: `translateY(${bob + hop}px) rotate(${tilt}deg)`, overflow: 'visible'}}
		>
			<g dangerouslySetInnerHTML={{__html: MASCOT_BODY}} />
			{PUPILS.map((p) => (
				<g key={p.cx} transform={`translate(${p.cx + gx} ${p.cy + gy}) scale(1 ${blink})`}>
					<circle r={9.5} fill="#2B1A12" />
					<circle cx={3.3} cy={-3.8} r={3} fill="#FFFFFF" />
				</g>
			))}
			<g dangerouslySetInnerHTML={{__html: MASCOT_FACE}} />
		</svg>
	);
};
