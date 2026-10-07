//
//  StoreScreenshotFixturesTests.swift
//  HangsTests
//
//  #190 — store listing readiness. Raw App Store screenshots are captured per
//  listing language, so the fixture content must follow the quiz language.
//

import Foundation
@testable import Hangs
import Testing

@Suite("Store screenshot fixtures")
struct StoreScreenshotFixturesTests {
    @Test(
        "Content follows the quiz language, so each store listing shows its own language",
        arguments: [
            ("en", "Which planet has the shortest day in the Solar System?", "Space for kids: planets, rockets and astronauts"),
            ("sk", "Ktorá planéta má najkratší deň v slnečnej sústave?", "Vesmír pre deti: planéty, rakety a astronauti"),
            ("cs", "Která planeta má nejkratší den ve Sluneční soustavě?", "Vesmír pro děti: planety, rakety a astronauti"),
        ]
    )
    func contentFollowsQuizLanguage(language: String, question: String, topic: String) {
        let content = StoreScreenshotFixtures.content(forQuizLanguage: language)
        #expect(content.openQuestion == question)
        #expect(content.packTopic == topic)

        let mcq = StoreScreenshotFixtures.mcqQuestion(content, language: language)
        #expect(mcq.possibleAnswers?[StoreScreenshotFixtures.mcqCorrectKey] == content.mcqOptions[2])
        #expect(mcq.category == "geography-world")
        #expect(StoreScreenshotFixtures.openQuestion(content, language: language).category == "science-nature")
    }

    @Test("sk and cs never fall back to English content")
    func localizedContentDiffersFromEnglish() {
        let en = StoreScreenshotFixtures.content(forQuizLanguage: "en")
        #expect(StoreScreenshotFixtures.content(forQuizLanguage: "sk") != en)
        #expect(StoreScreenshotFixtures.content(forQuizLanguage: "cs") != en)
    }
}
