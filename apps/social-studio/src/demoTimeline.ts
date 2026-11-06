// Recording time -> output time (the cuts), and the camera that follows the zooms.
import {spring} from 'remotion';
import {FOCUS_CY, PHONE_CX, PHONE_CY, PHONE_TOP, SAFE_BOTTOM, W, type PhoneBox} from './demoLayout';
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

/** Output seconds at which the stretch of recording that `t` falls in is cut (adjoining segments at the same speed count as one). */
export const runEnd = (tl: Timeline, t: number): number | null => {
	let i = tl.segments.findIndex((s) => t >= s.from && t < s.to);
	if (i < 0) return null;
	while (i + 1 < tl.segments.length && Math.abs(tl.segments[i + 1].from - tl.segments[i].to) < 1e-6 && tl.segments[i + 1].speed === tl.segments[i].speed) i++;
	return tl.segments[i].outEnd;
};

type Cam = {s: number; x: number; y: number};
type Key = {frame: number; to: Cam; cut?: boolean};

const TAP_NUDGE = 1.05;
const TAP_HOLD_S = 0.9;
const MARGIN = 30;

/** True when recording time `t` is where a segment starts, i.e. the video cuts to it. */
export const startsSegment = (tl: Timeline, t: number) => tl.segments.some((s) => Math.abs(s.from - t) < 1e-3);

/** Camera keys in output frames: explicit zooms in/out, plus a small nudge on taps outside any zoom. A zoom that starts with a cut starts there at once, like the cut. */
export const cameraKeys = (props: AppDemoProps, tl: Timeline, fps: number): Key[] => {
	const rest = restCam(props.recordingSize, props.restScale);
	const keys: Key[] = [];
	const zoomSpans: [number, number][] = [];
	for (const z of props.zooms ?? []) {
		const r = mapRange(tl, z.from, z.to);
		if (!r) continue;
		keys.push({frame: Math.round(r[0] * fps), to: {s: z.scale, x: z.x, y: z.y}, cut: startsSegment(tl, z.from)}, {frame: Math.round(r[1] * fps), to: rest});
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
		const p = (f: number) => (k.cut ? 1 : ease(f, fps));
		cur = lerp(from, k.to, p(frame - k.frame));
		const next = keys[i + 1];
		if (next) from = lerp(from, k.to, p(next.frame - k.frame));
	}
	return cur;
};

/** Horizontal shift that keeps the zoomed phone sensible: it never floats loose, and once wider than the frame it still covers it. */
const clampShift = (t: number, centre: number, size: number, scale: number, dim: number): number => {
	const lo = centre - (scale * size) / 2;
	const hi = centre + (scale * size) / 2;
	const m = Math.min(MARGIN, Math.max(0, (dim - (hi - lo)) / 2));
	const a = hi - lo >= dim ? dim - hi : m - lo;
	const b = hi - lo >= dim ? -lo : dim - m - hi;
	return Math.min(Math.max(t, Math.min(a, b)), Math.max(a, b));
};

/** How far (0..1) a camera of this scale pulls its point up to FOCUS_CY: fully from 1.2x, a little on a tap nudge. */
const FOCUS_FULL_AT = 1.2;

/**
 * CSS transform (origin = phone centre) for camera.s.
 * It brings its point to the middle of the frame horizontally (as far as the phone still covers the frame) and up to FOCUS_CY vertically,
 * the free space under the caption band, so the zoomed content never sits under a text (AppDemo clips the phone below the band). The
 * phone never opens a gap above its resting top, and its bottom always reaches the safe bottom.
 */
export const cameraTransform = (cam: Cam, rec: {w: number; h: number}, box: PhoneBox) => {
	const px = PHONE_CX - box.screenW / 2 + (cam.x / rec.w) * box.screenW;
	const py = PHONE_CY - box.screenH / 2 + (cam.y / rec.h) * box.screenH;
	const pull = Math.min(1, Math.max(0, (cam.s - 1) / (FOCUS_FULL_AT - 1)));
	const tx = clampShift((PHONE_CX - px) * pull + (1 - cam.s) * (px - PHONE_CX), PHONE_CX, box.outerW, cam.s, W);
	const target = py + (FOCUS_CY - py) * pull;
	const half = (cam.s * box.outerH) / 2;
	const tyMax = PHONE_TOP - (PHONE_CY - half);
	const tyMin = SAFE_BOTTOM - (PHONE_CY + half);
	const ty = Math.min(tyMax, Math.max(tyMin, target - PHONE_CY - cam.s * (py - PHONE_CY)));
	return {tx, ty, scale: cam.s};
};

export const restCam = (rec: {w: number; h: number}, s = 1): Cam => ({s, x: rec.w / 2, y: rec.h / 2});
