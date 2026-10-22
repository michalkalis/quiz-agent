export type Language = 'en' | 'sk' | 'cs';

export type TimedWord = {text: string; startMs: number};

/** One approved question, already shaped for the screen. */
export type ReelQuestion = {
	id: string;
	language: Language;
	category: string;
	question: string;
	answer: string;
	/** One sentence, cut by hand from the question's explanation (never an LLM). */
	why: string;
	/** MCQ options in the order given; empty for an open question. */
	options: string[];
	/** Index into `options` of the right one (MCQ only). */
	correctIndex: number | null;
};

export type ReelProps = {
	q: ReelQuestion;
	/** Path under public/ (staticFile) of the existing app clip, or null = no voice. */
	audio: string | null;
	/** On-screen question words with the moment each one appears. */
	words: TimedWord[];
	/** How long the question phase lasts (voice length, or reading time). */
	questionMs: number;
	/** When the MCQ options start to appear (the voice reaches them). */
	optionsAtMs: number;
	hookIndex: number;
};

export type CarouselSlideProps = {
	kind: 'cover' | 'question' | 'answers';
	language: Language;
	part: number;
	questions: ReelQuestion[];
	/** For kind = 'question': which one (0-based). */
	index: number;
};
