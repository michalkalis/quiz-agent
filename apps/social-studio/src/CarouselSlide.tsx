// "Road Trip Round" carousel (4:5 stills): cover, one question per slide,
// answers on the last slide.
import React from 'react';
import {AbsoluteFill} from 'remotion';
import {COPY} from './copy';
import {fitWhy} from './fitWhy';
import {Monkey} from './Monkey';
import {FONT, INK, INK2, OK, SURF, tintFor} from './theme';
import type {CarouselSlideProps} from './types';

const PAD = 84;
/** More than 4 answers with their why line do not fit one 1350 px slide. */
export const ANSWERS_PER_SLIDE = 4;

const Brand: React.FC<{color: string}> = ({color}) => (
	<div style={{display: 'flex', alignItems: 'center', gap: 16}}>
		<div style={{width: 68, height: 68, borderRadius: 34, background: SURF, display: 'flex', justifyContent: 'center', alignItems: 'center'}}>
			<Monkey size={52} />
		</div>
		<div style={{fontSize: 42, fontWeight: 800, color, letterSpacing: -0.5}}>Trubbo</div>
	</div>
);

// Answer text column = slide (1080) − padding − card padding − number − gap.
const Why: React.FC<{sentence: string}> = ({sentence}) => {
	const why = fitWhy(sentence, {width: 1080 - 2 * PAD - 80 - 40 - 28, maxLines: 3, size: 32, minSize: 26});
	return why.text ? <div style={{fontSize: why.size, lineHeight: 1.3, color: INK2, marginTop: 10, fontWeight: 500}}>{why.text}</div> : null;
};

export const CarouselSlide: React.FC<CarouselSlideProps> = ({kind, language, part, questions, index}) => {
	const copy = COPY[language];
	const q = questions[index];
	const tint = kind === 'question' && q ? tintFor(q.category) : tintFor('geography-world');

	return (
		<AbsoluteFill style={{backgroundColor: tint.bg, fontFamily: FONT, color: INK, padding: PAD, display: 'flex', flexDirection: 'column'}}>
			<div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'center'}}>
				<Brand color={tint.onBg} />
				{kind === 'question' ? (
					<div style={{fontSize: 40, fontWeight: 700, color: tint.onBg, opacity: 0.9}}>
						{index + 1}/{questions.length}
					</div>
				) : null}
			</div>

			{kind === 'cover' ? (
				<div style={{flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 36}}>
					<div style={{fontSize: 112, fontWeight: 800, lineHeight: 1.02, color: tint.onBg, letterSpacing: -2}}>{copy.roundTitle(part)}</div>
					<div style={{fontSize: 48, fontWeight: 600, lineHeight: 1.25, color: tint.onBg, opacity: 0.9}}>{copy.roundSub(questions.length)}</div>
					<div style={{display: 'flex', justifyContent: 'flex-end', alignItems: 'flex-end', gap: 30, marginTop: 20}}>
						<div style={{fontSize: 40, fontWeight: 700, color: tint.onBg, marginBottom: 40}}>{copy.swipe} →</div>
						<Monkey size={300} mood="thinking" />
					</div>
				</div>
			) : null}

			{kind === 'question' && q ? (
				<div style={{flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 40}}>
					<div style={{background: SURF, borderRadius: 44, padding: '64px 60px', boxShadow: '0 22px 44px rgba(17,18,22,.18)'}}>
						<div style={{fontSize: q.question.length > 110 ? 60 : 68, fontWeight: 700, lineHeight: 1.17, letterSpacing: -0.6}}>{q.question}</div>
					</div>
					<div style={{display: 'flex', justifyContent: 'flex-end'}}>
						<Monkey size={200} mood="thinking" />
					</div>
				</div>
			) : null}

			{kind === 'answers' ? (
				<div style={{flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 28}}>
					<div style={{fontSize: 80, fontWeight: 800, color: tint.onBg, letterSpacing: -1.2, marginBottom: 8}}>{copy.answersTitle}</div>
					{questions.slice(index * ANSWERS_PER_SLIDE, (index + 1) * ANSWERS_PER_SLIDE).map((a, j) => {
						const i = index * ANSWERS_PER_SLIDE + j;
						return (
						<div key={a.id} style={{background: SURF, borderRadius: 36, padding: '30px 40px', display: 'flex', gap: 28, alignItems: 'flex-start'}}>
							<div style={{fontSize: 48, fontWeight: 800, color: OK, minWidth: 40}}>{i + 1}</div>
							<div>
								<div style={{fontSize: 50, fontWeight: 800, lineHeight: 1.1}}>{a.answer}</div>
								<Why sentence={a.why} />

							</div>
						</div>
						);
					})}
				</div>
			) : null}
		</AbsoluteFill>
	);
};
