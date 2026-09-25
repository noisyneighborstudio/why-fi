import AppKit
import XCTest
@testable import NetmonCore

final class NetmonCoreTests: XCTestCase {
    func testScalePinsTheLateThresholdToTheHairline() {
        XCTAssertEqual(RTTScale.barHeight(milliseconds: 1), 1)
        XCTAssertEqual(RTTScale.barHeight(milliseconds: Thresholds.lateMilliseconds), RTTScale.thresholdHeight)
        XCTAssertEqual(RTTScale.barHeight(milliseconds: 3_000), RTTScale.height)
        XCTAssertEqual(RTTScale.barHeight(milliseconds: 30_000), RTTScale.height)
        XCTAssertLessThan(RTTScale.barHeight(milliseconds: 200), RTTScale.barHeight(milliseconds: 800))
    }

    func testLateMeansTheReplyCameAfterTheNextProbeWentOut() {
        XCTAssertEqual(NetworkSample.classify(milliseconds: 250, interval: 1).outcome, .ok)
        XCTAssertEqual(NetworkSample.classify(milliseconds: 1_000, interval: 1).outcome, .ok)
        XCTAssertEqual(NetworkSample.classify(milliseconds: 1_450.787, interval: 1), .late(1_450.787))
        XCTAssertEqual(NetworkSample.classify(milliseconds: nil, interval: 1, gateway: 4), .lost(gateway: 4))
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
        let dead = MonitorState.evaluate(samples: samples, gatewayReachable: false)
        XCTAssertEqual(dead.mode, .dead)
        XCTAssertEqual(dead.outageSeconds, 5)
        XCTAssertEqual(MonitorState.evaluate(samples: samples, gatewayReachable: true).mode, .gatewayOnly)
        XCTAssertEqual(MonitorState.evaluate(samples: [.ok(35), .lost, .lost], gatewayReachable: false).mode, .congested)
    }

    func testSteadyHighLatencyIsCongestedEvenWithoutSpikesOrLoss() {
        let steady = Array(repeating: NetworkSample.ok(718), count: 60)
        XCTAssertEqual(MonitorState.evaluate(samples: steady, gatewayReachable: false).mode, .congested)
        let fast = Array(repeating: NetworkSample.ok(40), count: 60)
        XCTAssertEqual(MonitorState.evaluate(samples: fast, gatewayReachable: false).mode, .fine)
    }

    func testAutoExpandsForEveryStateButFine() {
        XCTAssertFalse(DisplayMode.auto.isExpanded(for: .fine))
        XCTAssertTrue(MonitorMode.allCases.filter { $0 != .fine }.allSatisfy { DisplayMode.auto.isExpanded(for: $0) })
        XCTAssertTrue(DisplayMode.expanded.isExpanded(for: .fine))
        XCTAssertFalse(MonitorMode.allCases.contains { DisplayMode.compact.isExpanded(for: $0) })
    }

    func testCompactFineShowsAGreenBadgeThroughAKnockout() throws {
        let samples = Array(repeating: NetworkSample.ok(18), count: 30)
        let bitmap = try render(samples, state: MonitorState.evaluate(samples: samples, gatewayReachable: false), expanded: false)
        XCTAssertEqual(bitmap.pixelsWide, 60)
        // Badge center: glyph origin (6, 4) + (15.6, 11.6) = (21.6, 15.6)pt.
        let badge = try color(bitmap, x: 21.6, y: 15.6)
        XCTAssertGreaterThan(badge.greenComponent, badge.redComponent + 0.3)
        // The ring between radius 1.95 and 3.45 is cleared, even where the outer arc would be.
        XCTAssertLessThan(try color(bitmap, x: 21.6 + 2.7, y: 15.6).alphaComponent, 0.1)
    }

    func testExpandedSparklineMarksLateBarsLossAndOutage() throws {
        var samples = Array(repeating: NetworkSample.ok(18), count: 24)
        samples += [.late(1_800), .lost, .ok(18), .lost, .lost, .lost]
        let bitmap = try render(samples, state: MonitorState.evaluate(samples: samples, gatewayReachable: false), expanded: true)
        func column(_ index: Int) -> CGFloat { 30 + CGFloat(index) * 3 + 1 }
        // Late: orange above the 8pt hairline (baseline 18pt, y-down).
        let late = try color(bitmap, x: column(24), y: 18 - 11)
        XCTAssertGreaterThan(late.redComponent, 0.8)
        XCTAssertLessThan(late.blueComponent, 0.2)
        // Isolated loss: a dot at the top of the column, nothing at the baseline.
        XCTAssertGreaterThan(try color(bitmap, x: column(25), y: 5).alphaComponent, 0.9)
        XCTAssertLessThan(try color(bitmap, x: column(25), y: 17).alphaComponent, 0.1)
        // Outage: red stubs at the baseline.
        let stub = try color(bitmap, x: column(29), y: 17)
        XCTAssertGreaterThan(stub.redComponent, 0.7)
        XCTAssertLessThan(stub.greenComponent, 0.2)
    }

    func testChartBucketsKeepTheWorstReplyAndFlagOutages() {
        let samples: [NetworkSample] = [.ok(40), .late(1_200), .ok(90), .lost, .lost, .lost]
        let buckets = ChartBucket.buckets(samples: samples, slots: 9, perBucket: 3)
        XCTAssertEqual(buckets.count, 3)
        XCTAssertNil(buckets[0])
        XCTAssertEqual(buckets[1], ChartBucket(worstMilliseconds: 1_200, hasLoss: false, hasOutage: false))
        XCTAssertEqual(buckets[2], ChartBucket(worstMilliseconds: nil, hasLoss: true, hasOutage: true))
    }

    func testVerdictPlacesTheSlowdownOnTheLegThatIsSlow() {
        let upstream: [NetworkSample] = Array(repeating: .ok(900, gateway: 4), count: 20)
        let upstreamStats = WindowStats(samples: upstream)
        let state = MonitorState(mode: .congested, stats: upstreamStats)
        XCTAssertEqual(Verdict.text(state: state, stats: upstreamStats), "Slow: 900ms median, no loss. Router is fine; the slowdown is upstream.")
        let local: [NetworkSample] = Array(repeating: .ok(900, gateway: 600), count: 20)
        XCTAssertTrue(Verdict.text(state: state, stats: WindowStats(samples: local)).hasSuffix("The link to your router is slow."))
    }

    func testSpringSettlesWithoutOvershootAndReversesWithoutAJump() {
        var full = CriticalSpring(value: 0)
        var peak = 0.0
        for _ in 0..<120 {
            full.advance(toward: 1, by: 1.0 / 120)
            peak = max(peak, full.value)
        }
        XCTAssertLessThanOrEqual(peak, 1)
        XCTAssertEqual(full.value, 1)

        // Interrupted 0.1s in, while moving fast: reversing keeps position and outbound velocity.
        var spring = CriticalSpring(value: 0)
        for _ in 0..<12 { spring.advance(toward: 1, by: 1.0 / 120) }
        let before = spring.value
        spring.advance(toward: 0, by: 1.0 / 120)
        XCTAssertGreaterThan(spring.value, before)
        for _ in 0..<120 { spring.advance(toward: 0, by: 1.0 / 120) }
        XCTAssertEqual(spring.value, 0)
    }

    func testRevealWidensTheItemBetweenIconAndGraph() throws {
        let samples = Array(repeating: NetworkSample.ok(18), count: 30)
        let state = MonitorState.evaluate(samples: samples, gatewayReachable: false)
        let widths = [0, 0.5, 1].map { StatusRenderer.image(samples: samples, state: state, reveal: $0, dark: false).size.width }
        XCTAssertEqual(widths[0], 30)
        XCTAssertGreaterThan(widths[1], widths[0])
        XCTAssertGreaterThan(widths[2], widths[1])
        XCTAssertEqual(widths[1] * 2, (widths[1] * 2).rounded())
    }

    func testRingBufferKeepsOldestToNewestOrder() {
        var buffer = SampleRingBuffer(capacity: 3)
        [.ok(10), .ok(20), .ok(30), .ok(40)].forEach { buffer.append($0) }
        XCTAssertEqual(buffer.samples, [.ok(20), .ok(30), .ok(40)])
    }

    private func render(_ samples: [NetworkSample], state: MonitorState, expanded: Bool) throws -> NSBitmapImageRep {
        let image = StatusRenderer.image(samples: samples, state: state, reveal: expanded ? 1 : 0, dark: false)
        return try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
    }

    /// Point coordinates, y-down, as in the handoff.
    private func color(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB))
    }
}
