//
//  SnapshotHelpers.swift
//  HangsTests
//
//  Shared snapshotting strategy for tests that dump views backed by
//  ObservableObjects (QuizViewModel et al.).
//
//  Problem: Swift.dump() recurses into Combine @Published storage and emits
//  three categories of non-deterministic output that break snapshot comparisons:
//    1. Allocator-assigned memory addresses: "▿ lock: 0x000000010b025740"
//       and the adjacent "- pointerValue: 4416748752"
//    2. Wall-clock Date values captured by @State var now = Date() inside
//       views, rendered as ISO-8601 strings like "2026-05-15T15:09:19Z"
//    3. Combine's internal per-process Sink identity counter: dump() labels
//       each Subscribers.Sink wrapping an objectWillChange relay closure with
//       "Sink #<N>" (e.g. "- downstream: Sink #20"). With several independently
//       -initialized ObservableObject children (#113 decomposition), the order
//       in which those relay subscriptions register is not pinned across
//       process launches, so this label alone churns run-to-run even when the
//       object graph shape (types, property names/values, connection counts)
//       is byte-identical — verified by diffing two consecutive un-recorded
//       runs of the same code: only "Sink #<N>" differed, every other
//       instance-identity tag (e.g. "ObservableObjectPublisher #34",
//       "MockAudioService #5") stayed fixed.
//
//  .stableDump strips all three before comparison, making the baseline
//  deterministic across simulator processes and calendar time.
//

import Foundation
import SnapshotTesting

extension Snapshotting where Value: Any, Format == String {
    /// Like `.dump` but with two normalisation passes applied to the output
    /// before diffing: hex addresses are replaced with `0x<addr>` and
    /// ISO-8601 timestamps with `<date>`.
    static var stableDump: Snapshotting<Value, String> {
        SimplySnapshotting.lines.pullback { value -> String in
            var output = ""
            Swift.dump(value, to: &output)

            // 1. Combine lock hex addresses: 0x0000000107423cd0
            let noHex = output.replacingOccurrences(
                of: #"0x[0-9a-fA-F]+"#,
                with: "0x<addr>",
                options: .regularExpression
            )

            // 2. Adjacent raw pointer integers: "- pointerValue: 4416748752"
            let noPtr = noHex.replacingOccurrences(
                of: #"- pointerValue: \d+"#,
                with: "- pointerValue: <n>",
                options: .regularExpression
            )

            // 2b. Combine's per-process Sink identity counter (see file header,
            //     category 3): "downstream: Sink #20" -> "downstream: Sink #<n>".
            //     Scoped to "Sink #<N>" specifically (not a blanket "#<N>" strip)
            //     because every other dump() instance-identity tag was verified
            //     stable across runs and stays meaningful (e.g. a genuinely added
            //     or removed ObservableObjectPublisher relay still shows up).
            let noSinkId = noPtr.replacingOccurrences(
                of: #"Sink #\d+"#,
                with: "Sink #<n>",
                options: .regularExpression
            )

            // 3. ISO-8601 timestamps with T separator: "2026-05-15T15:09:19Z"
            let noDateISO = noSinkId.replacingOccurrences(
                of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})"#,
                with: "<date>",
                options: .regularExpression
            )

            // 4. Foundation.Date description format: "2026-05-15 15:12:13 +0000"
            let noDateFoundation = noDateISO.replacingOccurrences(
                of: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}"#,
                with: "<date>",
                options: .regularExpression
            )

            // 5. timeIntervalSinceReferenceDate floating-point value
            let noTI = noDateFoundation.replacingOccurrences(
                of: #"timeIntervalSinceReferenceDate: [-]?\d+\.\d+"#,
                with: "timeIntervalSinceReferenceDate: <n>",
                options: .regularExpression
            )

            // 6. Private-type metadata contexts carry an ASLR-dependent address:
            //    "(unknown context at $109915fa4)" — e.g. SilenceDetectionService's
            //    private State enum, dumped since #115 made the service non-optional.
            let noCtx = noTI.replacingOccurrences(
                of: #"\(unknown context at \$[0-9a-fA-F]+\)"#,
                with: "(unknown context at $<addr>)",
                options: .regularExpression
            )

            // 7. Truncate at the clockTimer section which dumps the live RunLoop
            //    (CFBasicHash / CFRunLoopSource entries with non-deterministic ordering
            //    and mach port numbers). Everything meaningful for structural assertions
            //    appears before this section.
            let lines = noCtx.components(separatedBy: "\n")
            let cutIndex = lines.firstIndex(where: { $0.contains("clockTimer") })
            let trimmed = cutIndex.map { lines[..<$0].joined(separator: "\n") } ?? noCtx

            return trimmed
        }
    }
}
