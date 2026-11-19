// The answer card (founder 2026-10-25): the answer big, then the whole
// explanation under it, as the app voice reads both (founder 2026-11-16).
// No repeat of the question or its number: the card comes right after it
// (founder 2026-10-30). Rounds show the whole explanation too, never only its
// first sentence: the screen says what the voice says (founder 2026-11-18).
import React from 'react';
import {COPY} from './copy';
import {fitWhy} from './fitWhy';
import {Monkey} from './Monkey';
import {INK2, OK, SURF} from './theme';
import type {ReelQuestion} from './types';

const LABEL = {fontSize: 32, fontWeight: 700, textTransform: 'uppercase', letterSpacing: 2} as const;

export const AnswerReveal: React.FC<{
	q: ReelQuestion;
	appear: number;
	/** 0 → 1 as the explanation comes in, after the answer is said. */
	why: number;
	startFrame: number;
}> = ({q, appear, why, startFrame}) => {
	const copy = COPY[q.language];
	// Text column = reel width (920) − card padding (104).
	const fit = fitWhy(q.explanation, {width: 920 - 104, maxLines: 9, size: 42, minSize: 32});
	const label = q.correctIndex !== null ? ` ${q.labels[q.correctIndex]}` : '';
	return (
		<div style={{background: SURF, borderRadius: 44, padding: '44px 52px 48px', boxShadow: '0 22px 44px rgba(17,18,22,.18)', opacity: appear, transform: `scale(${0.94 + 0.06 * appear})`}}>
			<div style={{display: 'flex', gap: 24, alignItems: 'center'}}>
				<div style={{flex: 1, minWidth: 0}}>
					<div style={{...LABEL, color: OK}}>
						{copy.answer}
						{label}
					</div>
					<div style={{fontSize: 76, fontWeight: 800, lineHeight: 1.05, marginTop: 8, letterSpacing: -1}}>{q.answer}</div>
				</div>
				<Monkey size={130} mood="happy" delay={startFrame} />
			</div>
			{fit.text ? (
				<div style={{fontSize: fit.size, lineHeight: 1.3, color: INK2, fontWeight: 500, marginTop: 28, opacity: why, transform: `translateY(${(1 - why) * 16}px)`}}>{fit.text}</div>
			) : null}
		</div>
	);
};
