//
//  QuizViewModel+CategoryDeck.swift
//  Hangs
//
//  #224.6 — Home category deck stepping; the rule lives in `CategoryCycle`.
//

import Foundation

extension QuizViewModel {
    /// Home deck tap (right half = next, left = previous) or VoiceOver
    /// increment / decrement.
    func stepCategory(_ direction: CategoryCycle.Direction) {
        settings.categories = CategoryCycle.stepped(from: settings.categories, direction)
    }
}
