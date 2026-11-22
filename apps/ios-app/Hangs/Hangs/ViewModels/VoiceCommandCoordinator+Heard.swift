//
//  VoiceCommandCoordinator+Heard.swift
//  Hangs
//
//  "What the app hears" (founder 2026-11-22): the live preview's lifecycle.
//  Words in progress that resemble a command show it, a fire fills it and
//  clears it after a short hold, and an utterance that ends without firing
//  (or a listener that goes away) clears it. The fire itself never waits on
//  any of this.
//

import Clocks
import Foundation

extension VoiceCommandCoordinator {
    /// A partial transcript arrived on `screen`: show the command it
    /// resembles, or nothing when it resembles none.
    func noteCommandHeard(_ text: String, on screen: VoiceCommandScreen) {
        // One command per utterance: after a fire the words no longer matter.
        guard !commandFiredThisUtterance else { return }
        guard CommandHeard.screens.contains(screen) else { return clearUnfiredCommandHeard() }
        // Over the read only repeat / next route, so only they may show.
        let commands = VoiceCommandLexicon.commands(on: screen).filter {
            !listensThroughQuestionRead || Self.readingCommands.contains($0)
        }
        let heard = VoiceCommandMatcher.resemblance(
            transcript: text, on: screen, among: commands, language: commandLanguage
        ).flatMap { CommandHeard.inProgress($0.command, score: $0.score) }
        guard let heard else { return clearUnfiredCommandHeard() }
        if commandHeard != heard { commandHeard = heard }
    }

    /// A command fired on `screen`: full, then cleared after a short hold.
    func showCommandFired(_ command: VoiceCommand, on screen: VoiceCommandScreen) {
        guard CommandHeard.screens.contains(screen) else { return }
        commandHeard = .fired(command)
        let clock = clock
        let task = Task { [weak self] in
            try? await clock.sleep(for: CommandHeard.firedHold)
            guard let self, !Task.isCancelled else { return }
            self.commandHeard = nil
        }
        taskBag.add(task, key: .commandHeardClear)
    }

    /// The utterance ended without firing, or the listener went away. A fired
    /// preview is left to its own hold.
    func clearUnfiredCommandHeard() {
        if commandHeard?.hasFired == false { commandHeard = nil }
    }
}
