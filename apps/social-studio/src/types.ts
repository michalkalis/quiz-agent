export type Language = 'en' | 'sk' | 'cs';

export type TimedWord = {text: string; startMs: number};

/** One approved question, already shaped for the screen. */
export type ReelQuestion = {
	id: string;
	language: Language;
	category: string;
	question: string;
	answer: string;
	/** First full sentence of the question's explanation (never an LLM); fitWhy fits it on the card. */
	why: string;
	/** The whole explanation, unchanged (reels read it aloud in parts). */
	explanation: string;
	/** MCQ options in the order given; empty for an open question. */
	options: string[];
	/** Index into `options` of the right one (MCQ only). */
	correctIndex: number | null;
	/** Option labels as the app shows and reads them: 1–4, or A–D when an option is a number. */
	labels: string[];
};

/** How the reel opens: a separate hook card before the question (the v1
 * reel), a hook line on screen with the question from frame 1, the
 * question alone, or (founder 2026-10-26) the hook alone, big and centred,
 * then the question readable in full. */
export type Opening = 'intro' | 'fused' | 'plain' | 'solo';
/** How the explanation is shown: its first sentence under the answer (v1),
 * the whole explanation read part by part, big spoken-word captions, or
 * (founder 2026-10-25) one card: the answer read aloud, the whole explanation shown under it. */
export type ExplainStyle = 'line' | 'parts' | 'captions' | 'card';
export type ReelStyle = {opening: Opening; explain: ExplainStyle};

/** The explanation phase: the whole text, timed to its clip (or reading pace). */
export type ExplainTrack = {
	audio: string | null;
	words: TimedWord[];
	/** Parts of at most ~110 characters, each with the index of its first word. */
	parts: {text: string; firstWord: number}[];
	ms: number;
};

export type ReelProps = {
	style: ReelStyle;
	explain: ExplainTrack;
	/** The answer said by the app voice ('card' style), or null = shown only. */
	answer: {audio: string | null; ms: number};
	q: ReelQuestion;
	/** Path under public/ (staticFile) of the existing app clip, or null = no voice. */
	audio: string | null;
	/** On-screen question words with the moment each one appears. */
	words: TimedWord[];
	/** How long the question phase lasts (voice length, or reading time). */
	questionMs: number;
	/** When the MCQ options start to appear (the voice reaches them). */
	optionsAtMs: number;
	/** When the voice starts reading each MCQ option, then when it stops (empty for open questions). */
	optionAtMs: number[];
	hookIndex: number;
};

export type CarouselSlideProps = {
	kind: 'cover' | 'question' | 'answers';
	language: Language;
	part: number;
	questions: ReelQuestion[];
	/** kind = 'question': which one (0-based); kind = 'answers': which answers slide (0-based). */
	index: number;
};

/** One question of a round reel, timed like a one-question reel, plus its answer read aloud at the end. */
export type RoundItem = {
	q: ReelQuestion;
	audio: string | null;
	words: TimedWord[];
	questionMs: number;
	/** The answer said by the app voice (path under public/), or null = shown only. */
	answerAudio: string | null;
	answerMs: number;
};

export type RoundProps = {
	items: RoundItem[];
	hookIndex: number;
	/** `solo`: the hook line alone before the first question; otherwise fused onto it. */
	opening?: Opening;
};
