import Testing

@testable import PierKit

@Suite struct ConversationFollowSettlementTests {
    @Test func requiresTwoBottomReadingsAfterTheInitialCommand() {
        var settling = ConversationFollowSettlement()
        let initial = settling.advance(distanceFromBottom: 0, contentHeight: 1_000, canFollow: true)
        let first = settling.advance(distanceFromBottom: 0, contentHeight: 1_000, canFollow: true)
        let second = settling.advance(distanceFromBottom: 0, contentHeight: 1_000, canFollow: true)
        #expect(initial == .scroll)
        #expect(first == .wait)
        #expect(second == .stop)
    }

    @Test func correctsBothUndershootAndOvershoot() {
        var settling = ConversationFollowSettlement()
        let distances = [0.0, 5_000, -2_000, 3, 0]
        let actions = distances.map { settling.advance(distanceFromBottom: $0, contentHeight: 20_000, canFollow: true) }
        #expect(actions == [.scroll, .scroll, .scroll, .wait, .stop])
    }

    @Test func changingHeightOrLeavingBottomNeedsFreshConfirmation() {
        var settling = ConversationFollowSettlement()
        let samples: [(Double, Double)] = [(0, 100), (0, 100), (0, 400), (200, 600), (0, 600), (0, 600)]
        let actions = samples.map { settling.advance(distanceFromBottom: $0.0, contentHeight: $0.1, canFollow: true) }
        #expect(actions == [.scroll, .wait, .wait, .scroll, .wait, .stop])
    }

    @Test func stopsAtTheBudgetEvenWhenLayoutNeverConverges() {
        var settling = ConversationFollowSettlement()
        let actions = (0..<20).map { index in
            settling.advance(distanceFromBottom: index.isMultiple(of: 2) ? 10_000 : -10_000,
                             contentHeight: Double(20_000 + index * 1_000), canFollow: true)
        }
        #expect(actions.prefix(ConversationFollowSettlement.maximumChecks).allSatisfy { $0 == .scroll })
        #expect(actions.dropFirst(ConversationFollowSettlement.maximumChecks).allSatisfy { $0 == .stop })
    }

    @Test func invalidOrMissingGeometryCannotConfirmArrival() {
        var settling = ConversationFollowSettlement()
        let samples: [(Double?, Double?)] = [(nil, nil), (.nan, 100), (0, .infinity), (0, 0), (0, -10)]
        let actions = samples.map { settling.advance(distanceFromBottom: $0.0, contentHeight: $0.1, canFollow: true) }
        #expect(actions.allSatisfy { $0 == .scroll })
    }

    @Test func interruptedSequenceCannotRestartFromLaterGeometry() {
        var settling = ConversationFollowSettlement()
        let initial = settling.advance(distanceFromBottom: 2_000, contentHeight: 3_000, canFollow: true)
        let interrupted = settling.advance(distanceFromBottom: 2_000, contentHeight: 3_000, canFollow: false)
        let later = settling.advance(distanceFromBottom: 0, contentHeight: 3_000, canFollow: true)
        #expect(initial == .scroll)
        #expect(interrupted == .stop)
        #expect(later == .stop)
    }
}
