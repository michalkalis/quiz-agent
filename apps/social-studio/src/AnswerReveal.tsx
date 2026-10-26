// The answer card (founder 2026-10-25): the question small, the answer big
// (read aloud by the app voice), then the explanation shown under it, not
// read. Rounds show the explanation's first sentence; the one-question reel
// shows all of it.
import React from 'react';
import {COPY} from './copy';
import {fitWhy} from './fitWhy';
import {Monkey} from './Monkey';
import {INK2, OK, SURF} from './theme';
import type {ReelQuestion} from './types';

const LABEL = {fontSize: 32, fontWeight: 700, textTransform: 'uppercase', letterSpacing: 2} as const;

export const AnswerReveal: React.FC<{
	q: ReelQuestion;
	/** The question's number in a round; none in a one-question reel. */
	number?: number;
	/** The explanation text to show: the first sentence (round) or the whole explanation. */
	text: string;
	appear: number;
	/** 0 → 1 as the explanation comes in, after the answer is said. */
	why: number;
	startFrame: number;
}> = ({q, number, text, appear, why, startFrame}) => {
	const copy = COPY[q.language];
	const whole = number === undefined;
	// Text column = reel width (920) − card padding (104).
	const fit = fitWhy(text, whole ? {width: 920 - 104, maxLines: 9, size: 42, minSize: 32} : {width: 920 - 104, maxLines: 5, size: 44, minSize: 36});
	const label = q.correctIndex !== null ? ` ${q.labels[q.correctIndex]}` : '';
	return (
		<div style={{background: SURF, borderRadius: 44, padding: '44px 52px 48px', boxShadow: '0 22px 44px rgba(17,18,22,.18)', opacity: appear, transform: `scale(${0.94 + 0.06 * appear})`}}>
			<div style={{display: 'flex', gap: 24, alignItems: 'center'}}>
				<div style={{flex: 1, minWidth: 0}}>
					{number !== undefined ? <div style={{...LABEL, fontSize: 28, color: INK2, marginBottom: 8}}>{`${copy.question} ${number}`}</div> : null}
					<div style={{fontSize: 32, fontWeight: 600, lineHeight: 1.25, color: INK2, display: '-webkit-box', WebkitLineClamp: 3, WebkitBoxOrient: 'vertical', overflow: 'hidden'}}>{q.question}</div>
					<div style={{...LABEL, color: OK, marginTop: 22}}>
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
