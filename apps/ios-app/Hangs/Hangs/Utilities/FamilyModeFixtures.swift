//
//  FamilyModeFixtures.swift
//  Hangs
//
//  #236: the topics a server with family mode on would list, and a scripted
//  round, for previews, tests and the UI-test app
//  (`--app-config-family` turns the switch on; `--ui-test-family-repeats`
//  makes the round's start say it replays played questions).
//

#if DEBUG
    import Foundation

    enum FamilyModeFixtures {
        /// Slovak names from the server catalog (`app/family/topics.py`), in
        /// its order; two to four topics per band like the first pilot.
        static let topics = FamilyTopicsResponse(bands: [
            .init(band: FamilyBand.kids4to6.rawValue, topics: [
                FamilyTopic(key: "family-dinosaurs", name: "Dinosaury", roundSize: 6),
                FamilyTopic(key: "family-gross-but-true", name: "Fuj, ale pravda", roundSize: 6),
                FamilyTopic(key: "family-your-body", name: "Tvoje telo", roundSize: 6),
            ]),
            .init(band: FamilyBand.kids7to9.rawValue, topics: [
                FamilyTopic(key: "family-lego", name: "LEGO", roundSize: 10),
                FamilyTopic(key: "family-minecraft", name: "Minecraft", roundSize: 10),
                FamilyTopic(key: "family-how-things-are-made", name: "Ako sa čo vyrába", roundSize: 10),
                FamilyTopic(key: "family-animal-superpowers", name: "Superschopnosti zvierat", roundSize: 10),
            ]),
            .init(band: FamilyBand.kids10to12.rawValue, topics: [
                FamilyTopic(key: "family-harry-potter", name: "Harry Potter", roundSize: 10),
                FamilyTopic(key: "family-spies-and-codes", name: "Špióni a šifry", roundSize: 10),
            ]),
        ])

        /// A 4–6 round: each question a choice of two, Slovak like the topics.
        private static let choiceScript: [(text: String, options: [String], why: String)] = [
            ("Robí tvoj nos sople, aj keď nie si chorý?", ["Áno", "Nie"],
             "Nos robí sople stále. Chytajú prach, aby sa nedostal do pľúc."),
            ("Čo mal tyranosaurus kratšie?", ["Predné nohy", "Chvost"],
             "Jeho predné nohy boli také krátke, že nedočiahli ani k ústam."),
            ("Kto má viac kostí?", ["Bábätko", "Dospelý"],
             "Bábätko má asi 300 kostí. Ako rastie, niektoré zrastú dokopy, dospelý ich má 206."),
        ]

        /// A 7–9 or 10–12 round: questions answered by voice.
        private static let openScript: [(text: String, answer: String, why: String)] = [
            ("Prvé hračky firmy LEGO ešte neboli z plastu. Z akého materiálu ich vyrábali?", "Z dreva",
             "Firma začínala v Dánsku s drevenými hračkami, napríklad s kačkou na kolesách."),
            ("Kocka LEGO vzniká z plastových zŕn. Čo s nimi stroj urobí, kým ich vtlačí do formy?", "Roztopí ich",
             "Zrná sa roztopia na hustú hmotu a tá sa vstrekne do formy, kde vychladne."),
            ("Názov LEGO vznikol z dvoch dánskych slov. Čo znamenajú?", "Hraj sa dobre",
             "Leg godt po dánsky znamená hraj sa dobre."),
        ]

        /// Question `number` (1-based) of a scripted round; the script repeats
        /// to fill a round of any size. Choice answers: the first option.
        static func roundQuestion(choice: Bool, number: Int) -> (question: Question, answer: String) {
            if choice {
                let entry = choiceScript[(number - 1) % choiceScript.count]
                let options = ["a": entry.options[0], "b": entry.options[1]]
                return (question(number, entry.text, type: .textMultichoice, options: options, why: entry.why), entry.options[0])
            }
            let entry = openScript[(number - 1) % openScript.count]
            return (question(number, entry.text, type: .text, options: nil, why: entry.why), entry.answer)
        }

        /// #242: what a server with the extra-categories switch on lists
        /// (`--app-config-extra-categories`); `--ui-test-extra-exhausted` makes
        /// the start answer 409 `extra_category_exhausted`.
        static let extraCategories = ExtraCategoriesResponse(categories: [
            ExtraCategory(key: "extra-wizard-school", name: "Čarodejnícka škola", until: "2026-12-06"),
            ExtraCategory(key: "extra-techno", name: "Techno a klubová scéna", until: nil),
        ])

        @MainActor
        static func configureExtraCategories(_ network: MockNetworkService, arguments: [String] = CommandLine.arguments) {
            guard arguments.contains("--app-config-extra-categories") else { return }
            network.stubbedExtraCategories = extraCategories
            if arguments.contains("--ui-test-extra-exhausted") { network.startQuizError = NetworkError.extraCategoryExhausted }
        }

        @MainActor
        static func configure(_ network: MockNetworkService, arguments: [String] = CommandLine.arguments) {
            guard arguments.contains("--app-config-family") else { return }
            network.stubbedFamilyTopics = topics
            network.familyScript = FamilyMockScript(repeats: arguments.contains("--ui-test-family-repeats"))
        }

        private static func question(
            _ number: Int, _ text: String, type: Question.QuestionType, options: [String: String]?, why: String
        ) -> Question {
            Question(
                id: "family_q_\(type == .text ? "open" : "choice")_\(number)",
                question: text,
                type: type,
                possibleAnswers: options,
                difficulty: "easy",
                topic: "Family",
                category: type == .text ? "family-lego" : "family-gross-but-true",
                sourceUrl: "https://sk.wikipedia.org/wiki/Family_\(number)",
                sourceExcerpt: nil,
                mediaUrl: nil,
                imageSubtype: nil,
                explanation: why,
                generatedBy: "fixture",
                optionLabels: options.map { _ in ["a": "1", "b": "2"] }
            )
        }
    }
#endif
