//
//  QuizViewModel+ExtraCategories.swift
//  Hangs
//
//  #242 — the free rotating extra categories on Home and in the picker (plan
//  docs/issues/issue-242-extra-categories-rotation.md, step 242.5). Same shape
//  as family topics: the server's list is fetched when the switch or the quiz
//  language changes, and a failed or slow fetch leaves the seven permanent
//  categories. State lives on `QuizViewModel` (`extraCatalog`,
//  `extraCategoryNotice`).
//

import Foundation
import os

extension QuizViewModel {
    /// Home asks whenever the switch or the quiz language changes. Switch off:
    /// nothing is fetched and the list empties. A failed fetch keeps what was
    /// known, so the player never sees an error or a wait for it. Only a fetch
    /// that answered drops a saved extra the list no longer holds.
    func refreshExtraCategories(enabled: Bool, language: String) async {
        guard enabled else {
            extraCatalog = []
            return
        }
        do {
            let response = try await networkService.extraCategories(language: Language.selectable(language).id)
            extraCatalog = response.categories
            dropUnlistedExtras()
        } catch {
            Logger.network.info("extra categories fetch skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The selection goes back to what the list still offers; none left = "All categories".
    private func dropUnlistedExtras() {
        let listed = Set(extraCatalog.map(\.key))
        let kept = settings.categories.filter { !ExtraCategory.isExtra($0) || listed.contains($0) }
        if kept != settings.categories { settings.categories = kept }
    }

    /// A quiz started with an extra category selected: one event per key.
    func trackExtraCategoryStart() {
        for key in settings.categories where ExtraCategory.isExtra(key) {
            trackAnalytics(.extraCategoryQuizStarted(category: key))
        }
    }

    /// The start answered 400 `extra_category_invalid` or 409
    /// `extra_category_exhausted`. Home stays, says it plainly with one way
    /// back (OK), and never offers to reset history. A gone category also
    /// leaves the selection and the list.
    func extraCategoryUnavailable(_ error: NetworkError) {
        switch error {
        case .extraCategoryExhausted:
            extraCategoryNotice = ExtraCategoryNotice.exhausted
        case .extraCategoryInvalid:
            let gone = Set(settings.categories.filter(ExtraCategory.isExtra))
            settings.categories.removeAll { gone.contains($0) }
            extraCatalog.removeAll { gone.contains($0.key) }
            extraCategoryNotice = ExtraCategoryNotice.invalid
        default:
            return
        }
        currentSession = nil
        persistenceStore.clearSession()
        activeFamily = nil
        transition(to: .idle)
    }

    func dismissExtraCategoryNotice() {
        extraCategoryNotice = nil
    }
}
