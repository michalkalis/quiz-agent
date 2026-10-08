//
//  VoiceDiagnosticsSettingsModel.swift
//  Hangs
//
//  State and actions behind the TestFlight/debug "voice diagnostics" group in
//  Settings (#184, #185 track C): mirrors of the UserDefaults-backed
//  `VoicePipelineFlags` (so the rows re-render on toggle), the live audio route
//  line and the saved answer recordings. Moved out of SettingsView in #194 A1.
//

import Combine
import Foundation

@MainActor
final class VoiceDiagnosticsSettingsModel: ObservableObject {
    @Published private(set) var voiceProcessingEnabled = VoicePipelineFlags.voiceProcessingEnabled
    @Published private(set) var voiceProcessingOnExternalOutput = VoicePipelineFlags.voiceProcessingOnExternalOutput
    @Published private(set) var conditionAnswerUpload = VoicePipelineFlags.conditionAnswerUpload
    @Published private(set) var realtimeSTTEnabled = VoicePipelineFlags.realtimeSTTEnabled
    @Published private(set) var saveAnswerRecordings = VoicePipelineFlags.saveAnswerRecordings
    /// Output · input · session mode · the voice-processing mode a mic engine
    /// would get now (#185 track C).
    @Published private(set) var audioRouteSummary: String
    @Published private(set) var savedRecordingCount: Int

    private let routeSummary: @MainActor () -> String
    private let recordingsDirectory: URL?
    private let presentShareSheet: @MainActor ([Any]) -> Void

    init(
        routeSummary: @escaping @MainActor () -> String = VoiceProcessingPolicy.routeSummary,
        recordingsDirectory: URL? = AnswerRecordingStore.directory(),
        presentShareSheet: @escaping @MainActor ([Any]) -> Void = ShareSheetPresenter.present
    ) {
        self.routeSummary = routeSummary
        self.recordingsDirectory = recordingsDirectory
        self.presentShareSheet = presentShareSheet
        audioRouteSummary = routeSummary()
        savedRecordingCount = AnswerRecordingStore.recordingCount(directory: recordingsDirectory)
    }

    func setVoiceProcessingEnabled(_ isOn: Bool) {
        voiceProcessingEnabled = isOn
        VoicePipelineFlags.voiceProcessingEnabled = isOn
        refreshRoute()
    }

    func setVoiceProcessingOnExternalOutput(_ isOn: Bool) {
        voiceProcessingOnExternalOutput = isOn
        VoicePipelineFlags.voiceProcessingOnExternalOutput = isOn
        refreshRoute()
    }

    func setConditionAnswerUpload(_ isOn: Bool) {
        conditionAnswerUpload = isOn
        VoicePipelineFlags.conditionAnswerUpload = isOn
    }

    func setRealtimeSTTEnabled(_ isOn: Bool) {
        realtimeSTTEnabled = isOn
        VoicePipelineFlags.realtimeSTTEnabled = isOn
    }

    func setSaveAnswerRecordings(_ isOn: Bool) {
        saveAnswerRecordings = isOn
        VoicePipelineFlags.saveAnswerRecordings = isOn
    }

    func refresh() {
        savedRecordingCount = AnswerRecordingStore.recordingCount(directory: recordingsDirectory)
        refreshRoute()
    }

    func refreshRoute() {
        audioRouteSummary = routeSummary()
    }

    /// Share sheet over every saved WAV + sidecar; nothing to share, nothing shown.
    func exportRecordings() {
        let files = AnswerRecordingStore.files(directory: recordingsDirectory)
        guard !files.isEmpty else { return }
        presentShareSheet(files)
    }

    func deleteRecordings() {
        AnswerRecordingStore.deleteAll(directory: recordingsDirectory)
        savedRecordingCount = AnswerRecordingStore.recordingCount(directory: recordingsDirectory)
    }
}
