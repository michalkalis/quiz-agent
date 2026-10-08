//
//  VoiceDiagnosticsSettingsModelTests.swift
//  HangsTests
//
//  #194 A1: the Settings voice-diagnostics group's logic moved out of
//  SettingsView into VoiceDiagnosticsSettingsModel. The founder A/Bs the
//  answer pipeline in the car from these rows (#184, #185 track C), so a
//  switch that stops writing its flag, or a route line that stops refreshing,
//  silently voids the field test.
//

import Foundation
@testable import Hangs
import Testing

@Suite("Settings voice diagnostics logic (#194 A1)", .serialized)
@MainActor
struct VoiceDiagnosticsSettingsModelTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceDiagnosticsSettingsModelTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func saveRecording(in dir: URL, at seconds: TimeInterval) {
        let sidecar = AnswerRecordingStore.Sidecar(
            recordedAt: Date(timeIntervalSince1970: seconds),
            language: "sk", inputPort: "MicrophoneBuiltIn", voiceProcessing: true,
            sampleRate: 16000, durationMs: 1200, questionId: nil
        )
        AnswerRecordingStore.save(wav: Data(count: 44), sidecar: sidecar, enabled: true, directory: dir)
    }

    /// Restores a UserDefaults-backed flag so the global pipeline state other
    /// suites read is untouched.
    private func preservingFlag(_ key: String, _ body: () -> Void) {
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        body()
    }

    @Test("the voice-processing switches write their flag and refresh the route line")
    func voiceProcessingSwitchesWriteFlagAndRefreshRoute() {
        preservingFlag(VoicePipelineFlags.Key.voiceProcessing) {
            preservingFlag(VoicePipelineFlags.Key.voiceProcessingOnExternalOutput) {
                var refreshes = 0
                let model = VoiceDiagnosticsSettingsModel(
                    routeSummary: { refreshes += 1; return "route \(refreshes)" },
                    recordingsDirectory: tempDir(),
                    presentShareSheet: { _ in }
                )
                #expect(model.audioRouteSummary == "route 1")

                model.setVoiceProcessingEnabled(!model.voiceProcessingEnabled)
                #expect(VoicePipelineFlags.voiceProcessingEnabled == model.voiceProcessingEnabled)
                #expect(model.audioRouteSummary == "route 2", "the VP mode on the route line depends on this switch")

                model.setVoiceProcessingOnExternalOutput(true)
                #expect(VoicePipelineFlags.voiceProcessingOnExternalOutput)
                #expect(model.voiceProcessingOnExternalOutput)
                #expect(model.audioRouteSummary == "route 3")
            }
        }
    }

    @Test("the pipeline switches write their flags without touching the route line")
    func pipelineSwitchesWriteFlags() {
        preservingFlag(VoicePipelineFlags.Key.conditionAnswerUpload) {
            preservingFlag(VoicePipelineFlags.Key.realtimeSTT) {
                preservingFlag(VoicePipelineFlags.Key.saveAnswerRecordings) {
                    var refreshes = 0
                    let model = VoiceDiagnosticsSettingsModel(
                        routeSummary: { refreshes += 1; return "" },
                        recordingsDirectory: tempDir(),
                        presentShareSheet: { _ in }
                    )

                    model.setConditionAnswerUpload(true)
                    model.setRealtimeSTTEnabled(true)
                    model.setSaveAnswerRecordings(true)

                    #expect(VoicePipelineFlags.conditionAnswerUpload && model.conditionAnswerUpload)
                    #expect(VoicePipelineFlags.realtimeSTTEnabled && model.realtimeSTTEnabled)
                    #expect(VoicePipelineFlags.saveAnswerRecordings && model.saveAnswerRecordings)
                    #expect(refreshes == 1, "only the initial read")
                }
            }
        }
    }

    @Test("refresh picks up recordings saved while Settings was closed")
    func refreshRecountsRecordings() {
        let dir = tempDir()
        defer { AnswerRecordingStore.deleteAll(directory: dir) }
        let model = VoiceDiagnosticsSettingsModel(routeSummary: { "" }, recordingsDirectory: dir, presentShareSheet: { _ in })
        #expect(model.savedRecordingCount == 0)

        saveRecording(in: dir, at: 1_700_000_000)
        model.refresh()

        #expect(model.savedRecordingCount == 1)
    }

    @Test("export shares every WAV and sidecar; with none saved, nothing is shown")
    func exportSharesAllFiles() {
        let dir = tempDir()
        defer { AnswerRecordingStore.deleteAll(directory: dir) }
        var shared: [[Any]] = []
        let model = VoiceDiagnosticsSettingsModel(routeSummary: { "" }, recordingsDirectory: dir, presentShareSheet: { shared.append($0) })

        model.exportRecordings()
        #expect(shared.isEmpty)

        saveRecording(in: dir, at: 1_700_000_000)
        model.exportRecordings()

        let urls = shared.first?.compactMap { $0 as? URL } ?? []
        #expect(urls.map(\.pathExtension) == ["json", "wav"])
    }

    @Test("delete removes the recordings and zeroes the count")
    func deleteClearsRecordings() {
        let dir = tempDir()
        defer { AnswerRecordingStore.deleteAll(directory: dir) }
        saveRecording(in: dir, at: 1_700_000_000)
        saveRecording(in: dir, at: 1_700_000_100)
        let model = VoiceDiagnosticsSettingsModel(routeSummary: { "" }, recordingsDirectory: dir, presentShareSheet: { _ in })
        #expect(model.savedRecordingCount == 2)

        model.deleteRecordings()

        #expect(model.savedRecordingCount == 0)
        #expect(AnswerRecordingStore.files(directory: dir).isEmpty)
    }
}
