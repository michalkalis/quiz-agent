import React from 'react';
import {Composition, Still, type CalculateMetadataFunction} from 'remotion';
import {CarouselSlide} from './CarouselSlide';
import {Reel} from './Reel';
import {Round} from './Round';
import {LEAD_MS, reelTimeline, roundTimeline} from './timing';
import {loadBrandFonts} from './theme';
import type {CarouselSlideProps, ReelProps, RoundProps} from './types';

loadBrandFonts();

const FPS = 30;

// Preview data for `npm run studio` only; real renders pass props from the CLI.
const sampleWords = (text: string, wps = 2.8) =>
	text.split(/\s+/).map((w, i) => ({text: w, startMs: Math.round((i / wps) * 1000)}));

const FIVE_SAMPLE: ReelProps = {
	q: {
		id: 'preview',
		language: 'en',
		category: 'science-nature',
		question: "The word 'galaxy' comes from an Ancient Greek word for an everyday drink. Which drink?",
		answer: 'Milk',
		why: "The Greeks saw the pale band across the night sky as spilled milk, and called it 'galaxias' from 'gala', meaning milk.",
		explanation: "The Greeks saw the pale band across the night sky as spilled milk, and called it 'galaxias' from 'gala', meaning milk. Our own galaxy kept the image: the Milky Way.",
		options: [],
		correctIndex: null,
		labels: [],
	},
	audio: null,
	words: sampleWords("The word 'galaxy' comes from an Ancient Greek word for an everyday drink. Which drink?"),
	questionMs: 5500,
	optionsAtMs: 0,
	optionAtMs: [],
	hookIndex: 0,
	style: {opening: 'fused', explain: 'parts'},
	explain: {
		audio: null,
		words: sampleWords("The Greeks saw the pale band across the night sky as spilled milk, and called it 'galaxias' from 'gala', meaning milk. Our own galaxy kept the image: the Milky Way."),
		parts: [
			{text: "The Greeks saw the pale band across the night sky as spilled milk, and called it 'galaxias' from 'gala', meaning milk.", firstWord: 0},
			{text: 'Our own galaxy kept the image: the Milky Way.', firstWord: 21},
		],
		ms: 10500,
	},
};

const ABC_SAMPLE: ReelProps = {
	...FIVE_SAMPLE,
	q: {
		...FIVE_SAMPLE.q,
		category: 'entertainment',
		question: 'Today San Diego Comic-Con draws well over 100,000 fans. Roughly how many people came to the very first one in 1970?',
		answer: 'About 300',
		why: 'About 300 comic fans met in a hotel basement in 1970.',
		explanation: 'About 300 comic fans met in a hotel basement in 1970.',
		options: ['About 30', 'About 300', 'About 3,000', 'About 30,000'],
		correctIndex: 1,
		labels: ["1", "2", "3"],
	},
	words: sampleWords('Today San Diego Comic-Con draws well over 100,000 fans. Roughly how many people came to the very first one in 1970?'),
	questionMs: 7500,
	optionsAtMs: 5000,
	optionAtMs: [5000, 5800, 6600, 7400],
};

const reelMetadata: CalculateMetadataFunction<ReelProps> = ({props}) => ({
	durationInFrames: Math.ceil(
		(reelTimeline(props.style, props.questionMs + (props.style.opening === 'intro' ? 0 : LEAD_MS), props.explain.ms).totalMs / 1000) * FPS,
	),
});

const ROUND_SAMPLE: RoundProps = {
	items: [FIVE_SAMPLE, FIVE_SAMPLE, FIVE_SAMPLE].map((p) => ({q: p.q, audio: null, words: p.words, questionMs: p.questionMs, answerAudio: null, answerMs: 900})),
	hookIndex: 0,
};

const roundMetadata: CalculateMetadataFunction<RoundProps> = ({props}) => ({
	durationInFrames: Math.ceil(
		(roundTimeline(
			props.items.map((it) => it.questionMs),
			props.items.map((it) => ({answerMs: it.answerMs, whyChars: it.q.why.length})),
		).totalMs /
			1000) *
			FPS,
	),
});

const FiveSeconds: React.FC<ReelProps> = (p) => <Reel {...p} variant="five" />;
const ABC: React.FC<ReelProps> = (p) => <Reel {...p} variant="abc" />;

export const RemotionRoot: React.FC = () => (
	<>
		<Composition
			id="FiveSeconds"
			component={FiveSeconds}
			width={1080}
			height={1920}
			fps={FPS}
			durationInFrames={510}
			defaultProps={FIVE_SAMPLE}
			calculateMetadata={reelMetadata}
		/>
		<Composition
			id="ABC"
			component={ABC}
			width={1080}
			height={1920}
			fps={FPS}
			durationInFrames={600}
			defaultProps={ABC_SAMPLE}
			calculateMetadata={reelMetadata}
		/>
		<Composition
			id="Round"
			component={Round}
			width={1080}
			height={1920}
			fps={FPS}
			durationInFrames={1500}
			defaultProps={ROUND_SAMPLE}
			calculateMetadata={roundMetadata}
		/>
		<Still
			id="CarouselSlide"
			component={CarouselSlide}
			width={1080}
			height={1350}
			defaultProps={
				{
					kind: 'cover',
					language: 'en',
					part: 1,
					questions: [FIVE_SAMPLE.q, ABC_SAMPLE.q],
					index: 0,
				} satisfies CarouselSlideProps
			}
		/>
	</>
);
