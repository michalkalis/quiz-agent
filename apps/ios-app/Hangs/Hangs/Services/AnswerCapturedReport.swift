//
//  AnswerCapturedReport.swift
//  Hangs
//
//  #204.9: the `answer_captured` analytics event, one per recorded answer.
//  The fields "answer recording stopped" sends to Sentry (which deletes them
//  after a while) plus the experiment arm of each tested switch, kept in our
//  own events table so the weekly evaluator can decide the A/B. Keys are the
//  204.9 contract and the backend allowlist (`taxonomy.py`); short scalars,
//  never a transcript.
//

import Foundation

nonisolated struct AnswerCapturedReport: Equatable, Sendable {
    var questionId: String?
    var isRetry: Bool
    var autoTest: Bool
    var flags: [VoiceExperimentFlag: VoiceFlagAssignment]
    var routeGroup: VoiceRouteGroup
    var outputRoute: String
    var inputRoute: String
    var stopReason: RecordingStopReason
    var detector: String
    var heardSpeech: Bool
    var speechMs: Int
    /// Stop time minus the end of the last speech; nil without speech.
    var endDelayMs: Int?
    var durationMs: Int
    var voiceProcessing: Bool
    var ecEnabled: Bool
    /// nil while the device's echo-cancelled input capability is unknown.
    var aecApplicable: Bool?
    var frontMicApplicable: Bool
    var micDataSource: String
    var micPolarPattern: String
    /// Transcripts the player already rejected on this question, whether or
    /// not #204.2 sends them with the upload.
    var rejectedCount: Int

    /// How long the recording ran on after the last word: the cost of a
    /// detector that waits too long.
    static func endDelayMs(durationMs: Int, lastSpeechEndMs: Int?) -> Int? {
        lastSpeechEndMs.map { max(0, durationMs - $0) }
    }

    var propertyPairs: [(String, AnalyticsValue?)] {
        var pairs: [(String, AnalyticsValue?)] = [
            ("question_id", questionId.map { .string($0) }),
            ("is_retry", .bool(isRetry)),
            ("auto_test", .bool(autoTest)),
            ("route_group", .string(routeGroup.rawValue)),
            ("output_route", .string(outputRoute)),
            ("input_route", .string(inputRoute)),
            ("stop_reason", .string(stopReason.rawValue)),
            ("detector", .string(detector)),
            ("heard_speech", .bool(heardSpeech)),
            ("speech_ms", .int(speechMs)),
            ("end_delay_ms", endDelayMs.map { .int($0) }),
            ("duration_ms", .int(durationMs)),
            ("voice_processing", .bool(voiceProcessing)),
            ("ec_enabled", .bool(ecEnabled)),
            ("aec_applicable", aecApplicable.map { .bool($0) }),
            ("front_mic_applicable", .bool(frontMicApplicable)),
            ("mic_data_source", .string(micDataSource)),
            ("mic_polar_pattern", .string(micPolarPattern)),
            ("rejected_count", .int(rejectedCount)),
        ]
        for flag in VoiceExperimentFlag.allCases {
            guard let value = flags[flag] else { continue }
            pairs.append((flag.rawValue, .bool(value.isOn)))
            pairs.append(("src_\(flag.rawValue)", .string(value.source.rawValue)))
            pairs.append(("exp_gen_\(flag.rawValue)", value.generation.map { .int($0) }))
        }
        return pairs
    }
}
