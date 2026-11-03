// Fixed geometry of the AppDemo frame (1080 x 1920). Every text sits inside the platform safe
// area (SAFE, ReelParts): the feature chip and the big caption band on top, above the phone; the
// player bubble at the bottom of the safe area. The phone itself runs on into the unsafe bottom
// strip, so whatever matters on screen is brought up to FOCUS_CY by a zoom (demoTimeline.ts).
import {SAFE} from './ReelParts';

export const W = 1080;
export const H = 1920;
/** Lowest y the platform UI leaves free. */
export const SAFE_BOTTOM = H - SAFE.bottom;

/** Feature chip row, at the top of the safe area. */
export const CHIP_TOP = SAFE.top;
export const CHIP_H = 68;
/** Hook, the app's voice and the big title words, under the chip row. */
export const TOP_BAND = {top: CHIP_TOP + CHIP_H + 14, bottom: 560};
/** Where the player bubble ends: just inside the safe area. */
export const BUBBLE_BOTTOM = SAFE_BOTTOM - 16;

export const PHONE_H = 1300;
export const PHONE_TOP = TOP_BAND.bottom + 14;
/** Dark frame around the screen. */
export const BEZEL = 14;
/** Widest screen we draw (keeps a wide recording from running off the frame). */
const MAX_SCREEN_W = W - 2 * 150;

/** Centre of the phone's outer box when the camera rests. */
export const PHONE_CX = W / 2;
export const PHONE_CY = PHONE_TOP + PHONE_H / 2;
/** A zoom brings its point here: the middle of the free space between the caption band and the safe bottom. */
export const FOCUS_CY = Math.round((TOP_BAND.bottom + SAFE_BOTTOM) / 2);

/** Text column, symmetric inside SAFE.left / SAFE.right. */
export const TEXT_W = W - 2 * SAFE.right;

export type PhoneBox = {screenW: number; screenH: number; outerW: number; outerH: number; radius: number};

export const phoneBox = (rec: {w: number; h: number}): PhoneBox => {
	let screenH = PHONE_H - 2 * BEZEL;
	let screenW = (screenH * rec.w) / rec.h;
	if (screenW > MAX_SCREEN_W) {
		screenW = MAX_SCREEN_W;
		screenH = (screenW * rec.h) / rec.w;
	}
	return {screenW, screenH, outerW: screenW + 2 * BEZEL, outerH: screenH + 2 * BEZEL, radius: screenW * 0.135};
};
