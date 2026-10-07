//
//  QuizToolbarInspection.swift
//  HangsTests
//
//  #173: the quiz chrome became a native `.toolbar`, and ViewInspector cannot
//  walk INTO one on this SwiftUI version — `toolbar().item(0)` hands back the
//  whole `TupleToolbarContent` instead of the item (its "content|value|.N" path
//  is one level short of the iOS 26 layout). So the chrome is asserted in two
//  halves, and both halves are real:
//
//   - the SCREEN owns a toolbar at all, in every mode and state → this helper;
//   - what is IN it → the control components (`QuizMuteToolbarButton`,
//     `QuizPauseToolbarButton`, `QuizOverflowMenu`) are plain Views precisely so
//     they can be hosted and asserted directly.
//
//  Deliberately no "hasControl(…)" convenience: it would have to lie (return
//  false for a control that is present), and a silently-passing negative
//  assertion is worse than no assertion.
//

@testable import Hangs
import SwiftUI
import ViewInspector

@MainActor
enum QuizToolbarInspection {
    /// The quiz screen's toolbar. `zStack()` is QuestionView's body root, which
    /// is where the `.toolbar` modifier is attached.
    static func toolbar(of view: QuestionView) throws -> InspectableView<ViewType.Toolbar> {
        try view.inspect().zStack().toolbar()
    }

    static func hasToolbar(_ view: QuestionView) -> Bool {
        (try? toolbar(of: view)) != nil
    }

    /// #188 G9: the result screen wears the same toolbar, also on its ZStack root.
    static func toolbar(of view: ResultView) throws -> InspectableView<ViewType.Toolbar> {
        try view.inspect().zStack().toolbar()
    }

    static func hasToolbar(_ view: ResultView) -> Bool {
        (try? toolbar(of: view)) != nil
    }

    static func bodyOccurrences(of identifier: String, in view: ResultView) throws -> Int {
        let matches: (InspectableView<ViewType.ClassifiedView>) -> Bool = {
            (try? $0.accessibilityIdentifier()) == identifier
        }
        let everywhere = try view.inspect().findAll(where: matches).count
        let inToolbar = try toolbar(of: view).findAll(where: matches).count
        return everywhere - inToolbar
    }

    /// How often `identifier` is drawn in the screen body, i.e. outside the
    /// toolbar. Since ViewInspector 0.10.4 a tree-wide `find` also walks into the
    /// toolbar items, so "not in the body" has to subtract the toolbar's share.
    static func bodyOccurrences(of identifier: String, in view: QuestionView) throws -> Int {
        let matches: (InspectableView<ViewType.ClassifiedView>) -> Bool = {
            (try? $0.accessibilityIdentifier()) == identifier
        }
        let everywhere = try view.inspect().findAll(where: matches).count
        let inToolbar = try toolbar(of: view).findAll(where: matches).count
        return everywhere - inToolbar
    }
}
