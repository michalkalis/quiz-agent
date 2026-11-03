// The phone of AppDemo: a drawn iPhone-style bezel around the cut recording, with the tap ripples
// on the screen. Everything inside moves with the camera (the group is transformed by AppDemo).
import React from 'react';
import {AbsoluteFill, OffthreadVideo, Sequence, interpolate, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {BEZEL, PHONE_CX, PHONE_CY, type PhoneBox} from './demoLayout';
import type {Timeline} from './demoTimeline';

export const RIPPLE_S = 0.45;
export type Ripple = {frame: number; x: number; y: number};

const RippleDot: React.FC<{x: number; y: number}> = ({x, y}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const p = interpolate(frame, [0, fps * RIPPLE_S], [0, 1], {extrapolateRight: 'clamp'});
	const eased = 1 - (1 - p) ** 3;
	const d = 36 + eased * 130;
	return (
		<div
			style={{
				position: 'absolute',
				left: x - d / 2,
				top: y - d / 2,
				width: d,
				height: d,
				borderRadius: d / 2,
				background: `rgba(255,255,255,${0.5 * (1 - p)})`,
				border: `${4 - 2 * p}px solid rgba(255,255,255,${0.95 * (1 - p)})`,
				boxShadow: `0 0 22px rgba(17,18,22,${0.3 * (1 - p)})`,
			}}
		/>
	);
};

export const DemoPhone: React.FC<{src: string; rec: {w: number; h: number}; box: PhoneBox; timeline: Timeline; ripples: Ripple[]; fps: number}> = ({src, rec, box, timeline, ripples, fps}) => {
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
