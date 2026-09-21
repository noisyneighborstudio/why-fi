import XCTest
@testable import NetmonCore

final class NetmonCoreTests: XCTestCase {
    func testLogScaleUsesTenMillisecondFloorAndThreeSecondCeiling() {
        XCTAssertEqual(RTTScale.normalized(milliseconds: 10), 0, accuracy: 0.000_001)
        XCTAssertEqual(RTTScale.normalized(milliseconds: 3_000), 1, accuracy: 0.000_001)
        XCTAssertEqual(RTTScale.normalized(milliseconds: 1), 0, accuracy: 0.000_001)
        XCTAssertEqual(RTTScale.normalized(milliseconds: 30_000), 1, accuracy: 0.000_001)
        XCTAssertEqual(RTTScale.barHeight(milliseconds: 10, maxHeight: 40), 0)
        XCTAssertEqual(RTTScale.barHeight(milliseconds: 3_000, maxHeight: 40), 40)
        XCTAssertLessThan(RTTScale.barHeight(milliseconds: 200, maxHeight: 40), RTTScale.barHeight(milliseconds: 800, maxHeight: 40))
    }

    func testLateArrivalIsNotLoss() {
        XCTAssertEqual(ProbeMeasurement.classify(transport: .icmp, milliseconds: 199.9).sample.outcome, .ok)
        XCTAssertEqual(ProbeMeasurement.classify(transport: .icmp, milliseconds: 200).sample.outcome, .late)
        XCTAssertEqual(ProbeMeasurement.classify(transport: .tcp, milliseconds: 1_450.787).sample.outcome, .late)
        XCTAssertEqual(ProbeMeasurement.classify(transport: .icmp, milliseconds: nil).sample.outcome, .lost)
        XCTAssertEqual(WindowStats(samples: [.late(1_450.787)]).lossPercent, 0)
    }

    func testContiguousLossRunsMergeAndScatteredLossDoesNot() {
        let samples: [NetworkSample] = [
            .ok(40),
            .lost,
            .lost,
            .late(400),
            .lost,
            .ok(42),
            .lost,
            .lost,
            .lost
        ]

        XCTAssertEqual(
            LossRuns.contiguous(in: samples),
            [LossRun(start: 1, end: 3), LossRun(start: 4, end: 5), LossRun(start: 6, end: 9)]
        )
        let stats = WindowStats(samples: samples)
        XCTAssertEqual(stats.longestLossRun, 3)
        XCTAssertEqual(stats.activeLossRun, 3)
        XCTAssertEqual(stats.lossCount, 6)
    }

    func testRingBufferKeepsOldestToNewestOrder() {
        var buffer = SampleRingBuffer(capacity: 3)
        buffer.append(.ok(10))
        buffer.append(.ok(20))
        buffer.append(.ok(30))
        buffer.append(.ok(40))
        XCTAssertEqual(buffer.samples, [.ok(20), .ok(30), .ok(40)])
    }

    func testToneTurnsRedOnlyForAnActiveThreeSecondLossRun() {
        let samples: [NetworkSample] = [.ok(35), .lost, .lost, .lost]
        let state = MonitorState(mode: .dead, stats: WindowStats(samples: samples))
        XCTAssertEqual(state.tone, .red)

        let shortRun = MonitorState(mode: .gatewayOnly, stats: WindowStats(samples: [.lost, .lost]))
        XCTAssertEqual(shortRun.tone, .amber)
    }
}
