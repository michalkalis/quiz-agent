//
//  QuestionAvailabilityTests.swift
//  HangsTests
//
//  #193 — an old build must survive a limiter value the server adds later.
//

import Foundation
import Testing
@testable import Hangs

@Suite("QuestionAvailability decoding (#193)")
struct QuestionAvailabilityTests {
    private func decode(_ limitedBy: String) throws -> QuestionAvailability {
        let json = """
        {"available": 3, "requested": 10, "sufficient": false, "limited_by": "\(limitedBy)"}
        """
        return try JSONDecoder().decode(QuestionAvailability.self, from: Data(json.utf8))
    }

    @Test("An unknown limiter decodes as .unknown instead of failing the whole response")
    func unknownLimiterDegrades() throws {
        let availability = try decode("rate_limit")
        #expect(availability.limitedBy == .unknown)
        #expect(availability.available == 3)
        #expect(availability.sufficient == false)
    }

    @Test("Known limiters still decode to their own cases")
    func knownLimitersDecode() throws {
        #expect(try decode("corpus").limitedBy == .corpus)
        #expect(try decode("quota").limitedBy == .quota)
    }
}
