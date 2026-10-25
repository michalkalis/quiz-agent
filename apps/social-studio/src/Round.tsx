// Round reel (9:16): 3 or 5 open questions in a row, easiest first, each read
// by the app voice with a countdown that says the answers come at the end
// (founder 2026-10-25). Then the answers one by one: each read aloud, its
// explanation shown for a few seconds. A tally (2/5) shows how far in the
// viewer is.
import React from 'react';
import {AbsoluteFill, Audio, Sequence, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {COPY} from './copy';
import {fitWhy} from './fitWhy';
import {Monkey} from './Monkey';
import {Countdown, EndCard, HOOK_HOLD_MS, HookLine, Logo, QuestionCard, SAFE, SMALL_Q, f, ms} from './ReelParts';
import {FONT, INK, INK2, OK, SURF, tintFor} from './theme';
import {roundTimeline} from './timing';
import type {RoundItem, RoundProps} from './types';

const Tally: React.FC<{n: number; of: number; color: string}> = ({n, of, color}) => (
	<div style={{position: 'absolute', top: SAFE.top + 8, right: SAFE.right, display: 'flex', gap: 10, alignItems: 'center'}}>
		{Array.from({length: of}, (_, i) => (
			<div key={i} style={{width: i === n ? 46 : 18, height: 18, borderRadius: 9, background: color, opacity: i <= n ? 1 : 0.35}} />
		))}
		<div style={{fontSize: 40, fontWeight: 800, color, marginLeft: 6}}>
			{n + 1}/{of}
		</div>
	</div>
);

/** One answer: the question small, the answer big (read aloud), then its explanation. */
const AnswerReveal: React.FC<{it: RoundItem; appear: number; why: number; startFrame: number}> = ({it, appear, why, startFrame}) => {
	const copy = COPY[it.q.language];
	// Text column = reel width (920) − card padding (104).
	const text = fitWhy(it.q.why, {width: 920 - 104, maxLines: 5, size: 44, minSize: 36});
	return (
		<div style={{background: SURF, borderRadius: 44, padding: '44px 52px 48px', boxShadow: '0 22px 44px rgba(17,18,22,.18)', opacity: appear, transform: `scale(${0.94 + 0.06 * appear})`}}>
			<div style={{display: 'flex', gap: 24, alignItems: 'center'}}>
				<div style={{flex: 1, minWidth: 0}}>
					<div style={{fontSize: 32, fontWeight: 600, lineHeight: 1.25, color: INK2, display: '-webkit-box', WebkitLineClamp: 3, WebkitBoxOrient: 'vertical', overflow: 'hidden'}}>{it.q.question}</div>
					<div style={{fontSize: 32, fontWeight: 700, color: OK, textTransform: 'uppercase', letterSpacing: 2, marginTop: 22}}>{copy.answer}</div>
					<div style={{fontSize: 76, fontWeight: 800, lineHeight: 1.05, marginTop: 8, letterSpacing: -1}}>{it.q.answer}</div>
				</div>
				<Monkey size={130} mood="happy" delay={startFrame} />
			</div>
			{text.text ? (
				<div style={{fontSize: text.size, lineHeight: 1.3, color: INK2, fontWeight: 500, marginTop: 28, opacity: why, transform: `translateY(${(1 - why) * 16}px)`}}>{text.text}</div>
			) : null}
		</div>
	);
};

export const Round: React.FC<RoundProps> = ({items}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const now = ms(frame, fps);
	const t = roundTimeline(
		items.map((it) => it.questionMs),
		items.map((it) => ({answerMs: it.answerMs, whyChars: it.q.why.length})),
	);
	const last = items[items.length - 1];
	const enter = (atMs: number, damping = 18) => spring({frame: frame - f(atMs, fps), fps, config: {damping, mass: 0.7}});
	const clip = (src: string | null, from: number, to: number, key: string) =>
		src ? (
			<Sequence key={key} from={f(from, fps)} durationInFrames={Math.max(1, f(to - from, fps))}>
				<Audio src={staticFile(src)} />
			</Sequence>
		) : null;
	const audio = [
		...items.map((it, k) => clip(it.audio, t.steps[k].voiceStart, t.steps[k].cdStart, `q${k}`)),
		...items.map((it, k) => clip(it.answerAudio, t.reveals[k].voiceStart, t.reveals[k].end, `a${k}`)),
	];

	if (now >= t.endStart) {
		return (
			<AbsoluteFill style={{backgroundColor: tintFor(last.q.category).bg, fontFamily: FONT, color: INK}}>
				<EndCard q={last.q} appear={enter(t.endStart)} startFrame={f(t.endStart, fps)} />
			</AbsoluteFill>
		);
	}

	// Answers one by one, each in its question's colour.
	if (now >= t.answersStart) {
		const k = Math.max(0, t.reveals.findIndex((r) => now < r.end));
		const r = t.reveals[k];
		const it = items[k];
		const tint = tintFor(it.q.category);
		return (
			<AbsoluteFill style={{backgroundColor: tint.bg, fontFamily: FONT, color: INK}}>
				{audio}
				<Logo color={tint.onBg} />
				<Tally n={k} of={items.length} color={tint.onBg} />
				<div style={{position: 'absolute', top: SAFE.top + 140, left: SAFE.left, right: SAFE.right - 50, bottom: SAFE.bottom}}>
					<AnswerReveal key={k} it={it} appear={enter(r.start, 16)} why={enter(r.whyStart, 20)} startFrame={f(r.start, fps)} />
				</div>
			</AbsoluteFill>
		);
	}
	const i = Math.max(0, t.steps.findIndex((s) => now < s.end));
	const step = t.steps[i];
	const item = items[i];
	const tint = tintFor(item.q.category);
	// The first question opens under the fixed hook line, then grows (as in the one-question reel).
	const grow = i === 0 ? spring({frame: frame - f(HOOK_HOLD_MS, fps), fps, config: {damping: 20, mass: 0.8}}) : 1;
	return (
		<AbsoluteFill style={{backgroundColor: tint.bg, fontFamily: FONT, color: INK}}>
			{audio}
			<Logo color={tint.onBg} />
			<Tally n={i} of={items.length} color={tint.onBg} />
			<div style={{position: 'absolute', top: SAFE.top + 140, left: SAFE.left, right: SAFE.right - 50, bottom: SAFE.bottom, display: 'flex', flexDirection: 'column', gap: 44}}>
				{i === 0 ? <HookLine text={COPY[item.q.language].roundHook(items.length)} color={tint.onBg} grow={grow} /> : null}
				<QuestionCard
					q={item.q}
					words={item.words}
					tMs={now - step.voiceStart}
					optionsAtMs={step.cdStart - step.voiceStart}
					revealed={false}
					appear={i === 0 ? 1 : enter(step.start)}
					readable
					scale={i === 0 ? SMALL_Q + (1 - SMALL_Q) * grow : 1}
					markBg={tint.bg}
					markInk={tint.onBg}
				/>
				{now >= step.cdStart ? <Countdown startFrame={f(step.cdStart, fps)} onBg={tint.onBg} note={COPY[item.q.language].answersAtEnd} seconds={t.countdownMs / 1000} /> : null}
			</div>
			{now < step.cdStart ? (
				<div style={{position: 'absolute', right: SAFE.right + 10, bottom: SAFE.bottom - 40, opacity: i === 0 ? enter(200) : 1}}>
					<Monkey size={190} mood="idle" />
				</div>
			) : null}
		</AbsoluteFill>
	);
};
