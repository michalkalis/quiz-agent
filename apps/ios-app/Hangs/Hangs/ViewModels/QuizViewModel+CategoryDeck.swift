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
    func stepCategory(_ direction: CategoryCycle.Direction, input: CategoryStepInput = .tap) {
        settings.categories = CategoryCycle.stepped(from: settings.categories, direction)
        analytics.track(.homeCategoryStepped(
            direction: direction,
            input: input,
            to: settings.categories.first ?? "all"
        ))
    }

    func categoryPickerOpened(from source: CategoryPickerSource) {
        analytics.track(.homeCategoryPickerOpened(source: source))
    }
}
