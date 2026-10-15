//
//  DailyChallengeFixtures.swift
//  Hangs
//
//  #205: realistic Slovak data for the daily challenge on the `--ui-test`
//  mock graph, and the launch flags that land on each state for screenshots:
//
//    --ui-test-daily-home          Home card, not played (the full click-through
//                                  Home → 5 questions → round end starts here)
//    --ui-test-daily-home-played   Home card, played 4/5
//    --ui-test-daily-result-rare   result, correct, "Vedel 1 z 3."
//    --ui-test-daily-result-hard   result, wrong, "Nikto iný to nevedel."
//    --ui-test-daily-result-easy   result, wrong, no strip
//    --ui-test-daily-result-first  result, correct, "Dnes si prvý."
//    --ui-test-daily-end-good      round end 4/5, rarest hit
//    --ui-test-daily-end-weak      round end 1/5, "Ťažká výzva."
//
//  Any of them also turns the server switch on (`AppConfigStore.debugSeed`).
//

#if DEBUG

    import Foundation

    enum DailyChallengeFixtures {
        struct ScriptedQuestion {
            let question: Question
            let answer: String
            /// Whether the scripted player knows it (a skip never does).
            let knows: Bool
            let crowdIfKnown: CrowdStrip?
            let crowdIfMissed: CrowdStrip?
        }

        static let flagPrefix = "--ui-test-daily"

        static func isActive(_ arguments: [String] = CommandLine.arguments) -> Bool {
            arguments.contains { $0.hasPrefix(flagPrefix) }
        }

        static let goodMarks: [Bool?] = [true, true, false, true, true]
        static let weakMarks: [Bool?] = [false, false, true, false, false]

        nonisolated static let rare = CrowdStrip(kind: .rare, text: "Vedel 1 z 3.", others: 3, knew: 1)
        nonisolated static let plain = CrowdStrip(kind: .plain, text: "Vedeli 2 z 3.", others: 3, knew: 2)
        nonisolated static let hard = CrowdStrip(kind: .hard, text: "Nikto iný to nevedel.", others: 2, knew: 0)
        nonisolated static let first = CrowdStrip(kind: .first, text: "Dnes si prvý.", others: 0, knew: 0)

        static let questions: [ScriptedQuestion] = [
            ScriptedQuestion(
                question: question("daily_q1", "Ktorá krajina má na vlajke cédrový strom?", category: "geography-world",
                                   explanation: "Libanonský céder je symbolom krajiny už od staroveku."),
                answer: "Libanon", knows: true, crowdIfKnown: rare, crowdIfMissed: nil
            ),
            ScriptedQuestion(
                question: question("daily_q2", "Koľko strún má klasická gitara?", category: "movies-music",
                                   explanation: "Klasická gitara má šesť nylonových strún."),
                answer: "Šesť", knows: true, crowdIfKnown: plain, crowdIfMissed: nil
            ),
            ScriptedQuestion(
                question: question("daily_q3", "Ako sa volá najvyšší vrch Slovenska?", category: "geography-world",
                                   explanation: "Gerlachovský štít vo Vysokých Tatrách má 2 655 metrov."),
                answer: "Gerlachovský štít", knows: false, crowdIfKnown: nil, crowdIfMissed: hard
            ),
            ScriptedQuestion(
                question: question("daily_q4", "V ktorom roku pristál človek prvýkrát na Mesiaci?", category: "history",
                                   explanation: "Apollo 11 pristálo na Mesiaci 20. júla 1969."),
                answer: "1969", knows: true, crowdIfKnown: first, crowdIfMissed: first
            ),
            ScriptedQuestion(
                question: question("daily_q5", "Ktorý plyn tvorí väčšinu zemskej atmosféry?", category: "science-nature",
                                   explanation: "Dusík tvorí asi 78 percent vzduchu."),
                answer: "Dusík", knows: true, crowdIfKnown: plain, crowdIfMissed: nil
            ),
        ]

        /// A played challenge: 3 or more right reads as the good result,
        /// fewer as the weak one.
        static func playedState(date: String, language: String, marks: [Bool?]) -> DailyChallengeState {
            let score = marks.count { $0 == true }
            let good = score >= 3
            return DailyChallengeState(
                date: date,
                language: language,
                status: .played,
                total: questions.count,
                summary: DailySummary(
                    score: score,
                    total: questions.count,
                    marks: marks,
                    players: 4,
                    comparison: good ? "Lepšie skóre ako 2 z 3 hráčov." : "Ťažká výzva.",
                    rank: good ? "Lepšie skóre ako 2 z 3 hráčov." : nil,
                    bestHit: good
                        ? DailyBestHit(questionId: "daily_q1", question: questions[0].question.question,
                                       answer: questions[0].answer, rare: true, text: "Vedel to len 1 z 3.")
                        : DailyBestHit(questionId: "daily_q3", question: questions[2].question.question,
                                       answer: questions[2].answer, rare: false, text: "Vedeli 2 z 3.")
                )
            )
        }

        // MARK: - Launch flags

        /// The mock network's side of the flags.
        static func configure(_ network: MockNetworkService, arguments: [String] = CommandLine.arguments) {
            guard isActive(arguments) else { return }
            let played: [Bool?]? = if arguments.contains("--ui-test-daily-end-weak") {
                weakMarks
            } else if arguments.contains("--ui-test-daily-home-played") || arguments.contains("--ui-test-daily-end-good") {
                goodMarks
            } else {
                nil
            }
            network.dailyScript = DailyMockScript(playedMarks: played)
        }

        /// The view model's side: land directly on a result or a round end.
        static func seed(_ viewModel: QuizViewModel, arguments: [String] = CommandLine.arguments) {
            guard isActive(arguments) else { return }
            viewModel.settings.language = "sk"
            let day = DailyChallengeDay(.now)
            let date = day.isoDate
            if arguments.contains("--ui-test-daily-end-good") || arguments.contains("--ui-test-daily-end-weak") {
                let marks = arguments.contains("--ui-test-daily-end-weak") ? weakMarks : goodMarks
                viewModel.activeDaily = DailyRound(day: day, language: "sk", state: playedState(date: date, language: "sk", marks: marks))
                viewModel.currentSession = QuizSession.preview(score: 0, answered: 5, maxQuestions: 5, phase: "finished")
                viewModel.quizState = .finished
                return
            }
            let results: [(flag: String, index: Int, said: String?, crowd: CrowdStrip?)] = [
                ("--ui-test-daily-result-rare", 0, nil, rare),
                ("--ui-test-daily-result-hard", 2, "Kriváň", hard),
                ("--ui-test-daily-result-easy", 1, "Päť", nil),
                ("--ui-test-daily-result-first", 3, nil, first),
            ]
            guard let pick = results.first(where: { arguments.contains($0.flag) }) else { return }
            let scripted = questions[pick.index]
            var round = DailyRound(day: day, language: "sk")
            if let crowd = pick.crowd { round.crowds[scripted.question.id] = crowd }
            viewModel.activeDaily = round
            viewModel.currentQuestion = scripted.question
            viewModel.currentSession = QuizSession.preview(
                score: Double(pick.index), answered: pick.index + 1, correct: pick.index,
                maxQuestions: 5, askedCount: pick.index + 1
            )
            viewModel.quizState = .showingResult(
                question: scripted.question,
                evaluation: Evaluation(
                    userAnswer: pick.said ?? scripted.answer,
                    result: pick.said == nil ? .correct : .incorrect,
                    points: pick.said == nil ? 1 : 0,
                    correctAnswer: scripted.answer,
                    questionId: scripted.question.id,
                    explanation: scripted.question.explanation
                )
            )
            viewModel.autoAdvanceCountdown = 5
            viewModel.settings.autoAdvanceDelay = 8
        }

        private static func question(_ id: String, _ text: String, category: String, explanation: String) -> Question {
            Question(
                id: id,
                question: text,
                type: .text,
                possibleAnswers: nil,
                difficulty: "medium",
                topic: "Denná výzva",
                category: category,
                sourceUrl: "https://sk.wikipedia.org",
                sourceExcerpt: nil,
                mediaUrl: nil,
                imageSubtype: nil,
                explanation: explanation,
                generatedBy: nil
            )
        }
    }

#endif
