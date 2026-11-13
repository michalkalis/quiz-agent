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

/** A light hand-drawn marker on the element the voice talks about (recording pixels): a loose loop, a highlighter swipe, an underline, or a thin traced outline. */
export type DemoMarkStyle = 'circle' | 'highlighter' | 'underline' | 'ring' | 'glow' | 'dim' | 'swipe' | 'tint' | 'band';
/** `r` = the element's own corner radius, `alpha` = strength (default 1), both optional. */
/** `band` only: `prev` = the box it slides in from (no fade-in), `hold` = no fade-out (the next band takes over). */
export type DemoMark = {from: number; to: number; x: number; y: number; w: number; h: number; style: DemoMarkStyle; r?: number; alpha?: number; prev?: {x: number; y: number; w: number; h: number}; hold?: boolean};

/** voice = what the app says · player = what the player answers (no audio) · label = feature chip · title = one big word · step = a short line saying what happens on screen · said = the narrator's words as spoken (`words`: each word's start, recording time; `karaoke`: the whole line shows faint and each word turns solid when spoken) (all but player share the band). */
export type DemoCaptionKind = 'voice' | 'player' | 'label' | 'title' | 'step' | 'said';
export type DemoWord = {w: string; t: number};
export type DemoCaption = {from: number; to: number; text: string; kind: DemoCaptionKind; words?: DemoWord[]; karaoke?: boolean};

/** A quick full-screen line before the recording (`intro`): `words[].t` and `audioAt` are seconds from the card's start. */
export type DemoIntroCard = {seconds: number; words: DemoWord[]; audio?: string; audioAt?: number};

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
	marks?: DemoMark[];
	captions?: DemoCaption[];
	/** Full-screen lines on the category colour, one after another (hard cuts), before the recording starts. */
	intro?: DemoIntroCard[];
	/** Title over the first seconds, above the phone (the app is visible from frame 1). */
	hook?: {text: string; seconds: number};
	endCard?: boolean;
	/** A big title word on the end card, styled like the `title` captions. */
	endWord?: string;
	/** A voice clip over the end card (staticFile path), from its start. */
	endAudio?: string;
	/** Camera scale when no zoom is on (default 1). Below 1 the whole phone shows, smaller, its top still just under the caption band. */
	restScale?: number;
	/** Background tint, a category name from theme.ts (default: general = cobalt). */
	category?: string;
};
