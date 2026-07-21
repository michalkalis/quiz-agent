//
//  NavigationModelTests.swift
//  HangsTests
//
//  Issue #111 (navigation as owned state). Pins the bypass-proof property:
//  a quiz start from ANY entry point — voice "start" over a pushed stack
//  (`CmdListener:169`), error-retry (`ContentView:298`), or a button — is
//  structurally unable to leave a pushed Settings/OrderPack/MyPacks screen
//  covering the fresh QuestionView, because teardown is driven off
//  `quizState` ENTERING `.startingQuiz`, not off any per-call-site broadcast.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing

@MainActor
@Suite("NavigationModel — reactive teardown on quiz start (#111)")
struct NavigationModelTests {
    // WHY: this is the actual shipping bug (CmdListener:169) — voice "start"
    // never fired the old quiz-start teardown broadcast, so a pushed stack
    // stayed mounted over the fresh quiz. Driving teardown off the
    // `.startingQuiz` state entry (which every start path produces) closes
    // the bypass structurally instead of per-call-site.
    @Test("entering .startingQuiz empties the path")
    func startingQuizEmptiesPath() {
        let nav = NavigationModel()
        nav.path.append(AppRoute.settings)
        nav.path.append(AppRoute.orderPack)

        nav.handleQuizStateChange(.startingQuiz)

        #expect(nav.path.isEmpty)
    }

    // WHY: pins the #110 error→startingQuiz retry entry — error-retry
    // (ContentView:298) shares the exact same bypass as voice "start". The
    // predicate must be "enters .startingQuiz", not "leaves .idle", or this
    // second entry point would silently stop clearing once #110 legalizes it.
    @Test("error does not clear, but the following startingQuiz does")
    func startingQuizFromErrorEmptiesPath() {
        let nav = NavigationModel()
        nav.path.append(AppRoute.settings)

        nav.handleQuizStateChange(.error(message: "boom", context: .general))
        #expect(!nav.path.isEmpty, ".error must not clear the stack on its own")

        nav.handleQuizStateChange(.startingQuiz)
        #expect(nav.path.isEmpty)
    }

    // WHY: guards against an over-eager predicate (e.g. "leaves .idle") that
    // would clear on every state change and mask real navigation bugs during
    // the quiz flow itself.
    @Test("a non-start state does not clear the path")
    func nonStartStateDoesNotClear() {
        let nav = NavigationModel()
        nav.path.append(AppRoute.settings)

        nav.handleQuizStateChange(.askingQuestion)

        #expect(!nav.path.isEmpty)
    }

    // WHY: the belt-and-braces isPresented reset (gate note 2) — SwiftUI's
    // transitive dismiss of a `navigationDestination(isPresented:)` child
    // when the parent path clears is community-documented as unreliable, so
    // OrderProgress's presentation is driven off this flag directly and must
    // reset in the SAME step as the path, proven here off-sim.
    @Test("entering .startingQuiz resets orderProgressPresented too")
    func startingQuizResetsOrderProgressPresented() {
        let nav = NavigationModel()
        nav.path.append(AppRoute.settings)
        nav.path.append(AppRoute.orderPack)
        nav.orderProgressPresented = true

        nav.handleQuizStateChange(.startingQuiz)

        #expect(nav.path.isEmpty)
        #expect(nav.orderProgressPresented == false)
    }

    // WHY: `orderProgressPresented` lives on the app-lifetime NavigationModel,
    // not per-mount view @State — if a multi-level pop (back-button long-press
    // menu) removes OrderPack without SwiftUI writing the isPresented binding
    // back, a stale `true` would auto-push a ghost OrderProgress on the next
    // Create-pack visit. The model itself must drop the flag the moment
    // `.orderPack` leaves the path, and keep it while OrderPack stays mounted.
    @Test("popping OrderPack out of the path resets orderProgressPresented")
    func poppingOrderPackResetsOrderProgressPresented() {
        let nav = NavigationModel()
        nav.path = [.settings, .orderPack]
        nav.orderProgressPresented = true

        nav.path = [.settings, .orderPack]
        #expect(nav.orderProgressPresented, "flag must survive while OrderPack stays mounted")

        nav.path = [.settings]
        #expect(nav.orderProgressPresented == false)
        #expect(nav.path == [.settings], "the pop itself must not be disturbed")
    }
}
