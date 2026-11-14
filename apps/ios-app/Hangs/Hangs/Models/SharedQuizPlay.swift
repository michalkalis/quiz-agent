//
//  SharedQuizPlay.swift
//  Hangs
//
//  #232: the friend's round from a shared link, while it plays and on its
//  round end.
//

import Foundation

nonisolated struct SharedQuizPlay: Equatable, Sendable, Identifiable {
    let token: String
    var id: String { token }
    /// round | daily | pack, once the server has started it.
    var kind: String?
}
