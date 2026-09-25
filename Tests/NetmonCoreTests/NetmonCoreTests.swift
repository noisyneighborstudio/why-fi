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

    func testStatusRenderIsGaplessAndDrawsLateBarsSolidAmber() throws {
        var samples = Array(repeating: NetworkSample.ok(40), count: 58)
        samples += [.late(1_500), .lost]
        let bitmap = try render(samples, state: MonitorState(mode: .fine, stats: WindowStats(samples: samples), pulseOn: true))
        XCTAssertEqual(bitmap.pixelsWide, 184)
        // Row 31 from the top is just above the 5.5pt baseline, inside every bar.
        // Pixel 4 was the gap between the first two bars; the skyline is now continuous.
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 4, y: 31)).alphaComponent, 0.5)
        // Slot 58 starts at 1pt + 58 * 1.5pt = 88pt (px 176): a late bar, fully opaque amber.
        let late = try XCTUnwrap(bitmap.colorAt(x: 176, y: 31)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(late.alphaComponent, 0.9)
        XCTAssertGreaterThan(late.redComponent, 0.7)
        XCTAssertLessThan(late.blueComponent, 0.3)
        // Slot 59 (px 179) is lost: a slab below the baseline, px 3..9 from the bottom.
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 179, y: 44 - 6)).alphaComponent, 0.5)
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

    func testOutageSlabIsRedWhenDeadAndAmberWhenOnlyTheGatewayAnswers() throws {
        let samples = Array(repeating: NetworkSample.ok(40), count: 55) + Array(repeating: NetworkSample.lost, count: 5)
        let dead = try render(samples, state: MonitorState.evaluate(samples: samples, gatewayReachable: false, pulseOn: true))
        let gateway = try render(samples, state: MonitorState.evaluate(samples: samples, gatewayReachable: true, pulseOn: true))
        let red = try XCTUnwrap(dead.colorAt(x: 179, y: 44 - 6)?.usingColorSpace(.sRGB))
        let amber = try XCTUnwrap(gateway.colorAt(x: 179, y: 44 - 6)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(red.greenComponent, 0.3)
        XCTAssertGreaterThan(amber.greenComponent, 0.35)
    }

    private func render(_ samples: [NetworkSample], state: MonitorState) throws -> NSBitmapImageRep {
        var image = NSImage()
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            image = StripRenderer.image(samples: samples, state: state)
        }
        return try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
    }
}
