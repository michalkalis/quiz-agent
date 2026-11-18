//
//  QuizViewModel+Family.swift
//  Hangs
//
//  #236 — family mode „S deťmi“ on Home (plan docs/issues/issue-236-family-mode-build.md,
//  increment A1). The switch "Kvíz | S deťmi" turns Home into the family
//  version: the deck shows the band's topics, Vek replaces Náročnosť, and
//  Start plays one topic. The round itself runs on today's quiz screens; the
//  server picks it whole at `/start`. State lives on `QuizViewModel`
//  (`familySettings`, `familyCatalog`, `hiddenFamilyTopics`, `activeFamily`).
//

import Foundation
import os

extension QuizViewModel {
    // MARK: - What Home shows

    /// The bands with at least one topic to play, in catalog order.
    var familyBands: [FamilyBand] {
        FamilyBand.allCases.filter { !familyTopics(for: $0).isEmpty }
    }

    /// The band's topics the server listed, minus the ones that came back empty.
    func familyTopics(for band: FamilyBand) -> [FamilyTopic] {
        (familyCatalog[band] ?? []).filter { !hiddenFamilyTopics.contains(Self.hiddenKey(band, $0.key)) }
    }

    /// The switch shows only while the server lists topics for the quiz
    /// language: off for this build, hidden storefront, or no content = no switch.
    var isFamilyModeAvailable: Bool { !familyBands.isEmpty }

    /// Home is in the family version. A saved "on" waits for the switch: with
    /// the server off it stays saved and Home looks exactly as without the mode.
    var isFamilyModeOn: Bool {
        isFamilyModeAvailable && familySettings.isOn && familySettings.band != nil
    }

    /// The selected band's topics (empty when that band has none now).
    var familyBandTopics: [FamilyTopic] {
        familySettings.band.map { familyTopics(for: $0) } ?? []
    }

    /// The topic Start plays: the band's last pick while it is listed, else its first.
    var familyTopic: FamilyTopic? {
        let topics = familyBandTopics
        guard let band = familySettings.band else { return nil }
        let saved = familySettings.topicByBand[band.rawValue]
        return topics.first { $0.key == saved } ?? topics.first
    }

    /// What "Štart s deťmi" asks the server for; nil = nothing to play.
    var familyRound: FamilyRound? {
        guard isFamilyModeOn, let band = familySettings.band, let topic = familyTopic else { return nil }
        return FamilyRound(band: band, topic: topic.key, roundSize: topic.roundSize)
    }

    /// The session in play is a family round (also after a restore: the
    /// server echoes the band on the session).
    var isFamilySession: Bool { currentSession?.ageBand != nil }

    // MARK: - Server topics

    /// Home asks whenever the switch or the quiz language changes. With the
    /// switch off nothing is fetched and the catalog empties, which hides the
    /// mode; the saved settings stay. A failed fetch keeps what was known.
    func refreshFamilyTopics(enabled: Bool, language: String) async {
        guard enabled else {
            familyCatalog = [:]
            return
        }
        do {
            let response = try await networkService.familyTopics(language: Language.selectable(language).id)
            familyCatalog = response.topicsByBand
        } catch {
            Logger.network.info("family topics fetch skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Parent actions

    /// The switch at the top of Home. The first flip to the mode asks for the
    /// age first (canvas F1); the mode turns on once a band is picked.
    func setFamilyMode(_ on: Bool) {
        guard on != isFamilyModeOn else { return }
        if on, familySettings.band == nil {
            showingFamilyBandSheet = true
            return
        }
        familySettings.isOn = on
        trackAnalytics(.familyModeChanged(enabled: on))
    }

    /// A band from the first-flip sheet or from the Vek menu.
    func selectFamilyBand(_ band: FamilyBand) {
        let firstTime = familySettings.band == nil
        let turnsOn = !familySettings.isOn || firstTime
        showingFamilyBandSheet = false
        familySettings.band = band
        familySettings.isOn = true
        trackAnalytics(.familyBandSelected(band: band, firstTime: firstTime))
        if turnsOn { trackAnalytics(.familyModeChanged(enabled: true)) }
    }

    /// The age sheet closed without a pick: Home stays on Kvíz.
    func dismissFamilyBandSheet() {
        showingFamilyBandSheet = false
    }

    /// A tap on the deck's halves (or VoiceOver adjust): the band's next or
    /// previous topic, one topic per round.
    func stepFamilyTopic(_ direction: CategoryCycle.Direction) {
        let topics = familyBandTopics
        guard !topics.isEmpty, let current = familyTopic,
              let index = topics.firstIndex(of: current) else { return }
        let delta = direction == .next ? 1 : -1
        selectFamilyTopic(topics[(index + delta + topics.count) % topics.count].key)
    }

    /// A topic from the deck or the Téma menu; remembered for its band.
    func selectFamilyTopic(_ key: String) {
        guard let band = familySettings.band, key != familyTopic?.key else { return }
        familySettings.topicByBand[band.rawValue] = key
        trackAnalytics(.familyTopicSelected(band: band, topic: key))
    }

    /// "Štart s deťmi". No availability check: the server picks the whole
    /// round and repeats played questions rather than end early.
    @discardableResult
    func beginFamilyStart() -> Task<Void, Never>? {
        guard let familyRound else { return nil }
        return beginQuizStart(family: familyRound)
    }

    // MARK: - Start outcome

    /// `/start` answered 409 `family_topic_empty`: the topic thinned out after
    /// the list was cached. It hides until the next launch and the deck moves
    /// to the next topic; the list is not fetched again (its cache would bring
    /// the topic straight back and the parent into a loop).
    func familyTopicWasEmpty(_ round: FamilyRound) {
        Logger.quiz.info("👪 Family topic \(round.topic, privacy: .public) is empty in this language, hiding it")
        hiddenFamilyTopics.insert(Self.hiddenKey(round.band, round.topic))
        trackAnalytics(.familyTopicEmpty(band: round.band, topic: round.topic))
        currentSession = nil
        persistenceStore.clearSession()
        activeFamily = nil
        transition(to: .idle)
    }

    /// One key may sit in several bands, each with its own questions.
    static func hiddenKey(_ band: FamilyBand, _ topic: String) -> String {
        "\(band.rawValue)/\(topic)"
    }
}
