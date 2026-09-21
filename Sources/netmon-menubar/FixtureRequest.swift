import AppKit
import Foundation
import NetmonCore

struct FixtureRequest {
    enum Fixture: String {
        case fine
        case congested
        case dead
        case gatewayOnly = "gateway-only"
    }

    enum RequestError: Error, CustomStringConvertible {
        case missingFixture
        case missingOutput
        case unknownFixture(String)

        var description: String {
            switch self {
            case .missingFixture: return "expected --render-fixture <fine|congested|dead|gateway-only>"
            case .missingOutput: return "expected --out <file.png>"
            case .unknownFixture(let value): return "unknown fixture \(value)"
            }
        }
    }

    let fixture: Fixture
    let outputURL: URL

    init(arguments: [String]) throws {
        guard let fixtureIndex = arguments.firstIndex(of: "--render-fixture"), fixtureIndex + 1 < arguments.count else {
            throw RequestError.missingFixture
        }
        let fixtureValue = arguments[fixtureIndex + 1]
        guard let fixture = Fixture(rawValue: fixtureValue) else {
            throw RequestError.unknownFixture(fixtureValue)
        }
        guard let outputIndex = arguments.firstIndex(of: "--out"), outputIndex + 1 < arguments.count else {
            throw RequestError.missingOutput
        }
        self.fixture = fixture
        self.outputURL = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: false)
    }

    func render() throws {
        let samples = FixtureSamples.samples(for: fixture)
        let state = FixtureSamples.state(for: fixture, samples: samples)
        try StripRenderer.writePNG(
            samples: samples,
            state: state,
            to: outputURL,
            size: StripRenderer.statusSize,
            windowSeconds: 60,
            scale: 2,
            palette: .fixture
        )
    }
}

private enum FixtureSamples {
    static func samples(for fixture: FixtureRequest.Fixture) -> [NetworkSample] {
        switch fixture {
        case .fine:
            return (0..<60).map { index in
                .ok(32 + Double((index * 7) % 17))
            }
        case .congested:
            return (0..<60).map { index in
                switch index % 9 {
                case 0: return .lost
                case 1, 5: return .late(620 + Double((index * 83) % 440))
                case 2: return .ok(330)
                case 3: return .late(1_180)
                case 4: return .ok(540)
                case 6: return .ok(90)
                case 7: return .late(860)
                default: return .ok(220)
                }
            }
        case .dead:
            let healthy = (0..<25).map { _ in NetworkSample.ok(42) }
            return healthy + Array(repeating: NetworkSample.lost, count: 35)
        case .gatewayOnly:
            return (0..<60).map { index in
                switch index % 4 {
                case 0, 1: return .lost
                case 2: return .late(980)
                default: return .lost
                }
            }
        }
    }

    static func state(for fixture: FixtureRequest.Fixture, samples: [NetworkSample]) -> MonitorState {
        let stats = WindowStats(samples: samples)
        switch fixture {
        case .fine:
            return MonitorState(mode: .fine, stats: stats, pulseOn: true)
        case .congested:
            return MonitorState(mode: .congested, stats: stats, pulseOn: true)
        case .dead:
            return MonitorState(mode: .dead, stats: stats, outageSeconds: 23, pulseOn: false)
        case .gatewayOnly:
            return MonitorState(mode: .gatewayOnly, stats: stats, pulseOn: false, gatewayReachable: true)
        }
    }
}
