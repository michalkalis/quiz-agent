// Answer + the whole explanation, read by the app voice (#210 founder pick
// 2026-10-24: the explanation is the interesting part, the v1 reel showed
// one sentence for 4 s). Two ways to show it: part by part on a card, or as
// big spoken-word captions under the answer.
import React from 'react';
import {Audio, Sequence, interpolate, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {COPY, LETTERS} from './copy';
import {Monkey} from './Monkey';
import {FONT, INK, INK2, OK, SURF} from './theme';
import type {ExplainStyle, ExplainTrack, ReelQuestion, TimedWord} from './types';

const CARD = {background: SURF, borderRadius: 44, boxShadow: '0 22px 44px rgba(17,18,22,.18)'} as const;

/** Index of the word being said at `t` (ms from the explanation start), -1 before the first. */
const wordAt = (words: TimedWord[], t: number) => {
	let i = -1;
	while (i + 1 < words.length && words[i + 1].startMs <= t) i++;
	return i;
};

/** Numbers and names stand out a little: digits, or a capital that does not start a sentence. */
const isKey = (word: string, prev: string | undefined) =>
	/\d/.test(word) || (/^["'„“(]?\p{Lu}/u.test(word) && prev !== undefined && !/[.!?:]$/.test(prev));

export const AnswerCard: React.FC<{q: ReelQuestion; abc: boolean; appear: number; startFrame: number; compact: boolean}> = ({q, abc, appear, startFrame, compact}) => {
	const copy = COPY[q.language];
	return (
		<div style={{...CARD, padding: '40px 52px 44px', display: 'flex', gap: 28, alignItems: 'center', opacity: appear, transform: `scale(${0.94 + 0.06 * appear})`}}>
			<div style={{flex: 1}}>
				<div style={{fontSize: 32, fontWeight: 600, lineHeight: 1.25, color: INK2, display: '-webkit-box', WebkitLineClamp: compact ? 2 : 3, WebkitBoxOrient: 'vertical', overflow: 'hidden'}}>
					{q.question}
				</div>
				<div style={{fontSize: 32, fontWeight: 700, color: OK, textTransform: 'uppercase', letterSpacing: 2, marginTop: 22}}>
					{copy.answer}
					{abc && q.correctIndex !== null ? ` ${LETTERS[q.correctIndex]}` : ''}
				</div>
				<div style={{fontSize: compact ? 64 : 76, fontWeight: 800, lineHeight: 1.05, marginTop: 8, letterSpacing: -1}}>{q.answer}</div>
			</div>
			<Monkey size={compact ? 120 : 150} mood="happy" delay={startFrame} />
		</div>
	);
};

/** One part at a time on a card, the word being said marked, dots for progress. */
const Parts: React.FC<{track: ExplainTrack; t: number; markBg: string; markInk: string}> = ({track, t, markBg, markInk}) => {
	const current = wordAt(track.words, t);
	let part = 0;
	while (part + 1 < track.parts.length && track.parts[part + 1].firstWord <= Math.max(0, current)) part++;
	const first = track.parts[part].firstWord;
	const last = part + 1 < track.parts.length ? track.parts[part + 1].firstWord : track.words.length;
	const partStart = track.words[first]?.startMs ?? 0;
	const fade = interpolate(t, [partStart - 120, partStart + 120], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
	const words = track.words.slice(first, last);
	return (
		<div style={{display: 'flex', flexDirection: 'column', gap: 26}}>
			<div style={{...CARD, padding: '48px 52px 52px', minHeight: 300, display: 'flex', alignItems: 'center'}}>
				<div style={{fontSize: 60, fontWeight: 600, lineHeight: 1.28, letterSpacing: -0.4, opacity: part === 0 ? 1 : fade, color: INK}}>
					{words.map((w, i) => {
						const k = first + i;
						const on = k === current;
						return (
							<React.Fragment key={k}>
								<span
									style={{
										fontWeight: isKey(w.text, track.words[k - 1]?.text) ? 800 : 600,
										background: on ? markBg : 'transparent',
										color: on ? markInk : INK,
										borderRadius: 12,
										padding: '0 6px',
										margin: '0 -6px',
									}}
								>
									{w.text}
								</span>
								{i < words.length - 1 ? ' ' : ''}
							</React.Fragment>
						);
					})}
				</div>
			</div>
			{track.parts.length > 1 ? (
				<div style={{display: 'flex', justifyContent: 'center', gap: 14}}>
					{track.parts.map((_, i) => (
						<div key={i} style={{width: i === part ? 40 : 16, height: 16, borderRadius: 8, background: SURF, opacity: i === part ? 1 : 0.5}} />
					))}
				</div>
			) : null}
		</div>
	);
};

/** Words grouped into short caption phrases: up to 4 words / 22 characters (one line), ending early at punctuation. */
export const captionPhrases = (words: TimedWord[]): {from: number; to: number}[] => {
	const out: {from: number; to: number}[] = [];
	let from = 0;
	let chars = 0;
	words.forEach((w, i) => {
		chars += w.text.length + 1;
		const n = i - from + 1;
		const next = words[i + 1];
		if (!next || n >= 4 || /[,.;:!?]$/.test(w.text) || chars + next.text.length > 22) {
			out.push({from, to: i + 1});
			from = i + 1;
			chars = 0;
		}
	});
	return out;
};

/** Big captions of the words being said, lower middle, kept above the bottom 35 % that
 * Meta's safe zone reserves for the caption and buttons. Positioned in the reel's content
 * column, which starts 310 px from the top. */
const Captions: React.FC<{track: ExplainTrack; t: number}> = ({track, t}) => {
	const current = wordAt(track.words, t);
	if (current < 0) return null;
	const phrase = captionPhrases(track.words).find((p) => current >= p.from && current < p.to)!;
	return (
		<div style={{position: 'absolute', left: 60, right: 110, top: 760, display: 'flex', justifyContent: 'center'}}>
			<div style={{background: 'rgba(17,18,22,.88)', borderRadius: 28, padding: '22px 36px', textAlign: 'center', fontFamily: FONT}}>
				{track.words.slice(phrase.from, phrase.to).map((w, i) => {
					const k = phrase.from + i;
					return (
						<span key={k} style={{fontSize: 72, fontWeight: 800, letterSpacing: -1, color: k === current ? '#FFD23F' : SURF}}>
							{w.text}
							{k < phrase.to - 1 ? ' ' : ''}
						</span>
					);
				})}
			</div>
		</div>
	);
};

export const ExplainPhase: React.FC<{
	q: ReelQuestion;
	abc: boolean;
	style: Exclude<ExplainStyle, 'line'>;
	track: ExplainTrack;
	revealFrame: number;
	whyFrame: number;
	appear: number;
	markBg: string;
	markInk: string;
}> = ({q, abc, style, track, revealFrame, whyFrame, appear, markBg, markInk}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const t = ((frame - whyFrame) / fps) * 1000;
	return (
		<>
			{track.audio ? (
				<Sequence from={whyFrame}>
					<Audio src={staticFile(track.audio)} />
				</Sequence>
			) : null}
			<div style={{display: 'flex', flexDirection: 'column', gap: 36}}>
				<AnswerCard q={q} abc={abc} appear={appear} startFrame={revealFrame} compact={style === 'parts'} />
				{style === 'parts' && t >= 0 ? <Parts track={track} t={t} markBg={markBg} markInk={markInk} /> : null}
			</div>
			{style === 'captions' && t >= 0 ? <Captions track={track} t={t} /> : null}
		</>
	);
};
