// Brand tokens, mirrored from apps/website/src/template.html (:root, light).
import {cancelRender, continueRender, delayRender, staticFile} from 'remotion';

export const INK = '#111216';
export const INK2 = '#3F4350';
export const SURF = '#FFFFFF';
export const OK = '#0E8A66';
export const OK_BG = 'rgba(63,224,174,.22)';
export const FONT = '"Rethink Sans", -apple-system, "SF Pro Display", system-ui, sans-serif';

/** Background + whether text on it is light or dark. */
type Tint = {bg: string; deep: string; onBg: string};

const COBALT: Tint = {bg: '#2C45F5', deep: '#1A2FC4', onBg: '#FFFFFF'};
const ORANGE: Tint = {bg: '#FF6B2C', deep: '#E0521A', onBg: '#111216'};
const GREEN: Tint = {bg: '#3FE0AE', deep: '#16B386', onBg: '#111216'};
const YELLOW: Tint = {bg: '#FFD23F', deep: '#F5B800', onBg: '#111216'};
const PINK: Tint = {bg: '#D42A72', deep: '#A91F5A', onBg: '#FFFFFF'};
const PURPLE: Tint = {bg: '#7052F5', deep: '#5638D6', onBg: '#FFFFFF'};

// Each category keeps one colour so a series looks varied but recognisable
// (content plan principle 4: identical-looking output gets penalised).
const BY_CATEGORY: Record<string, Tint> = {
	'science-nature': GREEN,
	'geography-world': COBALT,
	geography: COBALT,
	entertainment: PINK,
	'movies-music': PURPLE,
	'food-everyday': YELLOW,
	history: ORANGE,
	sports: ORANGE,
	general: COBALT,
};
const ROTATION = [COBALT, ORANGE, GREEN, YELLOW, PINK, PURPLE];

export const tintFor = (category: string): Tint => {
	if (BY_CATEGORY[category]) return BY_CATEGORY[category];
	let h = 0;
	for (const c of category) h = (h * 31 + c.charCodeAt(0)) >>> 0;
	return ROTATION[h % ROTATION.length];
};

/** Load Rethink Sans before the first frame is captured (call once, at module scope). */
export const loadBrandFonts = () => {
	if (typeof document === 'undefined') return;
	const handle = delayRender('Rethink Sans');
	const faces = [
		new FontFace('Rethink Sans', `url(${staticFile('brand/rethink-sans-latin.woff2')}) format("woff2")`, {
			weight: '400 800',
			unicodeRange:
				'U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD',
		}),
		new FontFace('Rethink Sans', `url(${staticFile('brand/rethink-sans-latin-ext.woff2')}) format("woff2")`, {
			weight: '400 800',
			unicodeRange:
				'U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C4,U+2113,U+2C60-2C7F,U+A720-A7FF',
		}),
	];
	Promise.all(faces.map((f) => f.load()))
		.then((loaded) => {
			loaded.forEach((f) => (document.fonts as unknown as Set<FontFace>).add(f));
			continueRender(handle);
		})
		.catch((e) => cancelRender(e));
};
