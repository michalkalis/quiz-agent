//
//  PackProgress.swift
//  Hangs
//
//  #200: how much of a custom pack this phone has played ("10 / 30" on the
//  pack card and in My packs).
//

import Foundation

struct PackProgress: Equatable, Sendable {
    let played: Int
    let total: Int
}
