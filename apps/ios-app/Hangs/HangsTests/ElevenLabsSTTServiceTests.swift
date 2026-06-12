//
//  ElevenLabsSTTServiceTests.swift
//  HangsTests
//
//  Unit tests for ElevenLabsSTTService.handleMessage parser and
//  buildWebSocketURL construction. No network — connect() is never called.
//

import Foundation
import Testing
@testable import Hangs

// MARK: - Helpers

/// Sends `json` to the service, then sends a sentinel partial_transcript so the
/// collector can prove *only* the sentinel arrived (or the expected event arrived
/// before the sentinel).  Returns all events collected up to `limit`.
private func collectEvents(
    from service: ElevenLabsSTTService,
    sending json: String,
    limit: Int
) async -> [STTEvent] {
    let sentinel = #"{"message_type":"partial_transcript","text":"__SENTINEL__"}"#

    let collector = Task { [events = service.events] () -> [STTEvent] in
        var collected: [STTEvent] = []
        for await event in events {
            collected.append(event)
            // Stop as soon as we hit the sentinel (or reach the requested limit).
            if case .partialTranscript(let t) = event, t == "__SENTINEL__" { break }
            if collected.count == limit { break }
        }
        return collected
    }

    await service.handleMessage(json)
    await service.handleMessage(sentinel)

    return await collector.value
}

/// Convenience: expects exactly one event before the sentinel.
private func firstEvent(
    from service: ElevenLabsSTTService,
    sending json: String
) async -> STTEvent? {
    let events = await collectEvents(from: service, sending: json, limit: 1)
    // Strip the sentinel itself — the last item is always the sentinel when limit==1
    // isn't reached early.  If only the sentinel arrived, events == [sentinel].
    guard let first = events.first else { return nil }
    if case .partialTranscript(let t) = first, t == "__SENTINEL__" { return nil }
    return first
}

// MARK: - ElevenLabsSTTServiceTests

@Suite("ElevenLabsSTTService — handleMessage parser")
struct ElevenLabsSTTServiceTests {

    // MARK: partial_transcript — non-empty text

    @Test("partial_transcript with text emits partialTranscript")
    func partialTranscriptNonEmpty() async {
        let service = ElevenLabsSTTService()
        let json = #"{"message_type":"partial_transcript","text":"Hello world"}"#
        let event = await firstEvent(from: service, sending: json)

        if case .partialTranscript(let text) = event {
            #expect(text == "Hello world")
        } else {
            Issue.record("Expected .partialTranscript, got \(String(describing: event))")
        }
    }

    // MARK: partial_transcript — empty text (filtered out)

    @Test("partial_transcript with empty text emits no event")
    func partialTranscriptEmpty() async {
        let service = ElevenLabsSTTService()
        let json = #"{"message_type":"partial_transcript","text":""}"#

        // Collect with limit=1; if no event before sentinel, firstEvent returns nil.
        let event = await firstEvent(from: service, sending: json)
        #expect(event == nil)
    }

    // MARK: committed_transcript — non-empty text

    @Test("committed_transcript with text emits committedTranscript")
    func committedTranscriptNonEmpty() async {
        let service = ElevenLabsSTTService()
        let json = #"{"message_type":"committed_transcript","text":"Final answer"}"#

        // committed_transcript yields an event; sentinel arrives after.
        let events = await collectEvents(from: service, sending: json, limit: 1)
        let payloadEvent = events.first(where: {
            if case .committedTranscript = $0 { return true }; return false
        })

        if case .committedTranscript(let text) = payloadEvent {
            #expect(text == "Final answer")
        } else {
            Issue.record("Expected .committedTranscript, got \(String(describing: payloadEvent))")
        }
    }

    // MARK: committed_transcript — empty text (dead-air commit MUST be emitted)

    /// 54.4 (founder #5): a forced commit after dead air returns empty text.
    /// The VM needs this event to escalate a transcription failure — swallowing
    /// it left the app stuck on the RECORDING screen forever.
    @Test("committed_transcript with empty text emits committedTranscript")
    func committedTranscriptEmpty() async {
        let service = ElevenLabsSTTService()
        let json = #"{"message_type":"committed_transcript","text":""}"#
        let event = await firstEvent(from: service, sending: json)
        guard case .committedTranscript(let text) = event else {
            Issue.record("Expected .committedTranscript(\"\"), got \(String(describing: event))")
            return
        }
        #expect(text.isEmpty)
    }

    // MARK: session_started — no event

    @Test("session_started emits no event")
    func sessionStartedEmitsNoEvent() async {
        let service = ElevenLabsSTTService()
        let json = #"{"message_type":"session_started"}"#
        let event = await firstEvent(from: service, sending: json)
        #expect(event == nil)
    }

    // MARK: error — with message field → .disconnected(ElevenLabsSTTError.serverError)

    @Test("error message_type emits disconnected with serverError")
    func errorWithMessageEmitsDisconnected() async {
        let service = ElevenLabsSTTService()
        let json = #"{"message_type":"error","message":"rate limit exceeded"}"#
        let event = await firstEvent(from: service, sending: json)

        guard let event else {
            Issue.record("Expected .disconnected, got nil")
            return
        }
        guard case .disconnected(let error) = event else {
            Issue.record("Expected .disconnected, got \(event)")
            return
        }
        guard let sttError = error as? ElevenLabsSTTError,
              case .serverError(let msg) = sttError else {
            Issue.record("Expected ElevenLabsSTTError.serverError, got \(String(describing: error))")
            return
        }
        #expect(msg == "rate limit exceeded")
    }

    // MARK: error — without message field → "Unknown error"

    @Test("error without message uses 'Unknown error'")
    func errorWithoutMessageUsesUnknown() async {
        let service = ElevenLabsSTTService()
        let json = #"{"message_type":"error"}"#
        let event = await firstEvent(from: service, sending: json)

        guard let event,
              case .disconnected(let error) = event,
              let sttError = error as? ElevenLabsSTTError,
              case .serverError(let msg) = sttError else {
            Issue.record("Expected .disconnected(ElevenLabsSTTError.serverError(\"Unknown error\"))")
            return
        }
        #expect(msg == "Unknown error")
    }

    // MARK: unknown message_type — no event, no crash

    @Test("unknown message_type emits no event and does not crash")
    func unknownMessageTypeIsIgnored() async {
        let service = ElevenLabsSTTService()
        let json = #"{"message_type":"future_event","data":"irrelevant"}"#
        let event = await firstEvent(from: service, sending: json)
        #expect(event == nil)
    }

    // MARK: malformed JSON — no event, no crash

    @Test("malformed JSON emits no event and does not crash")
    func malformedJSONIsIgnored() async {
        let service = ElevenLabsSTTService()
        let event = await firstEvent(from: service, sending: "not json at all {{{")
        #expect(event == nil)
    }

    // MARK: missing message_type — no event, no crash

    @Test("JSON without message_type emits no event and does not crash")
    func missingMessageTypeIsIgnored() async {
        let service = ElevenLabsSTTService()
        let json = #"{"text":"Hello","confidence":0.99}"#
        let event = await firstEvent(from: service, sending: json)
        #expect(event == nil)
    }
}

// MARK: - ElevenLabsSTTURLTests

@Suite("ElevenLabsSTTService — buildWebSocketURL")
struct ElevenLabsSTTURLTests {

    private func queryDict(for url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
                guard let value = item.value else { return nil }
                return (item.name, value)
            }
        )
    }

    @Test("URL scheme is wss")
    func urlSchemeIsWSS() throws {
        let url = try ElevenLabsSTTService.buildWebSocketURL(token: "tok", languageCode: "sk")
        #expect(url.scheme == "wss")
    }

    @Test("URL host is api.elevenlabs.io")
    func urlHostIsElevenLabs() throws {
        let url = try ElevenLabsSTTService.buildWebSocketURL(token: "tok", languageCode: "sk")
        #expect(url.host == "api.elevenlabs.io")
    }

    @Test("URL path is /v1/speech-to-text/realtime")
    func urlPathIsCorrect() throws {
        let url = try ElevenLabsSTTService.buildWebSocketURL(token: "tok", languageCode: "sk")
        #expect(url.path == "/v1/speech-to-text/realtime")
    }

    @Test("Query contains expected params for sk language")
    func queryParamsSkLanguage() throws {
        let url = try ElevenLabsSTTService.buildWebSocketURL(token: "my-token", languageCode: "sk")
        let dict = queryDict(for: url)

        #expect(dict["token"] == "my-token")
        #expect(dict["model_id"] == Config.elevenLabsModel)          // "scribe_v2_realtime"
        #expect(dict["audio_format"] == Config.elevenLabsAudioFormat) // "pcm_16000"
        #expect(dict["commit_strategy"] == "vad")
        #expect(dict["vad_silence_threshold_secs"] == String(Config.elevenLabsVadSilenceThresholdSecs)) // "1.5"
        #expect(dict["language_code"] == "sk")
    }

    @Test("Query contains expected params for en language")
    func queryParamsEnLanguage() throws {
        let url = try ElevenLabsSTTService.buildWebSocketURL(token: "other-token", languageCode: "en")
        let dict = queryDict(for: url)

        #expect(dict["token"] == "other-token")
        #expect(dict["language_code"] == "en")
    }

    @Test("vad_silence_threshold_secs matches Config value as String")
    func vadSilenceThresholdMatchesConfig() throws {
        let url = try ElevenLabsSTTService.buildWebSocketURL(token: "t", languageCode: "en")
        let dict = queryDict(for: url)
        // Assert as String to avoid Double formatting flakiness
        let expected = String(Config.elevenLabsVadSilenceThresholdSecs)
        #expect(dict["vad_silence_threshold_secs"] == expected)
    }
}
