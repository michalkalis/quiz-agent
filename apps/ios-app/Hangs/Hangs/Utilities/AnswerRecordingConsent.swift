//
//  AnswerRecordingConsent.swift
//  Hangs
//
//  #197 (founder 2026-10-10): every beta tester is asked ONCE, on Home before
//  their first quiz, whether their answer recordings may go to the developer
//  to improve speech recognition. Yes turns on the "Save answer recordings"
//  switch, No leaves it off; either way the question never comes back and the
//  switch in Settings stays the place to change it. App Store builds never
//  ask: the channel gate is the same receipt check as every other
//  TestFlight-only surface (`BuildChannel`).
//

import Foundation

nonisolated enum AnswerRecordingConsent {
    static let askedKey = "voicePipeline.answerRecordingConsentAsked"

    /// Ask only in a TestFlight/debug build, only once, and not when the
    /// switch is already on (the founder turned it on by hand before this
    /// question existed).
    static func shouldAsk(channelAllows: Bool = BuildChannel.debugSurfacesEnabled()) -> Bool {
        guard channelAllows else { return false }
        let defaults = UserDefaults.standard
        return !defaults.bool(forKey: askedKey)
            && !VoicePipelineFlags.saveAnswerRecordings(channelAllows: true)
    }

    static func record(consented: Bool) {
        UserDefaults.standard.set(true, forKey: askedKey)
        VoicePipelineFlags.saveAnswerRecordings = consented
    }
}
