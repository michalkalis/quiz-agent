//
//  QuizViewModel+PhoneLanguage.swift
//  Hangs
//
//  #231 — Ukrainian as a fourth language. A fresh install picks its quiz (and
//  interface) language from the phone at startup, before the server's language
//  list arrives, so a language switched on by the server (uk) fell back to
//  English for the whole first session. Once the list arrives, a player who
//  has not picked a language yet gets the phone's language again; a player who
//  picked one is never switched.
//

import Foundation

extension QuizViewModel {
    /// The player picks a quiz language (Home or Settings menu).
    func chooseLanguage(_ code: String) {
        persistenceStore.markLanguageChosen()
        settings.language = code
    }

    /// The server's language list arrived. Never mid-quiz: the screen would
    /// change language under a running set; the next launch catches up.
    func followPhoneLanguage(offered: [Language] = Language.selectableLanguages) {
        guard case .idle = quizState, let phoneLanguage = persistenceStore.unchosenPhoneLanguage else { return }
        settings.language = Language.selectable(phoneLanguage, in: offered).id
    }
}
