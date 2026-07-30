//
//  QuizViewModel+Recap.swift
//  Hangs
//
//  #132 Track E — recap narration. The end-of-set recap is read aloud through
//  the backend's generic TTS (`POST /tts/synthesize`, already-translated text,
//  1000-char cap per call): score first, then every question's verdict +
//  revealed answer + explanation, chunked per question and played
//  sequentially. Auto-starts on recap appear when `autoRecordEnabled` — the
//  app has no single driving-mode flag; auto-record is its hands-free signal —
//  and never while muted (mute wins everywhere TTS starts, #85).
//

import Foundation
import os

extension QuizViewModel {
    /// Server cap on one `synthesizeSpeech` call (SynthesizeTTSRequest.text).
    static let recapTTSChunkLimit = 1000

    // MARK: - Playback

    /// Recap CTA action: play the whole summary, or stop it when running.
    func toggleRecapNarration() {
        if isNarratingRecap {
            stopRecapNarration()
        } else {
            playRecapSummary()
        }
    }

    /// Auto-read on recap appear — the mock's "pri šoférovaní sa súhrn vždy
    /// číta nahlas". Hands-free proxy: `autoRecordEnabled` (judgment call,
    /// logged in the issue). Muted or hands-on drivers read the list instead.
    func autoPlayRecapIfHandsFree() {
        guard settings.autoRecordEnabled, !settings.isMuted else { return }
        playRecapSummary()
    }

    func playRecapSummary() {
        guard !recapEntries.isEmpty, !isNarratingRecap, !settings.isMuted else { return }
        let chunks = recapNarrationChunks()
        isNarratingRecap = true
        taskBag.add(Task { [weak self] in
            await self?.narrate(chunks: chunks)
            self?.isNarratingRecap = false
        }, key: .recapNarration)
    }

    func stopRecapNarration() {
        taskBag.cancel(.recapNarration)
        isNarratingRecap = false
        Task { await audioDeviceState.stopAnyPlayingAudio() }
    }

    /// Row-level "hear it": speak one entry's explanation. Replaces any
    /// running summary narration (shared task key → previous task cancels).
    func playRecapEntryExplanation(_ entry: RecapEntry) {
        guard let explanation = entry.explanation, !settings.isMuted else { return }
        isNarratingRecap = false
        taskBag.add(Task { [weak self] in
            await self?.narrate(chunks: Self.splitForTTS(explanation))
        }, key: .recapNarration)
    }

    /// Sequential fetch-and-play. A failed chunk is logged and skipped — one
    /// transient TTS failure must not silence the rest of the summary.
    private func narrate(chunks: [String]) async {
        for chunk in chunks {
            guard !Task.isCancelled else { return }
            do {
                let audio = try await networkService.synthesizeSpeech(text: chunk)
                guard !Task.isCancelled else { return }
                _ = try await audioService.playOpusAudio(audio)
            } catch is CancellationError {
                return
            } catch {
                Logger.quiz.warning("⚠️ Recap narration chunk failed: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Composition

    /// The spoken summary, split to the server's per-call cap.
    func recapNarrationChunks() -> [String] {
        Self.narrationChunks(for: recapEntries)
    }

    /// Pure composition — internal static for tests: the narration content is
    /// asserted here, not against audio.
    static func narrationChunks(for recapEntries: [RecapEntry]) -> [String] {
        var pieces: [String] = []
        let correct = recapEntries.filter(\.isCorrect).count
        pieces.append(String(
            localized: "Set finished. You got \(correct) out of \(recapEntries.count) right.",
            comment: "Recap narration intro: correct count out of total"
        ))
        for entry in recapEntries {
            switch entry.result {
            case .correct:
                pieces.append(String(
                    localized: "Question \(entry.id) — correct. \(entry.correctAnswerDisplay).",
                    comment: "Recap narration line for a correct answer: number, then the answer"
                ))
            case .skipped:
                pieces.append(String(
                    localized: "Question \(entry.id) — skipped. The answer: \(entry.correctAnswerDisplay).",
                    comment: "Recap narration line for a skipped question: number, then the revealed answer"
                ))
            default:
                pieces.append(String(
                    localized: "Question \(entry.id) — missed. The answer: \(entry.correctAnswerDisplay).",
                    comment: "Recap narration line for a wrong answer: number, then the revealed answer"
                ))
            }
            if let explanation = entry.explanation {
                pieces.append(explanation)
            }
        }
        return pieces.flatMap { Self.splitForTTS($0) }
    }

    /// Split one narration piece to the TTS cap at sentence boundaries;
    /// a single over-long sentence is hard-cut (the server rejects > cap).
    static func splitForTTS(_ text: String, limit: Int = recapTTSChunkLimit) -> [String] {
        guard text.count > limit else { return [text] }
        var chunks: [String] = []
        var current = ""
        for sentence in text.components(separatedBy: ". ") where !sentence.isEmpty {
            if current.isEmpty {
                current = sentence
            } else if current.count + sentence.count + 2 <= limit {
                current += ". " + sentence
            } else {
                chunks.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.flatMap { chunk -> [String] in
            guard chunk.count > limit else { return [chunk] }
            var out: [String] = []
            var rest = Substring(chunk)
            while !rest.isEmpty {
                out.append(String(rest.prefix(limit)))
                rest = rest.dropFirst(limit)
            }
            return out
        }
    }
}
