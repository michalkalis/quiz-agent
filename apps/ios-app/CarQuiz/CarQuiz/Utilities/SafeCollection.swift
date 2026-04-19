//
//  SafeCollection.swift
//  Hangs
//
//  Safe subscript that returns nil instead of crashing on out-of-bounds access.
//

import Foundation

extension Collection {
    /// Returns the element at the specified index if it is within bounds, otherwise nil.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
