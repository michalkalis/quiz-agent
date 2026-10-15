//
//  DailyChallengeModelTests.swift
//  HangsTests
//
//  #205 — daily challenge: the wire shapes the app reads from the backend
//  (PR #442), the device-local date it sends, and the share text. Why these
//  matter: a decode that throws on a new or missing key would lose a whole
//  answer response (the crowd strip rides on every daily answer) or turn the
//  Home card on against a server whose endpoints answer 404; the share text
//  must never carry the answers (it would spoil the day for everyone else).
//

import Foundation
@testable import Hangs
import Testing

@Suite("Daily challenge wire models (#205)")
@MainActor
struct DailyChallengeDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }

    @Test("app-config: the switch reads true only when the server says so")
    func appConfigSwitch() throws {
        #expect(try decode(RemoteAppConfig.self, #"{"daily_challenge_enabled": true}"#).dailyChallengeEnabled)
        #expect(try !decode(RemoteAppConfig.self, "{}").dailyChallengeEnabled, "a server without the key must not show a card whose endpoints 404")
        let garbled = try decode(RemoteAppConfig.self, #"{"daily_challenge_enabled": "yes", "orders_enabled": false}"#)
        #expect(!garbled.dailyChallengeEnabled)
        #expect(!garbled.ordersEnabled, "an unreadable switch must not cost the rest of the config")
        #expect(!RemoteAppConfig.permissive.dailyChallengeEnabled, "before any fetch the card stays hidden")
    }

    @Test("a not-played state decodes without a summary")
    func notPlayedState() throws {
        let state = try decode(DailyChallengeState.self, #"{"date":"2026-10-15","language":"sk","status":"not_played","total":5}"#)
        #expect(state.status == .notPlayed)
        #expect(state.total == 5)
        #expect(state.summary == nil)
    }

    @Test("a played state keeps unanswered marks as nil and reads the best hit")
    func playedState() throws {
        let json = """
        {"date":"2026-10-15","language":"sk","status":"played","total":5,
         "summary":{"score":3,"total":5,"marks":[true,false,null,true,true],"players":4,
           "comparison":"Lepšie skóre ako 2 z 3 hráčov.","rank":"Lepšie skóre ako 2 z 3 hráčov.",
           "best_hit":{"question_id":"q1","question":"Ktorá krajina?","answer":"Libanon","rare":true,"text":"Vedel to len 1 z 3."}}}
        """
        let state = try decode(DailyChallengeState.self, json)
        let summary = try #require(state.summary)
        #expect(summary.marks == [true, false, nil, true, true])
        #expect(summary.comparison == "Lepšie skóre ako 2 z 3 hráčov.")
        #expect(summary.bestHit?.rare == true)
        #expect(summary.bestHit?.questionId == "q1")
    }

    @Test("a played state below the top half has no rank and may have no best hit")
    func weakPlayedState() throws {
        let json = """
        {"date":"2026-10-15","language":"sk","status":"played","total":5,
         "summary":{"score":0,"total":5,"marks":[false,false,false,false,false],"players":3,
           "comparison":"Ťažká výzva.","rank":null,"best_hit":null}}
        """
        let summary = try #require(try decode(DailyChallengeState.self, json).summary)
        #expect(summary.rank == nil)
        #expect(summary.bestHit == nil)
    }

    @Test("the start response: a session to play, or none when already played")
    func startResponse() throws {
        let session = """
        {"session_id":"s1","mode":"single","phase":"asking","max_questions":5,"current_difficulty":"random",
         "category":null,"language":"sk","participants":[],"expires_at":"2026-10-15T12:00:00Z","created_at":"2026-10-15T11:00:00Z"}
        """
        let withSession = try decode(DailyStartResult.self, #"{"state":{"date":"2026-10-15","language":"sk","status":"in_progress","total":5},"session":\#(session)}"#)
        #expect(withSession.session?.id == "s1")
        #expect(withSession.session?.maxQuestions == 5)
        let played = try decode(DailyStartResult.self, #"{"state":{"date":"2026-10-15","language":"sk","status":"played","total":5},"session":null}"#)
        #expect(played.session == nil)
        #expect(played.state.status == .played)
    }

    private func quizResponse(crowd: String?) -> String {
        let crowdField = crowd.map { #","crowd":\#($0)"# } ?? ""
        return """
        {"success":true,"message":"ok","session":{"session_id":"s1","mode":"single","phase":"asking","max_questions":5,
          "current_difficulty":"random","category":null,"language":"sk","participants":[],
          "expires_at":"2026-10-15T12:00:00Z","created_at":"2026-10-15T11:00:00Z"},
         "current_question":null,"evaluation":null,"feedback_received":[]\(crowdField)}
        """
    }

    @Test("an answer carries its crowd strip; a regular answer has none")
    func answerCrowdStrip() throws {
        let rare = try decode(QuizResponse.self, quizResponse(crowd: #"{"kind":"rare","text":"Vedel 1 z 3.","others":3,"knew":1}"#))
        #expect(rare.crowd == CrowdStrip(kind: .rare, text: "Vedel 1 z 3.", others: 3, knew: 1))
        let first = try decode(QuizResponse.self, quizResponse(crowd: #"{"kind":"first","text":"Dnes si prvý.","others":0,"knew":0}"#))
        #expect(first.crowd?.kind == .first)
        #expect(try decode(QuizResponse.self, quizResponse(crowd: nil)).crowd == nil)
    }

    @Test("an unknown strip kind drops the strip, never the answer")
    func unknownStripKind() throws {
        let response = try decode(QuizResponse.self, quizResponse(crowd: #"{"kind":"legendary","text":"?","others":1,"knew":1}"#))
        #expect(response.crowd == nil)
        #expect(response.session.id == "s1", "the graded answer must still land")
    }

    @Test("the meter: a share of the others, nothing to measure for the first player")
    func meterFraction() {
        #expect(CrowdStrip(kind: .rare, text: "", others: 4, knew: 1).knewFraction == 0.25)
        #expect(CrowdStrip(kind: .hard, text: "", others: 2, knew: 0).knewFraction == 0)
        #expect(CrowdStrip(kind: .first, text: "", others: 0, knew: 0).knewFraction == nil)
    }
}

@Suite("Daily challenge day (#205)")
struct DailyChallengeDayTests {
    @Test("the day is the device's local date, not UTC")
    func localDate() throws {
        // 2026-10-15 22:00 UTC is already the 16th in Bratislava (UTC+2).
        let instant = Date(timeIntervalSince1970: 1_792_101_600)
        var bratislava = Calendar(identifier: .gregorian)
        bratislava.timeZone = try #require(TimeZone(identifier: "Europe/Bratislava"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        #expect(DailyChallengeDay(instant, calendar: bratislava).isoDate == "2026-10-16")
        #expect(DailyChallengeDay(instant, calendar: utc).isoDate == "2026-10-15")
    }

    @Test("ISO round trip with zero padding")
    func isoRoundTrip() {
        let day = DailyChallengeDay(year: 2026, month: 3, day: 7)
        #expect(day.isoDate == "2026-03-07")
        #expect(DailyChallengeDay(isoDate: "2026-03-07") == day)
        #expect(DailyChallengeDay(isoDate: "today") == nil)
    }

    @Test("label: 15. 10. in Slovak and Czech, Oct 15 in English")
    func label() {
        let day = DailyChallengeDay(year: 2026, month: 10, day: 15)
        #expect(day.label(languageCode: "sk") == "15. 10.")
        #expect(day.label(languageCode: "cs") == "15. 10.")
        #expect(day.label(languageCode: "en") == "Oct 15")
    }
}

@Suite("Daily challenge share text (#205.6)")
@MainActor
struct DailyShareTextTests {
    private let day = DailyChallengeDay(year: 2026, month: 10, day: 15)

    @Test("Slovak, with the rank line of a top-half player")
    func slovakWithRank() {
        let text = DailyShareText.make(
            day: day, language: "sk", marks: [true, true, false, true, true], score: 4, total: 5,
            rank: "Lepšie skóre ako 2 z 3 hráčov."
        )
        #expect(text == "Trubbo · denná výzva 15. 10.\n✅✅❌✅✅ 4/5\nLepšie skóre ako 2 z 3 hráčov.\ntrubbo.app")
    }

    @Test("no rank below the top half: never a 'worse than' line")
    func noRankLine() {
        let text = DailyShareText.make(day: day, language: "cs", marks: [false, true, false, false, false], score: 1, total: 5, rank: nil)
        #expect(text == "Trubbo · denní výzva 15. 10.\n❌✅❌❌❌ 1/5\ntrubbo.app")
    }

    @Test("English header; an unanswered question is a blank tile")
    func englishAndUnanswered() {
        let text = DailyShareText.make(day: day, language: "en", marks: [true, nil], score: 1, total: 5, rank: nil)
        #expect(text == "Trubbo · daily challenge Oct 15\n✅⬜⬜⬜⬜ 1/5\ntrubbo.app")
    }

    @Test("the text never contains an answer")
    func noAnswers() {
        let state = DailyChallengeFixtures.playedState(date: "2026-10-15", language: "sk", marks: DailyChallengeFixtures.goodMarks)
        let content = DailyRoundEndContent(state: state, localMarks: [], round: DailyRound(day: day, language: "sk", state: state))
        for scripted in DailyChallengeFixtures.questions {
            #expect(!content.shareText.contains(scripted.answer), "the share text spoils '\(scripted.answer)'")
            #expect(!content.shareText.contains(scripted.question.question))
        }
    }
}
