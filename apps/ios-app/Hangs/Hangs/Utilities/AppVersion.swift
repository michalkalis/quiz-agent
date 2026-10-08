//
//  AppVersion.swift
//  Hangs
//
//  Marketing-version comparison for the forced update (#193 task 193.9).
//

import Foundation

nonisolated enum AppVersion {
    /// `CFBundleShortVersionString` of the running build.
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// True when `version` is strictly below `minimum`, comparing dotted
    /// numbers component by component ("1.10" is newer than "1.9", "1.2"
    /// equals "1.2.0"). Anything that is not a dotted number on either side
    /// answers false: an unreadable version must never lock the app.
    static func isOlder(_ version: String, than minimum: String) -> Bool {
        guard let lhs = components(version), let rhs = components(minimum) else { return false }
        let length = max(lhs.count, rhs.count)
        let padded = { (parts: [Int]) in parts + Array(repeating: 0, count: length - parts.count) }
        return padded(lhs).lexicographicallyPrecedes(padded(rhs))
    }

    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil }
        return !parts.isEmpty && numbers.count == parts.count ? numbers : nil
    }
}
