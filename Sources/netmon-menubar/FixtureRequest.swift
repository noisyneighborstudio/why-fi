import AppKit
import Foundation
import NetmonCore

/// `--render-fixture <state> --out <png> [--appearance light|dark] [--mode auto|compact|expanded]`
struct FixtureRequest {
    enum Fixture: String {
        case fine
        case congested
        case dead
        case gatewayOnly = "gateway-only"
    }

    enum RequestError: Error, CustomStringConvertible {
        case missing(String)
        case invalid(String, String)

        var description: String {
            switch self {
            case .missing(let flag): return "expected \(flag)"
            case .invalid(let flag, let value): return "invalid \(flag) \(value)"
            }
        }
    }

    let fixture: Fixture
    let outputURL: URL
    let dark: Bool
    let displayMode: DisplayMode

    init(arguments: [String]) throws {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        guard let fixtureValue = value("--render-fixture") else { throw RequestError.missing("--render-fixture <fine|congested|dead|gateway-only>") }
        guard let fixture = Fixture(rawValue: fixtureValue) else { throw RequestError.invalid("fixture", fixtureValue) }
        guard let output = value("--out") else { throw RequestError.missing("--out <file.png>") }
        let appearance = value("--appearance") ?? "light"
        guard ["light", "dark"].contains(appearance) else { throw RequestError.invalid("appearance", appearance) }
        let modeValue = value("--mode") ?? "auto"
        guard let displayMode = DisplayMode(rawValue: modeValue) else { throw RequestError.invalid("mode", modeValue) }
        self.fixture = fixture
        self.outputURL = URL(fileURLWithPath: output)
        self.dark = appearance == "dark"
        self.displayMode = displayMode
    }

    func render() throws {
        let samples = Self.samples(for: fixture)
        let state = MonitorState.evaluate(samples: samples, gatewayReachable: fixture == .gatewayOnly)
        let image = StatusRenderer.image(samples: samples, state: state, expanded: displayMode.isExpanded(for: state.mode), dark: dark)
        guard let bitmap = image.representations.first as? NSBitmapImageRep,
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RequestError.invalid("render", fixture.rawValue)
        }
        try data.write(to: outputURL, options: .atomic)
    }

    /// Mirrors the handoff mockup's sample patterns, as round-trip times.
    private static func samples(for fixture: Fixture) -> [NetworkSample] {
        switch fixture {
        case .fine:
            return (0..<60).map { .ok(14 + Double(($0 * 7) % 11)) }
        case .congested:
            return (0..<60).map { index in
                if [43, 50, 57].contains(index) { return .lost }
                let pattern: [Double] = [180, 520, 1_150, 300, 2_400, 760, 240, 1_600, 900, 420]
                return .classify(milliseconds: pattern[index % pattern.count], interval: 1)
            }
        case .dead:
            return (0..<41).map { .ok(18 + Double($0 % 5) * 3) } + Array(repeating: .lost, count: 19)
        case .gatewayOnly:
            return (0..<34).map { .ok(20 + Double($0 % 4) * 4, gateway: 3) }
                + Array(repeating: .lost(gateway: 3), count: 26)
        }
    }
}
