//
//  FamilyModeFixtures.swift
//  Hangs
//
//  #236: the topics a server with family mode on would list, for previews,
//  snapshots and the UI-test app (`--app-config-family` turns the switch on).
//

#if DEBUG
    import Foundation

    enum FamilyModeFixtures {
        /// Slovak names from the server catalog (`app/family/topics.py`), in
        /// its order; two to four topics per band like the first pilot.
        static let topics = FamilyTopicsResponse(bands: [
            .init(band: FamilyBand.kids4to6.rawValue, topics: [
                FamilyTopic(key: "family-dinosaurs", name: "Dinosaury", roundSize: 6),
                FamilyTopic(key: "family-gross-but-true", name: "Fuj, ale pravda", roundSize: 6),
                FamilyTopic(key: "family-your-body", name: "Tvoje telo", roundSize: 6),
            ]),
            .init(band: FamilyBand.kids7to9.rawValue, topics: [
                FamilyTopic(key: "family-lego", name: "LEGO", roundSize: 10),
                FamilyTopic(key: "family-minecraft", name: "Minecraft", roundSize: 10),
                FamilyTopic(key: "family-how-things-are-made", name: "Ako sa čo vyrába", roundSize: 10),
                FamilyTopic(key: "family-animal-superpowers", name: "Superschopnosti zvierat", roundSize: 10),
            ]),
            .init(band: FamilyBand.kids10to12.rawValue, topics: [
                FamilyTopic(key: "family-harry-potter", name: "Harry Potter", roundSize: 10),
                FamilyTopic(key: "family-spies-and-codes", name: "Špióni a šifry", roundSize: 10),
            ]),
        ])

        @MainActor
        static func configure(_ network: MockNetworkService, arguments: [String] = CommandLine.arguments) {
            guard arguments.contains("--app-config-family") else { return }
            network.stubbedFamilyTopics = topics
        }
    }
#endif
