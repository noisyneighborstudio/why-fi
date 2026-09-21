import AppKit
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

    func testLateMeansTheReplyCameAfterTheNextProbeWentOut() {
        XCTAssertEqual(NetworkSample.classify(milliseconds: 250, interval: 1).outcome, .ok)
        XCTAssertEqual(NetworkSample.classify(milliseconds: 1_000, interval: 1).outcome, .ok)
        XCTAssertEqual(NetworkSample.classify(milliseconds: 1_450.787, interval: 1), .late(1_450.787))
        XCTAssertEqual(WindowStats(samples: [.late(1_450.787)]).lossPercent, 0)
    }

    func testLateReplyCorrectsItsSlotInPlace() {
        var buffer = SampleRingBuffer(capacity: 3)
        [.ok(40), .lost, .ok(42), .ok(41)].forEach { buffer.append($0) }
        buffer.replace(fromEnd: 1, with: .late(1_450))
        XCTAssertEqual(buffer.samples, [.lost, .late(1_450), .ok(41)])
        buffer.replace(fromEnd: 3, with: .ok(1))
        XCTAssertEqual(buffer.samples, [.lost, .late(1_450), .ok(41)])
    }

    func testSustainedLossIsDeadUnlessTheGatewayAnswers() {
        let samples: [NetworkSample] = [.ok(35), .lost, .lost, .lost, .lost, .lost]
        let dead = MonitorState.evaluate(samples: samples, gatewayReachable: false, pulseOn: false)
        XCTAssertEqual(dead.mode, .dead)
        XCTAssertEqual(dead.outageSeconds, 5)
        XCTAssertTrue(dead.showsOutageDuration)
        XCTAssertEqual(MonitorState.evaluate(samples: samples, gatewayReachable: true, pulseOn: false).mode, .gatewayOnly)
        XCTAssertEqual(MonitorState.evaluate(samples: [.ok(35), .lost, .lost], gatewayReachable: false, pulseOn: false).mode, .congested)
    }

    func testStatusRenderIsNotClippedAndDrawsTheHairline() throws {
        var samples = Array(repeating: NetworkSample.ok(40), count: 59)
        samples.append(.lost)
        let image = StripRenderer.image(samples: samples, state: MonitorState(mode: .fine, stats: WindowStats(samples: samples)))
        let bitmap = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        XCTAssertEqual(bitmap.pixelsWide, 184)
        // Last slot starts at 1pt + 59 * 1.5pt = 89.5pt (px 179); the loss rail spans px 3..9 from the bottom.
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 179, y: 44 - 6)).alphaComponent, 0.5)
        // 200ms hairline: one pixel tall at baseline 5.5pt + bar height for 200ms, above the 40ms bars.
        let hairlinePixels = Int((5.5 + CGFloat(RTTScale.barHeight(milliseconds: 200, maxHeight: 14))) * 2)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 20, y: 44 - hairlinePixels - 1)).alphaComponent, 0.1)
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
