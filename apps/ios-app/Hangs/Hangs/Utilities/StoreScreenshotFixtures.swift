//
//  StoreScreenshotFixtures.swift
//  Hangs
//
//  App Store screenshot mode (#190 — store listing readiness). Active only in
//  DEBUG builds launched with `--ui-test --store-screenshots`. Supplies
//  hand-written, listing-quality content in the quiz language (en / sk / cs) so
//  raw store screenshots show real-looking questions instead of the generic
//  `Question.preview` fixtures, and hides every debug-only surface.
//
//  Launch args (all optional beyond the two flags):
//  - `-quizLanguage sk|cs|en`   force the content language (UserDefaults arg domain)
//  - `--store-scene <name>`     seed a static scene: listening | confirm | result | mcq
//    (no value = Home; the custom-pack summary is reached through the UI).
//

#if DEBUG

    import Foundation

    enum StoreScreenshotFixtures {
        // MARK: - Mode switches

        static var isActive: Bool {
            CommandLine.arguments.contains("--store-screenshots")
        }

        /// The static scene named after `--store-scene`, nil for Home.
        static var scene: String? {
            let args = CommandLine.arguments
            guard let i = args.firstIndex(of: "--store-scene"), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        /// Content / quiz language: the `-quizLanguage` launch arg (UserDefaults
        /// arg domain), defaulting to English. The mock persistence store has no
        /// saved language of its own, so this is what seeds the quiz-language setting.
        static var quizLanguage: String {
            UserDefaults.standard.string(forKey: "quizLanguage") ?? "en"
        }

        // MARK: - Content

        struct Content: Equatable {
            let openQuestion: String
            let openAnswer: String
            let openExplanation: String
            let openSourceUrl: String
            let mcqQuestion: String
            /// Options in display order a..d; `mcqCorrectKey` is the right one.
            let mcqOptions: [String]
            let mcqExplanation: String
            let packTopic: String
            /// Short label for the Home "my packs" row (one line, no truncation).
            let packRowLabel: String
        }

        static let mcqCorrectKey = "c"

        static func content(forQuizLanguage language: String) -> Content {
            switch language {
            case "sk":
                return Content(
                    openQuestion: "Ktorá planéta má najkratší deň v slnečnej sústave?",
                    openAnswer: "Jupiter",
                    openExplanation: "Jupiter sa otočí okolo svojej osi za necelých 10 hodín, rýchlejšie ako ktorákoľvek iná planéta. Rýchla rotácia ho dokonca na póloch mierne splošťuje.",
                    openSourceUrl: "https://sk.wikipedia.org/wiki/Jupiter_(planéta)",
                    mcqQuestion: "Ktorá krajina má najviac časových pásiem, ak rátame aj zámorské územia?",
                    mcqOptions: ["Rusko", "Spojené štáty", "Francúzsko", "Čína"],
                    mcqExplanation: "Francúzsko pokrýva 12 časových pásiem vďaka zámorským územiam, ako sú Francúzska Polynézia, Réunion či Nová Kaledónia.",
                    packTopic: "Vesmír pre deti: planéty, rakety a astronauti",
                    packRowLabel: "Vesmír pre deti"
                )
            case "cs":
                return Content(
                    openQuestion: "Která planeta má nejkratší den ve Sluneční soustavě?",
                    openAnswer: "Jupiter",
                    openExplanation: "Jupiter se otočí kolem své osy za necelých 10 hodin, rychleji než kterákoli jiná planeta. Rychlá rotace ho dokonce na pólech mírně zplošťuje.",
                    openSourceUrl: "https://cs.wikipedia.org/wiki/Jupiter_(planeta)",
                    mcqQuestion: "Která země má nejvíce časových pásem, když počítáme i zámořská území?",
                    mcqOptions: ["Rusko", "Spojené státy", "Francie", "Čína"],
                    mcqExplanation: "Francie pokrývá 12 časových pásem díky zámořským územím, jako jsou Francouzská Polynésie, Réunion nebo Nová Kaledonie.",
                    packTopic: "Vesmír pro děti: planety, rakety a astronauti",
                    packRowLabel: "Vesmír pro děti"
                )
            default:
                return Content(
                    openQuestion: "Which planet has the shortest day in the Solar System?",
                    openAnswer: "Jupiter",
                    openExplanation: "Jupiter spins once in just under 10 hours, faster than any other planet. The quick spin even flattens it slightly at the poles.",
                    openSourceUrl: "https://en.wikipedia.org/wiki/Jupiter",
                    mcqQuestion: "Which country has the most time zones, counting its overseas territories?",
                    mcqOptions: ["Russia", "United States", "France", "China"],
                    mcqExplanation: "France covers 12 time zones thanks to overseas territories such as French Polynesia, Réunion and New Caledonia.",
                    packTopic: "Space for kids: planets, rockets and astronauts",
                    packRowLabel: "Space for kids"
                )
            }
        }

        // MARK: - Models

        static func openQuestion(_ c: Content, language: String) -> Question {
            Question(
                id: "q_store_open",
                question: c.openQuestion,
                type: .text,
                possibleAnswers: nil,
                difficulty: "medium",
                topic: "Astronomy",
                category: "science-nature",
                sourceUrl: c.openSourceUrl,
                sourceExcerpt: nil,
                mediaUrl: nil,
                imageSubtype: nil,
                explanation: c.openExplanation,
                generatedBy: nil,
                language: language
            )
        }

        static func mcqQuestion(_ c: Content, language: String) -> Question {
            let keys = ["a", "b", "c", "d"]
            return Question(
                id: "q_store_mcq",
                question: c.mcqQuestion,
                type: .textMultichoice,
                possibleAnswers: Dictionary(uniqueKeysWithValues: zip(keys, c.mcqOptions)),
                difficulty: "medium",
                topic: "Time zones",
                category: "geography-world",
                sourceUrl: nil,
                sourceExcerpt: nil,
                mediaUrl: nil,
                imageSubtype: nil,
                explanation: c.mcqExplanation,
                generatedBy: nil,
                language: language,
                optionLabels: ["a": "1", "b": "2", "c": "3", "d": "4"]
            )
        }

        static func correctEvaluation(_ c: Content, questionId: String) -> Evaluation {
            Evaluation(
                userAnswer: c.openAnswer,
                result: .correct,
                points: 1.0,
                correctAnswer: c.openAnswer,
                questionId: questionId,
                explanation: c.openExplanation
            )
        }

        static func session(answered: Int = 0, correct: Int = 0) -> QuizSession {
            QuizSession.preview(
                score: Double(correct), answered: answered, correct: correct, maxQuestions: 10
            )
        }

        static func quizResponse(
            question: Question, evaluation: Evaluation? = nil, answered: Int = 0, correct: Int = 0
        ) -> QuizResponse {
            QuizResponse(
                success: true,
                message: "Store screenshots",
                session: session(answered: answered, correct: correct),
                currentQuestion: question,
                evaluation: evaluation,
                feedbackReceived: [],
                audio: AudioInfo(
                    feedbackUrl: nil, feedbackAudioBase64: nil, questionUrl: nil, format: "opus"
                )
            )
        }

        /// Home plan card: a free user with questions left, no pack credits.
        static var usage: UsageInfo {
            UsageInfo(
                userId: "mock-subject", isPremium: false, questionsUsed: 8,
                questionsLimit: 30, remaining: 22,
                resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(19 * 86400)),
                subscriptionStatus: "none", creditBalance: 0
            )
        }

        /// One ready (delivered, playable) custom pack for Home "my packs".
        /// The row label is the pack's `category`, so it carries the localized topic.
        static func readyPack(_ c: Content, language: String) -> OrderSnapshot {
            let base = OrderSnapshot.mockDelivered
            return OrderSnapshot(
                orderId: base.orderId,
                status: base.status,
                productId: base.productId,
                targetCount: 30,
                language: language,
                category: c.packRowLabel,
                theme: nil,
                createdAt: base.createdAt,
                deliveredAt: base.deliveredAt,
                packId: base.packId,
                llmCostUsd: nil,
                searchCostCents: 0,
                job: base.job,
                actualCount: 30,
                packGenerationStatus: "complete"
            )
        }
    }

#endif
