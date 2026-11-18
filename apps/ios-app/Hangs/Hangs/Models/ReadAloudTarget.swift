//
//  ReadAloudTarget.swift
//  Hangs
//
//  #235 F3: which "hear it" button a failed read belongs to.
//

import Foundation

/// #235 F3: the "hear it" buttons whose read can fail: the result's
/// explanation, the recap's whole summary, one recap row.
enum ReadAloudTarget: Equatable {
    case explanation
    case recapSummary
    case recapEntry(Int)
}
