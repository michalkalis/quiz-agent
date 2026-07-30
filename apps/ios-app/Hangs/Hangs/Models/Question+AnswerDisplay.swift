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

import Foundation

extension Question {
    func labelledAnswer(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let options = possibleAnswers else { return raw }

        if let text = options[value.lowercased()],
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "\(value.uppercased()) — \(text)"
        }
        if let match = options.first(where: { $0.value.caseInsensitiveCompare(value) == .orderedSame }) {
            return "\(match.key.uppercased()) — \(match.value)"
        }
        return raw
    }
}
