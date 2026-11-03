// Recording time -> output time (the cuts), and the camera that follows the zooms.
import {spring} from 'remotion';
import {H, PHONE_CX, PHONE_CY, W, type PhoneBox} from './demoLayout';
import type {AppDemoProps, DemoSegment} from './demoTypes';

export type TimelineSegment = {from: number; to: number; speed: number; outStart: number; outEnd: number; startFrame: number; endFrame: number};
export type Timeline = {segments: TimelineSegment[]; seconds: number; frames: number};

export const buildTimeline = (segments: DemoSegment[], fps: number): Timeline => {
	let out = 0;
	const built = segments.map((s) => {
		const speed = s.speed && s.speed > 0 ? s.speed : 1;
		const outStart = out;
		out += Math.max(0, s.to - s.from) / speed;
		return {from: s.from, to: s.to, speed, outStart, outEnd: out, startFrame: Math.round(outStart * fps), endFrame: Math.round(out * fps)};
	});
	return {segments: built, seconds: out, frames: Math.round(out * fps)};
};

/** One recording instant -> output seconds; null when it falls in a cut-out part. */
export const mapTime = (tl: Timeline, t: number): number | null => {
	for (const s of tl.segments) if (t >= s.from && t < s.to) return s.outStart + (t - s.from) / s.speed;
	return null;
};

/** A recording span -> the output span of the parts that survive the cuts (null = fully cut). */
export const mapRange = (tl: Timeline, from: number, to: number): [number, number] | null => {
	let lo = Infinity;
	let hi = -Infinity;
	for (const s of tl.segments) {
		const a = Math.max(from, s.from);
		const b = Math.min(to, s.to);
		if (b <= a) continue;
		lo = Math.min(lo, s.outStart + (a - s.from) / s.speed);
		hi = Math.max(hi, s.outStart + (b - s.from) / s.speed);
	}
	return hi > lo ? [lo, hi] : null;
};

type Cam = {s: number; x: number; y: number};
type Key = {frame: number; to: Cam};

const TAP_NUDGE = 1.05;
const TAP_HOLD_S = 0.9;
const MARGIN = 30;

/** Camera keys in output frames: explicit zooms in/out, plus a small nudge on taps outside any zoom. */
export const cameraKeys = (props: AppDemoProps, tl: Timeline, fps: number): Key[] => {
	const rest: Cam = {s: 1, x: props.recordingSize.w / 2, y: props.recordingSize.h / 2};
	const keys: Key[] = [];
	const zoomSpans: [number, number][] = [];
	for (const z of props.zooms ?? []) {
		const r = mapRange(tl, z.from, z.to);
		if (!r) continue;
		keys.push({frame: Math.round(r[0] * fps), to: {s: z.scale, x: z.x, y: z.y}}, {frame: Math.round(r[1] * fps), to: rest});
		zoomSpans.push([r[0] - 0.4, r[1] + 0.6]);
	}
	for (const tap of props.taps ?? []) {
		const at = mapTime(tl, tap.t);
		if (at === null || zoomSpans.some(([a, b]) => at >= a && at <= b)) continue;
		keys.push({frame: Math.round(at * fps), to: {s: TAP_NUDGE, x: tap.x, y: tap.y}}, {frame: Math.round((at + TAP_HOLD_S) * fps), to: rest});
	}
	return keys.sort((a, b) => a.frame - b.frame);
};

const lerp = (a: Cam, b: Cam, p: number): Cam => ({s: a.s + (b.s - a.s) * p, x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p});

/** Calm, overdamped: no overshoot. */
const ease = (frame: number, fps: number) => spring({frame, fps, config: {damping: 24, stiffness: 70, mass: 1}});

/** Camera at a frame: each key springs from wherever the previous one had got to. */
export const cameraAt = (keys: Key[], frame: number, fps: number, rest: Cam): Cam => {
	let from = rest;
	let cur = rest;
	for (let i = 0; i < keys.length; i++) {
		const k = keys[i];
		if (frame < k.frame) break;
		cur = lerp(from, k.to, ease(frame - k.frame, fps));
		const next = keys[i + 1];
		if (next) from = lerp(from, k.to, ease(next.frame - k.frame, fps));
	}
	return cur;
};

/** Shift that keeps the zoomed phone sensible: it never floats loose, and once larger than the frame it still covers it. */
const clampShift = (t: number, centre: number, size: number, scale: number, dim: number): number => {
	const lo = centre - (scale * size) / 2;
	const hi = centre + (scale * size) / 2;
	const m = Math.min(MARGIN, Math.max(0, (dim - (hi - lo)) / 2));
	const a = hi - lo >= dim ? dim - hi : m - lo;
	const b = hi - lo >= dim ? -lo : dim - m - hi;
	return Math.min(Math.max(t, Math.min(a, b)), Math.max(a, b));
};

/** CSS transform (origin = phone centre) that puts camera.x/y at its spot and scales by camera.s. */
export const cameraTransform = (cam: Cam, rec: {w: number; h: number}, box: PhoneBox) => {
	const px = PHONE_CX - box.screenW / 2 + (cam.x / rec.w) * box.screenW;
	const py = PHONE_CY - box.screenH / 2 + (cam.y / rec.h) * box.screenH;
	const tx = clampShift((1 - cam.s) * (px - PHONE_CX), PHONE_CX, box.outerW, cam.s, W);
	const ty = clampShift((1 - cam.s) * (py - PHONE_CY), PHONE_CY, box.outerH, cam.s, H);
	return {tx, ty, scale: cam.s};
};

export const restCam = (rec: {w: number; h: number}): Cam => ({s: 1, x: rec.w / 2, y: rec.h / 2});
