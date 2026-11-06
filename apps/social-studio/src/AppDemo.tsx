// AppDemo (#210): an iOS simulator recording of Trubbo as a 9:16 promo reel. The recording sits in a
// drawn phone on a soft tint; cuts, tap marks, a spotlight on the element in focus, a calm zooming camera, the app's voice clips and
// captions (the app's voice, the player's answer, feature chips, big title words) are laid on top.
// The script (demoTypes.ts) is in RECORDING time throughout.
import React from 'react';
import {AbsoluteFill, Audio, interpolate, Sequence, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {DemoPhone, type Ripple, type Spot} from './DemoPhone';
import {fitSteps, fitTitle, HookText, KineticText, LabelChip, PlayerBubble, SaidText, StepText, TitleWord} from './DemoCaptions';
import type {MarkBox} from './DemoMarks';
import {phoneBox, PHONE_CX, PHONE_CY, PHONE_TOP, TOP_BAND} from './demoLayout';
import {buildTimeline, cameraAt, cameraKeys, cameraTransform, mapRange, mapTime, restCam, runEnd, startsSegment} from './demoTimeline';
import type {AppDemoProps, DemoCaption, DemoCaptionKind} from './demoTypes';
import {END_CARD_S, EndCard} from './EndCard';
import {FONT, INK, tintFor} from './theme';

export const appDemoFrames = (props: AppDemoProps, fps: number) => buildTimeline(props.segments, fps).frames + (props.endCard ? Math.round(END_CARD_S * fps) : 0);

type Rig = {keys: ReturnType<typeof cameraKeys>; rec: AppDemoProps['recordingSize']; box: ReturnType<typeof phoneBox>; frames: number; restScale?: number};

// Zoomed content stops well under the texts: fully hidden down to 30 px under the band, fully shown from the phone's resting top.
const PHONE_MASK = `linear-gradient(to bottom, transparent ${TOP_BAND.bottom + 30}px, #000 ${PHONE_TOP}px)`;

/** Camera at this component's frame. */
const useCamera = (rig: Rig) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const cam = cameraAt(rig.keys, Math.min(frame, rig.frames), fps, restCam(rig.rec, rig.restScale));
	return cameraTransform(cam, rig.rec, rig.box);
};

// Own components, so only these re-render every frame, not the video layers.
const Camera: React.FC<{rig: Rig; children: React.ReactNode}> = ({rig, children}) => {
	const {tx, ty, scale} = useCamera(rig);
	return <AbsoluteFill style={{transformOrigin: `${PHONE_CX}px ${PHONE_CY}px`, transform: `translate(${tx}px, ${ty}px) scale(${scale})`}}>{children}</AbsoluteFill>;
};

type Layer = ReturnType<typeof mapCaption>[number];
const mapCaption = (tl: ReturnType<typeof buildTimeline>, c: DemoCaption, fps: number) => {
	const r = mapRange(tl, c.from, c.to);
	if (!r) return [];
	const startFrame = Math.round(r[0] * fps);
	// Spoken words: each one's frame within the caption.
	const wordFrames = (c.words ?? []).map((w) => Math.round((mapTime(tl, w.t) ?? r[0]) * fps) - startFrame);
	return [{...c, startFrame, frames: Math.max(1, Math.round((r[1] - r[0]) * fps)), wordFrames}];
};

/** Captions that share a place on screen: one may only start once the previous one there has gone. */
const SLOT: Record<DemoCaptionKind, string> = {voice: 'band', title: 'band', step: 'band', said: 'band', label: 'band', player: 'bubble'};
const oneAtATime = (layers: Layer[]): Layer[] => {
	const sorted = [...layers].sort((a, b) => a.startFrame - b.startFrame);
	return sorted.map((c) => {
		const next = sorted.find((o) => o !== c && SLOT[o.kind] === SLOT[c.kind] && o.startFrame > c.startFrame);
		return next ? {...c, frames: Math.max(1, Math.min(c.frames, next.startFrame - c.startFrame))} : c;
	});
};

const CaptionLayer: React.FC<{c: Layer; tint: ReturnType<typeof tintFor>; titleSize: number; stepSize: number}> = ({c, tint, titleSize, stepSize}) => {
	if (c.kind === 'voice') return <KineticText text={c.text} frames={c.frames} />;
	if (c.kind === 'said') return <SaidText words={c.words?.map((w) => w.w) ?? c.text.split(/\s+/)} at={c.wordFrames} frames={c.frames} karaoke={c.karaoke} />;
	if (c.kind === 'step') return <StepText text={c.text} frames={c.frames} size={stepSize} />;
	if (c.kind === 'title') return <TitleWord text={c.text} frames={c.frames} size={titleSize} />;
	if (c.kind === 'player') return <PlayerBubble text={c.text} frames={c.frames} tint={tint} />;
	return <LabelChip text={c.text} frames={c.frames} tint={tint} />;
};

export const AppDemo: React.FC<AppDemoProps> = (props) => {
	const {fps} = useVideoConfig();
	const tint = tintFor(props.category ?? 'general');
	const rec = props.recordingSize;
	const box = phoneBox(rec);
	const tl = buildTimeline(props.segments, fps);

	const rig: Rig = {keys: cameraKeys(props, tl, fps), rec, box, frames: tl.frames, restScale: props.restScale};

	const ripples: Ripple[] = [];
	for (const t of props.taps ?? []) {
		const at = mapTime(tl, t.t);
		if (at !== null) ripples.push({frame: Math.round(at * fps), x: t.x, y: t.y});
	}

	// The spotlight glides to the next element on the same shot; on a cut it lands on the new one at once.
	const spots: Spot[] = (props.highlights ?? []).flatMap((h, i, all) => {
		const r = mapRange(tl, h.from, h.to);
		const glide = i > 0 && Math.abs(all[i - 1].to - h.from) < 1e-3 && !startsSegment(tl, h.from);
		return r ? [{start: Math.round(r[0] * fps), end: Math.round(r[1] * fps), x: h.x, y: h.y, w: h.w, h: h.h, glide}] : [];
	});

	const marks: MarkBox[] = (props.marks ?? []).flatMap((m) => {
		const r = mapRange(tl, m.from, m.to);
		return r ? [{frames: Math.round((r[1] - r[0]) * fps), start: Math.round(r[0] * fps), x: m.x, y: m.y, w: m.w, h: m.h, style: m.style}] : [];
	});

	const captions = oneAtATime((props.captions ?? []).flatMap((c) => mapCaption(tl, c, fps)));
	// All title words share one size (the largest at which the longest still fits one line).
	const stepSize = fitSteps(captions.filter((c) => c.kind === 'step').map((c) => c.text));
	const titleSize = fitTitle([...captions.filter((c) => c.kind === 'title').map((c) => c.text), ...(props.endWord ? [props.endWord] : [])]);
	// The hook gives way to the first caption in its band instead of drawing under it.
	const firstVoice = Math.min(Infinity, ...captions.filter((c) => SLOT[c.kind] === 'band').map((c) => c.startFrame));
	const hookFrames = props.hook ? Math.min(Math.round(props.hook.seconds * fps), firstVoice, tl.frames) : 0;

	return (
		<AbsoluteFill style={{fontFamily: FONT, color: INK, background: '#F3F4F8'}}>
			<AbsoluteFill style={{background: `radial-gradient(1300px 1000px at 50% 34%, ${tint.bg}38, transparent 72%), radial-gradient(1100px 800px at 50% 100%, ${tint.deep}20, transparent 70%)`}} />
			<Sequence durationInFrames={Math.max(1, tl.frames)} layout="none">
				{/* The phone is cut off (soft edge) just under the caption band: zoomed in, it slides up behind it, never under a text. */}
				<AbsoluteFill style={{maskImage: PHONE_MASK, WebkitMaskImage: PHONE_MASK}}>
					<Camera rig={rig}>
						<DemoPhone src={props.recording} rec={rec} box={box} timeline={tl} ripples={ripples} spots={spots} marks={marks} fps={fps} />
					</Camera>
				</AbsoluteFill>
				{hookFrames > 0 && props.hook ? (
					<Sequence durationInFrames={hookFrames} layout="none">
						<HookText text={props.hook.text} frames={hookFrames} />
					</Sequence>
				) : null}
				{captions.map((c, i) => (
					<Sequence key={i} from={c.startFrame} durationInFrames={c.frames} layout="none">
						<CaptionLayer c={c} tint={tint} titleSize={titleSize} stepSize={stepSize} />
					</Sequence>
				))}
				{(props.audio ?? []).map((a, i) => {
					const at = mapTime(tl, a.t);
					if (at === null) return null;
					// A clip stops where its stretch of recording is cut (short fade), never runs over the next shot.
					const from = Math.round(at * fps);
					const frames = Math.max(1, Math.round((runEnd(tl, a.t) ?? tl.seconds) * fps) - from);
					const vol = a.volume ?? 1;
					return (
						<Sequence key={i} from={from} durationInFrames={frames} layout="none">
							<Audio src={staticFile(a.src)} volume={(f) => vol * interpolate(f, [frames - 6, frames], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'})} />
						</Sequence>
					);
				})}
			</Sequence>
			{props.endCard ? (
				<Sequence from={tl.frames} durationInFrames={Math.round(END_CARD_S * fps)}>
					<EndCard language={props.language} frames={Math.round(END_CARD_S * fps)} word={props.endWord} wordSize={titleSize} />
					{props.endAudio ? (
						<Sequence from={Math.round(0.35 * fps)} layout="none">
							<Audio src={staticFile(props.endAudio)} />
						</Sequence>
					) : null}
				</Sequence>
			) : null}
		</AbsoluteFill>
	);
};
