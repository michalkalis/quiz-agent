// AppDemo (#210): an iOS simulator recording of Trubbo as a 9:16 promo reel. The recording sits in a
// drawn phone on a soft tint; cuts, tap ripples, a calm zooming camera, the app's voice clips and
// three kinds of captions are laid on top. The script (demoTypes.ts) is in RECORDING time throughout.
import React from 'react';
import {AbsoluteFill, Audio, Sequence, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {DemoPhone, RIPPLE_S, type Ripple} from './DemoPhone';
import {HookText, KineticText, LabelChip, PlayerBubble} from './DemoCaptions';
import {phoneBox, PHONE_CX, PHONE_CY} from './demoLayout';
import {buildTimeline, cameraAt, cameraKeys, cameraTransform, mapRange, mapTime, restCam} from './demoTimeline';
import type {AppDemoProps} from './demoTypes';
import {END_CARD_S, EndCard} from './EndCard';
import {FONT, INK, tintFor} from './theme';

export const appDemoFrames = (props: AppDemoProps, fps: number) => buildTimeline(props.segments, fps).frames + (props.endCard ? Math.round(END_CARD_S * fps) : 0);

export const AppDemo: React.FC<AppDemoProps> = (props) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const tint = tintFor(props.category ?? 'general');
	const rec = props.recordingSize;
	const box = phoneBox(rec);
	const tl = buildTimeline(props.segments, fps);

	const keys = cameraKeys(props, tl, fps);
	const rest = restCam(rec);
	const cam = cameraAt(keys, Math.min(frame, tl.frames), fps, rest);
	const {tx, ty, scale} = cameraTransform(cam, rec, box);
	const lift = Math.min(1, Math.max(0, (scale - 1.04) / 0.12));

	const ripples: Ripple[] = [];
	for (const t of props.taps ?? []) {
		const at = mapTime(tl, t.t);
		if (at !== null) ripples.push({frame: Math.round(at * fps), x: t.x, y: t.y});
	}

	const captions = (props.captions ?? []).flatMap((c) => {
		const r = mapRange(tl, c.from, c.to);
		return r ? [{...c, startFrame: Math.round(r[0] * fps), frames: Math.max(1, Math.round((r[1] - r[0]) * fps))}] : [];
	});
	// The hook gives way to the first spoken caption instead of drawing under it.
	const firstVoice = Math.min(Infinity, ...captions.filter((c) => c.kind === 'voice').map((c) => c.startFrame));
	const hookFrames = props.hook ? Math.min(Math.round(props.hook.seconds * fps), firstVoice, tl.frames) : 0;

	return (
		<AbsoluteFill style={{fontFamily: FONT, color: INK, background: '#F3F4F8'}}>
			<AbsoluteFill style={{background: `radial-gradient(1300px 1000px at 50% 34%, ${tint.bg}38, transparent 72%), radial-gradient(1100px 800px at 50% 100%, ${tint.deep}20, transparent 70%)`}} />
			<Sequence durationInFrames={Math.max(1, tl.frames)} layout="none">
				<AbsoluteFill style={{transformOrigin: `${PHONE_CX}px ${PHONE_CY}px`, transform: `translate(${tx}px, ${ty}px) scale(${scale})`}}>
					<DemoPhone src={props.recording} rec={rec} box={box} timeline={tl} ripples={ripples} fps={fps} />
				</AbsoluteFill>
				{hookFrames > 0 && props.hook ? (
					<Sequence durationInFrames={hookFrames} layout="none">
						<HookText text={props.hook.text} frames={hookFrames} lift={lift} />
					</Sequence>
				) : null}
				{captions.map((c, i) => (
					<Sequence key={i} from={c.startFrame} durationInFrames={c.frames} layout="none">
						{c.kind === 'voice' ? <KineticText text={c.text} frames={c.frames} lift={lift} /> : null}
						{c.kind === 'player' ? <PlayerBubble text={c.text} frames={c.frames} tint={tint} /> : null}
						{c.kind === 'label' ? <LabelChip text={c.text} frames={c.frames} tint={tint} /> : null}
					</Sequence>
				))}
				{(props.audio ?? []).map((a, i) => {
					const at = mapTime(tl, a.t);
					if (at === null) return null;
					const from = Math.round(at * fps);
					return (
						<Sequence key={i} from={from} durationInFrames={Math.max(1, tl.frames - from)} layout="none">
							<Audio src={staticFile(a.src)} volume={a.volume ?? 1} />
						</Sequence>
					);
				})}
			</Sequence>
			{props.endCard ? (
				<Sequence from={tl.frames} durationInFrames={Math.round(END_CARD_S * fps)}>
					<EndCard language={props.language} frames={Math.round(END_CARD_S * fps)} />
				</Sequence>
			) : null}
		</AbsoluteFill>
	);
};
