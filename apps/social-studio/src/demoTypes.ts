// Script of an AppDemo reel (#210): a simulator screen recording of Trubbo plus
// everything layered on it. All `t` / `from` / `to` values are RECORDING time
// (seconds into the source mp4); demoTimeline.ts maps them onto the cut video.
import type {Language} from './types';

export type DemoSegment = {from: number; to: number; speed?: number};
/** Recording pixels (e.g. 1206 x 2622), origin top left. */
export type DemoTap = {t: number; x: number; y: number};
export type DemoZoom = {from: number; to: number; x: number; y: number; scale: number};
export type DemoAudio = {t: number; src: string; volume?: number};
/** The UI element in focus from `from` to `to`: the rest of the screen dims, a ring marks it (recording pixels). */
export type DemoHighlight = {from: number; to: number; x: number; y: number; w: number; h: number};

/** voice = what the app says · player = what the player answers (no audio) · label = feature chip · title = one big word · step = a short line saying what happens on screen (voice, title and step share the band). */
export type DemoCaptionKind = 'voice' | 'player' | 'label' | 'title' | 'step';
export type DemoCaption = {from: number; to: number; text: string; kind: DemoCaptionKind};

export type AppDemoProps = {
	language: Language;
	/** staticFile path of the simulator mp4. */
	recording: string;
	recordingSize: {w: number; h: number};
	segments: DemoSegment[];
	taps?: DemoTap[];
	zooms?: DemoZoom[];
	audio?: DemoAudio[];
	highlights?: DemoHighlight[];
	captions?: DemoCaption[];
	/** Title over the first seconds, above the phone (the app is visible from frame 1). */
	hook?: {text: string; seconds: number};
	endCard?: boolean;
	/** A big title word on the end card, styled like the `title` captions. */
	endWord?: string;
	/** Background tint, a category name from theme.ts (default: general = cobalt). */
	category?: string;
};
