# Prior-Art Research: AI/Prompt-Based Quiz Generation UI

**Date:** 2026-07-03
**Purpose:** UI/UX prior art for the upcoming "generate a quiz from your own prompt" feature ("make me a quiz about 80s rock") in our voice-first, hands-free driving trivia app. Founder constraint: copy proven patterns from existing products — no invented novel screens. Every element below is grounded in a named product with a source URL.
**Method:** 4 parallel research passes (Kahoot, Quizlet, Quizizz/teacher tools, consumer AI-prompt + voice patterns), each claim cited; load-bearing claims spot-checked first-hand against the original source (see Verification Notes at the end).

---

## 1. Kahoot! — AI Question Generator & Kahoot Generator

### 1a. In-editor "Question generator" (adds questions to an existing kahoot)

- **Entry point:** Two paths — (a) Create → Kahoot → "Question generator"; (b) inside an existing kahoot, click "Add question" and select "Question generator". Verbatim from Kahoot's blog: *"Select 'Question generator' to start creating a kahoot with AI (OR start creating a kahoot as normal, click 'Add question', and select 'Question generator'"* ([kahoot.com/blog/2023/06/20/kahoot-ai-social](https://kahoot.com/blog/2023/06/20/kahoot-ai-social/)).
- **Input UI:** A free-text topic field. Kahoot's guidance: keep the topic "short and simple", with example topics like "Books by Shakespeare," "History of football," "Dog breeds," "Space" ([support.kahoot.com — How to generate Kahoot questions with AI](https://support.kahoot.com/hc/en-us/articles/40988856361747-How-to-generate-Kahoot-questions-with-AI)). The generator also offers URL input and PDF upload tabs (same source). The topic description sits in a top bar and can be edited and re-submitted via a "Refresh" button to regenerate the whole batch (same source).
- **Generation flow:** *"Enter your topic, click continue, and watch Kahoot! AI automatically generate the most relevant questions"* ([kahoot.com/blog/2023/06/20/kahoot-ai-social](https://kahoot.com/blog/2023/06/20/kahoot-ai-social/)). The support article describes a loading bar / "wait a moment" state during generation ([support.kahoot.com article 40988856361747](https://support.kahoot.com/hc/en-us/articles/40988856361747-How-to-generate-Kahoot-questions-with-AI)).
- **Preview/edit:** Generated questions appear as expandable cards — *"You can now preview the questions by clicking on the down arrow to view the answers"* — and each question has an individual "Add" button: *"simply select 'Add' and the question will automatically be included in your kahoot"* ([kahoot.com/blog/2023/06/20/kahoot-ai-social](https://kahoot.com/blog/2023/06/20/kahoot-ai-social/)). No per-question regenerate or reject control is documented; "Refresh" regenerates the whole batch.

### 1b. Whole-kahoot "Kahoot Generator" (topic/PDF/URL/Wikipedia → full kahoot)

- **Entry point:** When creating a new kahoot, choose "start from scratch" or the AI-assisted Kahoot Generator ([kahoot.com/ai-tools](https://kahoot.com/ai-tools/)).
- **Input:** *"the option to type in a topic, enter a website URL, or select a specific Wikipedia article"*, plus PDF ([kahoot.com/ai-tools](https://kahoot.com/ai-tools/)).
- **Customization:** A "Choose your format" panel — "Quiz", "True or false", "Scenario practice", "Step-by-step solver" — plus "Skill level" (Beginner/Intermediate/Advanced) and "Kahoot length" (question count) ([support.kahoot.com — How to choose the right format when generating a kahoot with AI](https://support.kahoot.com/hc/en-us/articles/34251401475101-How-to-choose-the-right-format-when-generating-a-kahoot-with-AI)).
- **Preview:** Users "review and customize the questions before saving your game" ([kahoot.com/ai-tools](https://kahoot.com/ai-tools/)).

### 1c. Mobile app

- **Entry point:** App → tap "Create" → "Kahoot Generator", with sub-options "Scan" (scan/upload notes → "Generate kahoot"), "Upload" (choose file → "Generate questions"), or "Add URL" ([support.kahoot.com — How to use Kahoot AI tools in mobile app](https://support.kahoot.com/hc/en-us/articles/32816978203283-How-to-use-Kahoot-AI-tools-in-mobile-app)).
- **Preview:** Topic-based results are reviewed as a list; "Add to kahoot" inserts all generated questions at once — unwanted ones are deselected beforehand rather than rejected individually afterwards (same source).

**Kahoot takeaways:** free-text topic + example topics as guidance; expandable preview cards with tap-to-reveal answers; per-question "Add" (desktop) vs batch add-with-deselect (mobile); "Refresh" to regenerate the batch after editing the prompt.

---

## 2. Quizlet — Magic Notes ("Study Guides") and Q-Chat

### 2a. Magic Notes / Study Guides

- **Entry point:** Select the "Generate" button, then "Study guide"; generated guides live in "Your library" → "Study guides" ([help.quizlet.com — Studying with Study Guides](https://help.quizlet.com/hc/en-us/articles/18312306436365-Studying-with-Study-Guides)).
- **Input UI:** *"Upload your notes by pasting them in or uploading a file"*, then select "Start transforming" (same source). This is note/material-driven, not a topic prompt.
- **Loading states:** Not documented in any official or press source found — an explicit gap.
- **Output review:** Output is an outline + flashcard set + practice test; users *"can edit and tailor your study guide"* via a "More" menu (edit title, adjust visibility, view original uploaded content, delete) (same source). No dedicated preview-before-save step is documented — the artifact saves directly and is edited afterwards. Launched August 2023 as part of Quizlet's AI suite ([prnewswire.com — Quizlet launches advanced AI-powered tools](https://www.prnewswire.com/news-releases/quizlet-launches-advanced-ai-powered-tools-for-next-gen-studying-301895290.html)).
- Secondary sources additionally claim photo-scan and audio input ([efcoachtutors.com](https://efcoachtutors.com/quizlets-ai-features-turn-your-notes-into-flashcards/)) — unverified against official docs; treat as secondary.

### 2b. Q-Chat (discontinued June 2025)

- Q-Chat was Quizlet's Socratic AI tutor, launched March 2023 on the OpenAI API ([prnewswire.com — Quizlet launches Q-Chat](https://www.prnewswire.com/news-releases/quizlet-launches-q-chat-ai-tutor-built-with-openai-api-301759014.html)); it has since been discontinued ([fortune.com](https://fortune.com/education/articles/quizlet-ai-powered-tools-q-chat-magic-notes-quick-summary-gpt/)).
- **Interaction model (historical):** entered from within a study set via a magic-wand icon; interaction driven by mode buttons rather than free chat — "Quiz Me," "Story mode," "Practice with sentences," "Skip" ([fltmag.com — Quizlet Q-Chat review](https://fltmag.com/quizlet-q-chat/)); official activity naming was "Teach Me, Quiz Me, Apply my Knowledge, Practice with Sentences" ([prnewswire.com](https://www.prnewswire.com/news-releases/quizlet-launches-advanced-ai-powered-tools-for-next-gen-studying-301895290.html)).
- **Relevant pattern despite discontinuation:** constraining an open chat into a small set of named activity buttons is a proven way to bound expectations of a conversational agent.

**Quizlet takeaways:** a single global "Generate" entry point; a two-step "provide material → Start transforming" flow; edit-after-save rather than gated preview. Loading-state design is undocumented — no pattern to copy here.

---

## 3. Quizizz AI (now "Wayground") and other teacher tools

Quizizz rebranded to Wayground in 2026; docs live under wayground.com ([wayground.com/quizizz-ai](https://wayground.com/quizizz-ai)).

- **Entry point:** "Create" in the left nav → "Quiz" or "Assessment" → "Generate with AI" → "Text/Prompt" ([help.wayground.com — Generate standards-aligned assessments/quizzes with Wayground AI](https://help.wayground.com/support/solutions/articles/158000405028-generate-standards-aligned-assessments-quizzes-with-wayground-ai)). A business-tier variant is entered via "AI Studio" → "Add a topic, a prompt or paste your excerpt" ([forbusiness-help.wayground.com article 158000411040](https://forbusiness-help.wayground.com/support/solutions/articles/158000411040-wayground-ai-create-a-quiz-instantly-from-prompts-documents-or-web-links)).
- **Input UI:** Free-text box accepting a topic, prompt, or pasted excerpt up to ~10,000 characters; documented example prompt: "Create a quiz on data privacy" (same source). Configurable: number of questions (or "Automatic" — let the AI decide), output language, subject, grade level, standards (up to 5), and Depth of Knowledge levels ([help.wayground.com article 158000405091](https://help.wayground.com/support/solutions/articles/158000405091-wayground-ai-generate-assessments-from-prompts-documents-youtube-more); [article 158000405028](https://help.wayground.com/support/solutions/articles/158000405028-generate-standards-aligned-assessments-quizzes-with-wayground-ai)). After "Continue", users can optionally pick up to 10 subtopics before "Generate quiz" (same sources).
- **Loading:** no documented loading-state copy in official docs.
- **Preview/edit (verified verbatim):** After generation there is a two-path fork — *"Select 'Regenerate with changes' to make changes to the content with the help of AI. After you're happy with the regenerated results, select 'Continue to editor'"*, or *"Select 'Continue to editor' directly to modify questions yourself, change the question types, add or delete answer options, add images, videos, audio clips, etc."* — then "Publish" ([help.wayground.com article 158000405028](https://help.wayground.com/support/solutions/articles/158000405028-generate-standards-aligned-assessments-quizzes-with-wayground-ai)). No per-question accept/reject checkboxes; review happens in bulk in the full editor.

### Other teacher tools (brief)

- **Questgen.ai** — paste text (up to 80,000 words) or a topic; pick question type (MCQ, T/F, fill-blank, higher-order/Bloom's) before generating; edit before exporting to PDF/QTI/Moodle XML ([questgen.ai](https://www.questgen.ai/)).
- **OpExams / OpQuiz** — input long text, topic, link, YouTube, or PDF; in-app editing before export to CSV/XLSX/DOCX or online test ([opexams.com/free-questions-generator](https://opexams.com/free-questions-generator/)).
- **PrepAI** — text (min 100 words), documents, links, or video; explicit "Preview Quiz" button before "Download" ([prepai.io blog](https://www.prepai.io/blog/generate-questions-from-text/)).
- **Twee** — paste topic/link/word list; generates by CEFR level; exports to PDF/Word/Google Forms; no documented preview gate ([twee.com](https://twee.com/)).

**Quizizz takeaways:** the "Automatic" question-count default (AI decides) is the zero-config pattern we want; the post-generation fork "Regenerate with changes" vs "Continue to editor" is the cleanest documented review model. Every teacher tool in this space previews/edits before publishing.

---

## 4. Consumer AI-prompt input patterns (mobile)

### 4a. Free-text "describe what you want" input

- **Spotify Prompted Playlists** (closest consumer analog to our feature — prompt in, playable content out): entry via Create → "Prompted Playlist"; the user describes "a specific vibe, scenario, or cultural moment"; *"Need help getting started? Tap 'Ideas' for quick inspiration"*; Spotify's editors surface *"a mix of playful prompts"* on users' Home screens; *"You can edit your prompt anytime, or start fresh whenever inspiration hits"* ([newsroom.spotify.com — Prompted Playlists expansion, 2026-01-22](https://newsroom.spotify.com/2026-01-22/prompted-playlists-expansion/); [support.spotify.com — Prompted playlists](https://support.spotify.com/us/article/prompted-playlists/)).
- **Google Gemini app:** empty state shows a greeting plus suggested-prompt chips (Create Image, Write, Build, Deep Research…); the suggestion list disappears once the user starts typing ([9to5google.com](https://9to5google.com/2025/09/15/gemini-tools-redesign-android-ios/); [androidauthority.com](https://www.androidauthority.com/gemini-neural-expressive-android-app-hands-on-3668985/)).
- **Perplexity:** the input placeholder is literally "Ask anything" — placeholder text as affordance for open-ended input ([perplexity.ai](https://www.perplexity.ai/); [App Store listing](https://apps.apple.com/us/app/perplexity-ask-anything/id1668000334)).
- **Canva Magic Write/Design:** surfaces suggested prompts and recommends specific, bounded prompts; "More like this" / "This but…" refine before "Insert" commits ([canva.com/help/use-magic-write](https://www.canva.com/help/use-magic-write/); [canva.com/help/use-magic-design](https://www.canva.com/help/use-magic-design/)).
- **Notion AI:** preset action menu first (Summarize, Translate, Improve Writing), free-text as the escape hatch ([zapier.com/blog/how-to-use-notion-ai](https://zapier.com/blog/how-to-use-notion-ai/)).

### 4b. Loading/progress for 10–30s generation

- **Duration guidance (NN/g, verified verbatim):** *"Spinners… are best used when the page takes 2–10 seconds to load"*; *"skeleton screens should be used with a wait time that's under 10 seconds"*; *"progress bars are strongly recommended for any page that takes longer that 10 seconds to load"*; *"Anything above 10 seconds requires an explicit estimation of duration"* ([nngroup.com/articles/skeleton-screens](https://www.nngroup.com/articles/skeleton-screens/)). Our 10–30s generation is squarely in progress-bar-with-stages territory, not spinner territory.
- **Apple HIG:** use a determinate progress indicator when duration is known; indeterminate spinners don't help people estimate wait ([developer.apple.com — Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)).
- **Perplexity staged status:** Pro Search shows an expandable step-by-step plan as it executes ("Searching… Reading… Writing"); Perplexity found *"users were more willing to wait for results if the product would display the intermediate progress"* ([langchain.com/breakoutagents/perplexity](https://www.langchain.com/breakoutagents/perplexity)).
- **ChatGPT streaming:** responses stream token-by-token via SSE, so useful content appears before generation completes ([channel.tel — streaming AI responses](https://www.channel.tel/blog/streaming-ai-responses-sse-websockets-real-time)).
- **Midjourney:** numeric progress percentage during generation, then a 4-image grid ([docs.midjourney.com — Getting Started](https://docs.midjourney.com/hc/en-us/articles/33329261836941-Getting-Started-Guide)).
- **DoorDash and others:** shimmer skeleton screens for structural loads ([nngroup.com/articles/skeleton-screens](https://www.nngroup.com/articles/skeleton-screens/)).

### 4c. Error/retry

- **ChatGPT:** on stalled/failed generation, the documented recovery is "Stop generating" then "Regenerate" ([help.openai.com — troubleshooting](https://help.openai.com/en/articles/7996703-troubleshooting-chatgpt-error-messages); [community.openai.com](https://community.openai.com/t/implementing-a-retry-regenerate-response-feature-assistants-api/559093)).
- **NN/g error guidelines:** positive, nonjudgmental tone; no blame words ("invalid", "illegal"); explicit, human-readable, constructive next step, shown near the error source ([nngroup.com/articles/error-message-guidelines](https://www.nngroup.com/articles/error-message-guidelines/)).

### 4d. Preview before committing

- **Spotify Prompted Playlists:** *"Every song includes a quick one-liner that tells you exactly why it landed in your playlist"* — per-item rationale shown at review; prompt is editable afterwards ([newsroom.spotify.com](https://newsroom.spotify.com/2026-01-22/prompted-playlists-expansion/)).
- **Midjourney / Adobe Firefly:** generate 4 variants in a grid; the user compares and explicitly selects/upscales before committing ([docs.midjourney.com](https://docs.midjourney.com/hc/en-us/articles/33329261836941-Getting-Started-Guide); [helpx.adobe.com — generate images from text](https://helpx.adobe.com/firefly/web/work-with-images/generate-images/generate-images-from-text-descriptions.html)).
- **Canva Magic Write:** iterate ("More like this", "This but…") before "Insert" ([canva.com/help/use-magic-write](https://www.canva.com/help/use-magic-write/)).

---

## 5. Voice-prompt entry (speaking the prompt instead of typing)

- **ChatGPT Voice Mode:** entry point is a voice/waveform icon at the bottom-right of the compose bar; tapping starts either integrated in-chat voice or a full-screen listening mode ("Separate Mode", the blue orb) ([help.openai.com — Voice mode FAQ](https://help.openai.com/en/articles/8400625-voice-mode-faq); [tomsguide.com](https://www.tomsguide.com/ai/chatgpt-now-lets-you-enable-voice-mode-directly-inside-your-chat-without-switching-heres-how)).
- **Google voice search / AI Mode:** mic tap opens a listening UI with a pulsing animation and **real-time transcription displayed above it so the user can visually confirm recognition accuracy before results load** ([9to5google.com — AI Mode voice input](https://9to5google.com/2025/06/02/google-ai-mode-voice-input/)). This live-transcript-as-confirmation is the key voice-input trust pattern.
- **Gemini Live:** "Live" waveform icon in the bottom-right of the app opens a full-duplex spoken conversation the user can interrupt naturally ([gemini.google/overview/gemini-live](https://gemini.google/overview/gemini-live/)).
- **Siri / CarPlay (driving-grade prior art):** activated by the steering-wheel voice button, "Hey Siri", or touch-and-hold on the CarPlay screen; some vehicles support press-and-hold-while-speaking instead of silence detection ([support.apple.com — Use Siri](https://support.apple.com/guide/iphone/use-siri-iph0aa8c80e6/ios); [appleinsider.com — Siri in CarPlay](https://appleinsider.com/inside/carplay/tips/how-to-use-siri-in-carplay-with-or-without-your-voice)).
- **Android Auto / Google Assistant driving mode:** push-to-talk or wake word; the driving UI is deliberately minimalist and glanceable, with everything operable by voice alone to reduce distraction ([makeuseof.com](https://www.makeuseof.com/how-to-use-driving-mode-in-google-assistant/); [slashgear.com](https://www.slashgear.com/1326444/android-auto-vs-google-assistant-driving-mode/)).

---

## 6. Recommended pattern for our app

Every element below names the product it is copied from. Two contexts matter: **parked/passenger** (screen usable) and **driving** (eyes-free, voice only). The same generation backend serves both; only the shell differs.

### 6.1 Entry point — Home, as a first-class create action + example prompts on Home

- A primary "Create a quiz" action on Home, exactly like **Spotify**'s Create → Prompted Playlist ([newsroom.spotify.com](https://newsroom.spotify.com/2026-01-22/prompted-playlists-expansion/)) and **Kahoot mobile**'s Create → Kahoot Generator ([support.kahoot.com](https://support.kahoot.com/hc/en-us/articles/32816978203283-How-to-use-Kahoot-AI-tools-in-mobile-app)).
- Additionally surface a rotating row of ready-made example prompts directly on Home ("80s rock", "Road-trip geography", …), copying **Spotify**'s editor-curated prompts on the Home screen ([newsroom.spotify.com](https://newsroom.spotify.com/2026-01-22/prompted-playlists-expansion/)). Tapping one runs it immediately — zero typing.

### 6.2 Input UI — one free-text field + example chips + mic button, no settings form

- Single free-text topic field with a short open-ended placeholder, copying **Perplexity**'s "Ask anything" ([perplexity.ai](https://www.perplexity.ai/)) — ours phrased for quizzes ("What should your quiz be about?").
- Suggestion chips under the field that disappear on typing, copying **Gemini**'s empty-state suggested prompts ([9to5google.com](https://9to5google.com/2025/09/15/gemini-tools-redesign-android-ios/)) and **Spotify**'s "Ideas" button ([newsroom.spotify.com](https://newsroom.spotify.com/2026-01-22/prompted-playlists-expansion/)). Chip copy should follow **Kahoot**'s "short and simple" topic guidance and example style ("History of football", "Dog breeds") ([support.kahoot.com](https://support.kahoot.com/hc/en-us/articles/40988856361747-How-to-generate-Kahoot-questions-with-AI)).
- Mic button at the trailing edge of the field, copying **ChatGPT**'s voice icon placement in the compose bar ([help.openai.com](https://help.openai.com/en/articles/8400625-voice-mode-faq)) and **Google**'s mic-in-search-bar ([9to5google.com](https://9to5google.com/2025/06/02/google-ai-mode-voice-input/)).
- No settings form. Question count defaults to AI-decided, copying **Wayground**'s "Automatic" number-of-questions option ([help.wayground.com](https://help.wayground.com/support/solutions/articles/158000405091-wayground-ai-generate-assessments-from-prompts-documents-youtube-more)); difficulty/length knobs are omitted from v1 (Kahoot/Wayground have them, but they exist for teachers; Spotify — the consumer analog — has none).
- Recent prompts listed below the chips for one-tap re-run, copying **Spotify**'s "edit your prompt anytime, or start fresh" re-use model ([newsroom.spotify.com](https://newsroom.spotify.com/2026-01-22/prompted-playlists-expansion/)).

### 6.3 Voice-prompt entry (driving mode)

- Mic tap (or in-quiz voice command) opens a full-screen listening state with a pulsing waveform and **live transcription of the spoken topic**, copying **Google AI Mode voice input**'s real-time transcript-above-animation confirmation ([9to5google.com](https://9to5google.com/2025/06/02/google-ai-mode-voice-input/)) and **ChatGPT Voice**'s full-screen listening mode ([help.openai.com](https://help.openai.com/en/articles/8400625-voice-mode-faq)).
- Eyes-free confirmation: after silence-detection ends the utterance, the app reads the interpreted topic back via TTS ("A quiz about 80s rock — starting now") before generation, translating Google's *visual* transcript-confirmation into audio, consistent with **CarPlay Siri**'s spoken, glance-free interaction model ([appleinsider.com](https://appleinsider.com/inside/carplay/tips/how-to-use-siri-in-carplay-with-or-without-your-voice)). A spoken "no / change it" during the read-back cancels — the driving equivalent of editing the transcript.

### 6.4 Loading state (~10–30s)

- Not a bare spinner. Per **NN/g**, anything over 10s needs a progress bar and *"an explicit estimation of duration"* ([nngroup.com](https://www.nngroup.com/articles/skeleton-screens/)); per **Apple HIG**, prefer determinate indicators when duration is known ([developer.apple.com](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)).
- Copy **Perplexity**'s staged-status pattern — a progress bar plus rotating stage labels ("Picking topics… Writing questions… Checking answers") — which Perplexity found makes users measurably more willing to wait ([langchain.com/breakoutagents/perplexity](https://www.langchain.com/breakoutagents/perplexity)). Kahoot itself uses a loading bar here ([support.kahoot.com](https://support.kahoot.com/hc/en-us/articles/40988856361747-How-to-generate-Kahoot-questions-with-AI)).
- In driving mode, the stages are spoken, not shown ("Got it — writing your 80s rock quiz"), reusing the same staged messages over TTS (audio translation of the Perplexity pattern, per the Android Auto principle that everything must work by voice alone — [makeuseof.com](https://www.makeuseof.com/how-to-use-driving-mode-in-google-assistant/)).
- Latency mitigation: start play as soon as the first question is ready while the rest generate in the background, copying **ChatGPT**'s stream-before-complete delivery model ([channel.tel](https://www.channel.tel/blog/streaming-ai-responses-sse-websockets-real-time)). This can cut perceived wait from ~30s to first-question time.

### 6.5 Preview-before-play — yes when parked, no when driving

- **Parked/passenger:** show the generated quiz as a list of expandable question cards (tap to reveal answers), copying **Kahoot**'s down-arrow preview cards ([kahoot.com/blog](https://kahoot.com/blog/2023/06/20/kahoot-ai-social/)), with two actions copying **Wayground**'s verified fork: "Regenerate" (re-run with tweaks) and "Play now" (its "Regenerate with changes" / "Continue to editor" pattern, [help.wayground.com](https://help.wayground.com/support/solutions/articles/158000405028-generate-standards-aligned-assessments-quizzes-with-wayground-ai)).
- **Driving:** skip visual preview entirely — **Android Auto/driving-mode** prior art says driving UIs must be minimal and fully voice-operable ([slashgear.com](https://www.slashgear.com/1326444/android-auto-vs-google-assistant-driving-mode/)). The spoken topic read-back (6.3) plus a spoken quiz title on completion ("Your quiz '80s Rock Legends' is ready — 10 questions. Starting.") replaces preview; in-quiz voice commands ("skip", "new quiz") replace per-question curation — the audio equivalent of **Kahoot mobile**'s batch add-then-adjust model ([support.kahoot.com](https://support.kahoot.com/hc/en-us/articles/32816978203283-How-to-use-Kahoot-AI-tools-in-mobile-app)). The quiz is saved to the library either way, so it can be reviewed/edited later, copying **Quizlet**'s edit-after-save model ("Your library" → edit via "More" menu, [help.quizlet.com](https://help.quizlet.com/hc/en-us/articles/18312306436365-Studying-with-Study-Guides)).

### 6.6 Error handling

- On failure: a short, non-blaming message with one primary "Try again" action, per **NN/g** error guidelines ([nngroup.com/articles/error-message-guidelines](https://www.nngroup.com/articles/error-message-guidelines/)), with retry/regenerate as the recovery verb, copying **ChatGPT**'s "Regenerate" ([help.openai.com](https://help.openai.com/en/articles/7996703-troubleshooting-chatgpt-error-messages)).
- Driving mode: the error is spoken and retry is offered by voice ("That didn't work. Try again?" → "yes"), per the voice-only operability principle ([makeuseof.com](https://www.makeuseof.com/how-to-use-driving-mode-in-google-assistant/)).
- *Inferred extension (no direct prior art, flagged as such):* after a second consecutive failure while driving, offer a pre-made pack on the same/nearest topic instead of a third retry, so the drive is never left without content.

---

## 7. Verification notes

- **Spot-checked first-hand by the synthesizing agent** (fetched and quote-verified at source): Kahoot blog question-generator flow and per-question "Add" ([kahoot.com/blog/2023/06/20/kahoot-ai-social](https://kahoot.com/blog/2023/06/20/kahoot-ai-social/)); Kahoot AI-tools input options ([kahoot.com/ai-tools](https://kahoot.com/ai-tools/)); Wayground "Regenerate with changes"/"Continue to editor" fork verbatim ([help.wayground.com article 158000405028](https://help.wayground.com/support/solutions/articles/158000405028-generate-standards-aligned-assessments-quizzes-with-wayground-ai)); Spotify Prompted Playlists (Ideas button, Home example prompts, per-track one-liner, editable prompt) ([newsroom.spotify.com](https://newsroom.spotify.com/2026-01-22/prompted-playlists-expansion/)); NN/g duration thresholds verbatim ([nngroup.com/articles/skeleton-screens](https://www.nngroup.com/articles/skeleton-screens/)); Quizlet "Generate" → paste/upload → "Start transforming" corroborated via the official help-center article surfaced in search ([help.quizlet.com article 18312306436365](https://help.quizlet.com/hc/en-us/articles/18312306436365-Studying-with-Study-Guides)).
- **Fetch-blocked sources:** support.kahoot.com and help.quizlet.com return HTTP 403 to direct automated fetch; claims from them rest on research-pass reads via search snippets/proxy and are corroborated where possible by the fetchable Kahoot blog/marketing pages. quizlet.com/blog returned 403/451 — Q-Chat claims rest on press releases and the FLTMAG review instead.
- **Known gaps (nothing invented to fill them):** no product documents its generation loading-state copy except Kahoot (loading bar) and Perplexity (staged status); ChatGPT iOS empty-state suggestion-chip copy could not be verified; Kahoot documents no per-question regenerate; Wayground documents no per-question accept/reject.
