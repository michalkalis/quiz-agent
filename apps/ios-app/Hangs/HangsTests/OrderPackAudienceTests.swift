//
//  OrderPackAudienceTests.swift
//  HangsTests
//
//  #236 (236.1): who a custom pack is written for.
//  WHY: a child band changes how the server writes and checks the pack, so the
//  band the parent picked must reach BOTH the pre-payment topic check and the
//  paid order; a wrong or lost band means a paid pack written for the wrong
//  age. Adults is the default and must leave today's adult order untouched,
//  and the choice must never hold the order back the way the required
//  difficulty does.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeViewModel(
    service: MockPackOrderService = MockPackOrderService()
) -> OrderPackViewModel {
    let vm = OrderPackViewModel(
        service: service,
        purchaseService: MockPackPurchaseService(),
        adminKeyAvailable: { true },
        orderLanguages: { Language.selectableLanguages(in: LanguageAvailability.fallbackPackOrderCodes) },
        clock: AnyClock(ImmediateClock())
    )
    vm.prompt = "Space"
    vm.selectDifficulty(.easy)
    return vm
}

@Suite("Order pack audience (#236)")
@MainActor
struct OrderPackAudienceTests {
    @Test("adults is preselected, never blocks Continue, and is what the order carries")
    func defaultIsAdults() async {
        let service = MockPackOrderService()
        let vm = makeViewModel(service: service)
        #expect(vm.audience == .adults)
        #expect(vm.isValid, "a topic and a difficulty are enough; the audience has a default")

        await vm.continueFromForm()
        #expect(vm.state == .confirming)
        await vm.submit()

        #expect(service.capturedTopicAudiences == [.adults])
        #expect(service.capturedIntents.first?.audience == .adults)
        #expect(PackAudience.adults.wireValue == nil, "adults sends no field: today's request")
    }

    @Test("a child band reaches the topic check and the order",
          arguments: [PackAudience.kids4to6, .kids7to9, .kids10to12])
    func childBandIsSent(_ band: PackAudience) async {
        let service = MockPackOrderService()
        let vm = makeViewModel(service: service)
        vm.selectAudience(band)

        await vm.continueFromForm()
        await vm.submit()

        #expect(service.capturedTopicAudiences == [band])
        #expect(service.capturedIntents.first?.audience == band)
    }

    // WHY: the child tier is stricter, so an "ok" for adults says nothing
    // about the same topic for a 4 year old; a cached verdict would let a
    // borderline topic through for a child pack.
    @Test("switching the band after a check asks again for the new band")
    func switchingBandRechecks() async {
        let service = MockPackOrderService()
        let vm = makeViewModel(service: service)
        await vm.continueFromForm()
        vm.backToEdit()

        vm.selectAudience(.kids4to6)
        await vm.continueFromForm()

        #expect(service.capturedTopicAudiences == [.adults, .kids4to6])
    }

    // WHY (PR #806 review): an adult-level verdict must never carry a child
    // order to the summary. If the band changes while the check is in flight,
    // the result belongs to the old band, so the new band is checked before
    // anything advances.
    @Test("a band switched during the check is checked itself before the summary")
    func bandSwitchedMidCheckIsRechecked() async {
        let clock = TestClock()
        let service = MockPackOrderService(clock: AnyClock(clock), topicDelaySeconds: 1)
        let vm = makeViewModel(service: service)

        let task = Task { await vm.continueFromForm() }
        await pumpUntil({ vm.isCheckingTopic && service.topicCheckCallCount == 1 }, "the adult check never started")
        vm.selectAudience(.kids4to6)

        await clock.advance(by: .seconds(1))
        await pumpUntil({ service.topicCheckCallCount == 2 }, "the child band was never checked")
        #expect(vm.state == .editing, "the adult verdict must not advance a child order")

        await clock.advance(by: .seconds(1))
        await task.value

        #expect(service.capturedTopicAudiences == [.adults, .kids4to6])
        #expect(vm.state == .confirming)
    }

    @Test("a blocked verdict belongs to its band: switching band clears the notice")
    func blockBelongsToBand() async {
        let vm = makeViewModel(service: MockPackOrderService(topicResult: .success(.blocked)))
        vm.selectAudience(.kids4to6)
        await vm.continueFromForm()
        #expect(vm.isTopicBlocked)

        vm.selectAudience(.kids10to12)
        #expect(!vm.isTopicBlocked, "the notice was for the other band")
    }
}

@Suite("Order snapshot audience (#236)")
struct OrderSnapshotAudienceTests {
    private func snapshot(audienceField: String) throws -> OrderSnapshot {
        let json = """
        {
          "order_id": "11111111-1111-1111-1111-111111111111",
          "status": "delivered",
          "product_id": "pack_30",
          "target_count": 30,
          "language": "sk",
          "category": null,
          "theme": null,
          "created_at": "2026-11-15T10:00:00Z",
          "delivered_at": null,
          "pack_id": null,
          "llm_cost_usd": null,
          "search_cost_cents": 0,
          "job": null\(audienceField)
        }
        """
        return try JSONDecoder().decode(OrderSnapshot.self, from: Data(json.utf8))
    }

    // WHY: older servers send no field and pre-choice orders send null; a newer
    // server may add a band. None of these may break the order list or poll.
    @Test("decodes with the field, without it, as null, and with an unknown band",
          arguments: [
              (#", "audience": "kids_7_9""#, "kids_7_9" as String?),
              ("", nil),
              (#", "audience": null"#, nil),
              (#", "audience": "kids_13_15""#, "kids_13_15"),
          ])
    func decodesAudience(field: String, expected: String?) throws {
        #expect(try snapshot(audienceField: field).audience == expected)
    }
}
