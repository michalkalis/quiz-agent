//
//  PackPlay.swift
//  Hangs
//
//  #200: a custom pack the player starts, with what the phone knows of its
//  size, so a pack played through on this phone can ask before starting over.
//

import Foundation

struct PackPlay: Equatable, Sendable {
    let packId: String
    /// Questions the pack holds. Nil while it still grows (#182) or when the
    /// caller does not know: such a pack never counts as played through, and
    /// the server's empty answer is the only end.
    let questionCount: Int?
}
