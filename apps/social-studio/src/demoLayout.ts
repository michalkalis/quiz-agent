// Fixed geometry of the AppDemo frame (1080 x 1920). The phone is smaller than the
// "78% of the height" first asked for: the top and bottom caption bands have to fit
// outside it, and 78% (1498 px) leaves only ~210 px above and below.
export const W = 1080;
export const H = 1920;
export const PHONE_H = 1344;
export const PHONE_TOP = 372;
/** Dark frame around the screen. */
export const BEZEL = 14;
/** Widest screen we draw (keeps a wide recording from running off the frame). */
const MAX_SCREEN_W = W - 2 * 150;

/** Centre of the phone's outer box when the camera rests. */
export const PHONE_CX = W / 2;
export const PHONE_CY = PHONE_TOP + PHONE_H / 2;

/** Voice captions / hook live above the phone, label chip + player bubble below it. */
export const TOP_BAND = {top: 205, bottom: PHONE_TOP - 14};
export const LABEL_CY = PHONE_TOP + PHONE_H + 44;
export const BUBBLE_BOTTOM = H - 24;
/** Text column, symmetric inside SAFE.left / SAFE.right (ReelParts). */
export const TEXT_W = W - 2 * 130;

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
