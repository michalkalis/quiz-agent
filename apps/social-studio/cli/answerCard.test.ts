// The voice reads the answer and then the whole explanation (founder
// 2026-11-16), so the answer card must show the whole explanation too. Rounds
// used to show only its first sentence while the voice read on (founder
// report 2026-11-18): the viewer heard sentences that were nowhere on screen.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {Thumbnail} from '@remotion/player';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {Reel} from '../src/Reel';
import {Round} from '../src/Round';
import {HOOK_SOLO_MS, LEAD_MS, reelTimeline, roundTimeline} from '../src/timing';
import type {ReelProps, ReelQuestion, RoundProps} from '../src/types';

const FPS = 30;
const FIRST = 'Ženích ju tam musí nájsť a vykúpiť.';
const SECOND = 'Výkupné býva často celý účet, ktorý si únoscovia medzitým stihli objednať.';
const q: ReelQuestion = {
	id: 'b6b5e315',
	language: 'sk',
	category: 'general',
	question: 'Keď kamaráti počas svadby „unesú“ nevestu, kam ju podľa tradície najčastejšie odvedú?',
	answer: 'do krčmy',
	why: FIRST,
	explanation: `${FIRST} ${SECOND}`,
	options: [],
	correctIndex: null,
	labels: [],
};
const words = q.question.split(' ').map((text, i) => ({text, startMs: i * 300}));
const ANSWER_MS = 7000; // the answer clip: answer + whole explanation

/** The frame as markup (fitWhy keeps the whole text when there is no canvas to measure with). */
const frameAt = (component: React.FC<never>, inputProps: object, ms: number) =>
	renderToStaticMarkup(
		React.createElement(Thumbnail, {
			component: component as React.FC<Record<string, unknown>>,
			inputProps: inputProps as Record<string, unknown>,
			frameToDisplay: Math.round((ms * FPS) / 1000),
			durationInFrames: 10_000,
			compositionWidth: 1080,
			compositionHeight: 1920,
			fps: FPS,
		}),
	);

test('a round shows the whole explanation the voice reads, not just its first sentence', () => {
	const props: RoundProps = {items: [{q, audio: null, words, questionMs: 4000, answerAudio: null, answerMs: ANSWER_MS}], hookIndex: 0, opening: 'solo'};
	const r = roundTimeline([4000], [{answerMs: ANSWER_MS, whyChars: q.explanation.length}], HOOK_SOLO_MS).reveals[0];
	const html = frameAt(Round, props, r.end - 100);
	assert.ok(html.includes(FIRST), 'first sentence on the card');
	assert.ok(html.includes(SECOND), 'the sentence the voice reads after it is on the card too');
});

test('a one-question reel shows the whole explanation the voice reads', () => {
	const props: ReelProps = {
		style: {opening: 'solo', explain: 'card'},
		explain: {audio: null, words: [], parts: [], ms: 0},
		answer: {audio: null, ms: ANSWER_MS},
		q,
		audio: null,
		words,
		questionMs: 4000,
		optionsAtMs: 0,
		optionAtMs: [],
		hookIndex: 0,
	};
	const t = reelTimeline(props.style, props.questionMs + LEAD_MS, 0, ANSWER_MS, q.explanation.length);
	const html = frameAt(Reel, props, t.endStart - 100);
	assert.ok(html.includes(FIRST) && html.includes(SECOND), 'whole explanation on the card');
});
