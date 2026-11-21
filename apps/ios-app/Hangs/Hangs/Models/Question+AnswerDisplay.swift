//
//  Question+AnswerDisplay.swift
//  Hangs
//
//  #132 (founder, 2026-07-29): on MCQ the evaluation used to carry the bare
//  option KEY ("b"), which read as a one-letter answer. Display pairs letter
//  and text — "B — Pyramid" — resolving from `possibleAnswers` in BOTH
//  directions, because the backend now serves the translated option text
//  while older sessions still send the key:
//    1. the value IS a key → take that key's text;
//    2. the value IS an option's text → take that option's letter.
//  Anything that matches neither (open answers, a question with no options)
//  renders unchanged. Extracted from ResultView for #132 Track E — the recap
//  entries freeze the same composition at capture time.
//
//  #185 track G: the label is the server's `optionLabels` ("2 — Pyramid", or
//  "B — 1969" when the options are numbers), the same one the option grid
//  shows and the question audio reads.
//

import Foundation

extension Question {
    /// The label shown for option `key`: the server's (#185 track G), else the
    /// legacy letter — a question decoded without labels is also read out with
    /// letters, so screen and voice still agree.
    func optionLabel(for key: String) -> String {
        optionLabels?[key] ?? key.uppercased()
    }

    /// Whether the options are labelled with letters (A–D) rather than numbers —
    /// what the driver is told to say when an answer named no option.
    var usesLetterLabels: Bool {
        guard let optionLabels, !optionLabels.isEmpty else { return true }
        return optionLabels.values.contains { !$0.allSatisfy(\.isNumber) }
    }

    func labelledAnswer(_ raw: String) -> String {
        guard let key = optionKey(matching: raw), let text = possibleAnswers?[key] else { return raw }
        return "\(optionLabel(for: key)) — \(text)"
    }

    /// The option an answer names, by key or by option text (the two shapes
    /// above); nil for an open answer or one that names no option.
    func optionKey(matching raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let options = possibleAnswers else { return nil }

        if let text = options[value.lowercased()],
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return value.lowercased()
        }
        return options.first(where: { $0.value.caseInsensitiveCompare(value) == .orderedSame })?.key
    }
}
