//
//  ElevenLabsSTTService.swift
//  Hangs
//
//  Streaming speech-to-text via ElevenLabs Scribe v2 Realtime WebSocket.
//  Receives PCM audio chunks and returns partial/final transcripts.
//

@preconcurrency import Foundation
import os
import Sentry

/// Events emitted by the STT service
enum STTEvent: Sendable {
    /// Interim transcript (updates as user speaks)
    case partialTranscript(String)
    /// Final committed transcript (after VAD detects silence)
    case committedTranscript(String)
    /// WebSocket connection established
    case connected
    /// Connection closed or errored
    case disconnected(Error?)
}

/// Protocol for streaming speech-to-text
protocol ElevenLabsSTTServiceProtocol: Sendable {
    /// Connect to ElevenLabs WebSocket with a single-use token
    func connect(token: String, languageCode: String) async throws
    /// Send a PCM audio chunk (base64-encoded)
    func sendAudioChunk(_ pcmData: Data) async throws
    /// Signal end of audio stream
    func commitAndClose() async throws
    /// Disconnect and clean up
    func disconnect() async
    /// Stream of STT events
    var events: AsyncStream<STTEvent> { get }
}

/// Streaming STT service using ElevenLabs Scribe v2 Realtime WebSocket
actor ElevenLabsSTTService: ElevenLabsSTTServiceProtocol {

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<STTEvent>.Continuation?

    nonisolated let events: AsyncStream<STTEvent>

    init() {
        var continuation: AsyncStream<STTEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    // MARK: - Connection

    func connect(token: String, languageCode: String) async throws {
        // Build WebSocket URL with query parameters
        guard var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime") else {
            throw ElevenLabsSTTError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "model_id", value: Config.elevenLabsModel),
            URLQueryItem(name: "audio_format", value: Config.elevenLabsAudioFormat),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            URLQueryItem(name: "vad_silence_threshold_secs", value: String(Config.elevenLabsVadSilenceThresholdSecs)),
            URLQueryItem(name: "language_code", value: languageCode),
        ]

        guard let url = components.url else {
            throw ElevenLabsSTTError.invalidURL
        }

        Logger.stt.debug("🎙️ ElevenLabs STT: connecting to \(url.host ?? "unknown", privacy: .public)")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()

        self.webSocketTask = task

        // Start receiving messages
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        eventContinuation?.yield(.connected)

        Logger.stt.info("🎙️ ElevenLabs STT: connected")

        // Sentry: mark start of STT session (language code is metadata, not PII)
        let startCrumb = Breadcrumb(level: .info, category: "stt.start")
        startCrumb.message = "ElevenLabs STT connected"
        startCrumb.data = ["language": languageCode, "model": Config.elevenLabsModel]
        SentrySDK.addBreadcrumb(startCrumb)
    }

    // MARK: - Sending Audio

    func sendAudioChunk(_ pcmData: Data) async throws {
        guard let task = webSocketTask else {
            throw ElevenLabsSTTError.notConnected
        }

        let base64Audio = pcmData.base64EncodedString()

        let message: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": base64Audio,
            "commit": false,
            "sample_rate": 16000,
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: message)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw ElevenLabsSTTError.serverError("Failed to encode audio chunk")
        }
        try await task.send(.string(jsonString))
    }

    func commitAndClose() async throws {
        guard let task = webSocketTask else { return }

        // Send a commit message to force-finalize any pending transcript
        let message: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": "",
            "commit": true,
            "sample_rate": 16000,
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: message)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw ElevenLabsSTTError.serverError("Failed to encode commit message")
        }
        try await task.send(.string(jsonString))

        Logger.stt.debug("🎙️ ElevenLabs STT: sent commit, waiting for final transcript")
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil

        Logger.stt.info("🎙️ ElevenLabs STT: disconnected")
    }

    // MARK: - Receive Loop

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await task.receive()

                switch message {
                case .string(let text):
                    handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    Logger.stt.error("🎙️ ElevenLabs STT: receive error: \(error.localizedDescription, privacy: .public)")
                    eventContinuation?.yield(.disconnected(error))
                }
                return
            }
        }
    }

    private func handleMessage(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = json["message_type"] as? String else {
            return
        }

        switch messageType {
        case "partial_transcript":
            if let text = json["text"] as? String, !text.isEmpty {
                eventContinuation?.yield(.partialTranscript(text))

                Logger.stt.debug("🎙️ ElevenLabs STT partial: \(text, privacy: .public)")
            }

        case "committed_transcript":
            if let text = json["text"] as? String, !text.isEmpty {
                eventContinuation?.yield(.committedTranscript(text))

                Logger.stt.info("🎙️ ElevenLabs STT committed: \(text, privacy: .public)")

                // Sentry: metadata ONLY — never the transcript text itself.
                let confidence = (json["confidence"] as? Double) ?? 0
                let crumb = Breadcrumb(level: .info, category: "stt.result")
                crumb.message = "committed_transcript"
                crumb.data = ["length": text.count, "confidence": confidence]
                SentrySDK.addBreadcrumb(crumb)
            }

        case "session_started":
            Logger.stt.info("🎙️ ElevenLabs STT: session started")

        case "error":
            let errorMsg = json["message"] as? String ?? "Unknown error"
            Logger.stt.error("🎙️ ElevenLabs STT error: \(errorMsg, privacy: .public)")
            // Sentry: server-side STT error — treat as a "fallback" signal (caller may retry with Whisper).
            SentryLog.warn("STT fallback", category: .stt, attributes: [
                "reason": "server_error",
                "message": errorMsg
            ])
            eventContinuation?.yield(.disconnected(ElevenLabsSTTError.serverError(errorMsg)))

        default:
            Logger.stt.debug("🎙️ ElevenLabs STT: unknown message type: \(messageType, privacy: .public)")
        }
    }
}

// MARK: - Errors

enum ElevenLabsSTTError: LocalizedError {
    case invalidURL
    case notConnected
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid ElevenLabs WebSocket URL"
        case .notConnected:
            return "Not connected to ElevenLabs STT"
        case .serverError(let message):
            return "ElevenLabs STT error: \(message)"
        }
    }
}

// MARK: - Mock for Testing

#if DEBUG
actor MockElevenLabsSTTService: ElevenLabsSTTServiceProtocol {
    private var eventContinuation: AsyncStream<STTEvent>.Continuation?
    nonisolated let events: AsyncStream<STTEvent>

    var mockCommittedText = "Paris"
    var shouldFail = false

    init() {
        var continuation: AsyncStream<STTEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    func connect(token: String, languageCode: String) async throws {
        if shouldFail {
            throw ElevenLabsSTTError.notConnected
        }
        eventContinuation?.yield(.connected)
    }

    func sendAudioChunk(_ pcmData: Data) async throws {
        // Simulate partial transcript after a few chunks
        eventContinuation?.yield(.partialTranscript("Par..."))
    }

    func commitAndClose() async throws {
        eventContinuation?.yield(.committedTranscript(mockCommittedText))
    }

    func disconnect() async {}
}
#endif
