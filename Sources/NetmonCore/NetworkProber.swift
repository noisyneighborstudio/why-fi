import Foundation
import Network

public final class NetworkProbeCoordinator {
    public typealias SnapshotHandler = (ProbeSnapshot) -> Void

    private let probeQueue = DispatchQueue(label: "netmon-menubar.probes", qos: .utility)
    private let callbackQueue = DispatchQueue(label: "netmon-menubar.probe-callbacks", qos: .utility)
    private let publicAddress: String
    private let publicPort: UInt16
    private let interval: TimeInterval
    private let handler: SnapshotHandler
    private var timer: DispatchSourceTimer?
    private var isStopped = false
    private var tickCount = 0
    private var lastIdleMilliseconds: Double?
    private var lastUnderLoadMilliseconds: Double?

    public init(
        publicAddress: String = "1.1.1.1",
        publicPort: UInt16 = 443,
        interval: TimeInterval = 1,
        handler: @escaping SnapshotHandler
    ) {
        self.publicAddress = publicAddress
        self.publicPort = publicPort
        self.interval = interval
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() {
        probeQueue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.isStopped = false
            let timer = DispatchSource.makeTimerSource(queue: self.probeQueue)
            timer.schedule(deadline: .now(), repeating: self.interval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                self?.probeTick()
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        probeQueue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.timer?.setEventHandler {}
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func probeTick() {
        guard !isStopped else { return }
        let gatewayAddress = DefaultGatewayResolver.resolve()
        let shouldMeasureLoad = tickCount % 30 == 0
        let group = DispatchGroup()
        let lock = NSLock()
        var publicEndpoint: EndpointProbe?
        var gatewayEndpoint: EndpointProbe?

        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let endpoint = Self.probeEndpoint(address: publicAddress, port: publicPort, callbackQueue: callbackQueue)
            lock.lock()
            publicEndpoint = endpoint
            lock.unlock()
            group.leave()
        }

        if let gatewayAddress {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                let endpoint = Self.probeEndpoint(address: gatewayAddress, port: publicPort, callbackQueue: callbackQueue)
                lock.lock()
                gatewayEndpoint = endpoint
                lock.unlock()
                group.leave()
            }
        }

        _ = group.wait(timeout: .now() + 3.5)
        guard let publicEndpoint else { return }
        if shouldMeasureLoad {
            lastIdleMilliseconds = publicEndpoint.displaySample.rttMilliseconds
            lastUnderLoadMilliseconds = BufferbloatProbe.measure(
                address: publicAddress,
                port: publicPort,
                callbackQueue: callbackQueue
            )
        }
        tickCount += 1
        let snapshot = ProbeSnapshot(
            publicEndpoint: publicEndpoint,
            gatewayEndpoint: gatewayEndpoint,
            idleMilliseconds: lastIdleMilliseconds,
            underLoadMilliseconds: lastUnderLoadMilliseconds
        )
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.handler(snapshot)
        }
    }

    private static func probeEndpoint(address: String, port: UInt16, callbackQueue: DispatchQueue) -> EndpointProbe {
        let icmp = ICMPProbe.measure(address: address)
        let tcp = TCPProbe.measure(address: address, port: port, callbackQueue: callbackQueue)
        return EndpointProbe(address: address, icmp: icmp, tcp: tcp)
    }
}

private enum BufferbloatProbe {
    static func measure(address: String, port: UInt16, callbackQueue: DispatchQueue) -> Double? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let connections = (0..<4).map { _ in
            NWConnection(host: NWEndpoint.Host(address), port: endpointPort, using: .tcp)
        }
        let eventSemaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var signalled = Array(repeating: false, count: connections.count)
        let payload = Data(repeating: 0, count: 16 * 1024)

        for (index, connection) in connections.enumerated() {
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { _ in })
                    lock.lock()
                    let shouldSignal = !signalled[index]
                    signalled[index] = true
                    lock.unlock()
                    if shouldSignal { eventSemaphore.signal() }
                case .failed, .cancelled:
                    lock.lock()
                    let shouldSignal = !signalled[index]
                    signalled[index] = true
                    lock.unlock()
                    if shouldSignal { eventSemaphore.signal() }
                default:
                    break
                }
            }
            connection.start(queue: callbackQueue)
        }

        for _ in connections {
            _ = eventSemaphore.wait(timeout: .now() + 1)
        }
        let loadedMeasurement = ICMPProbe.measure(address: address).sample.rttMilliseconds
        connections.forEach { $0.cancel() }
        return loadedMeasurement
    }
}

private enum ICMPProbe {
    static func measure(address: String) -> ProbeMeasurement {
        let executable = URL(fileURLWithPath: "/sbin/ping")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-n", "-c", "1", "-W", "2000", address]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProbeMeasurement.classify(transport: .icmp, milliseconds: nil)
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard let milliseconds = parseMilliseconds(from: output), process.terminationStatus == 0 else {
            return ProbeMeasurement.classify(transport: .icmp, milliseconds: nil)
        }
        return ProbeMeasurement.classify(transport: .icmp, milliseconds: milliseconds)
    }

    private static func parseMilliseconds(from output: String) -> Double? {
        let pattern = #"time[=<]([0-9]+(?:\.[0-9]+)?)\s*ms"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression.firstMatch(in: output, range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: output) else { return nil }
        return Double(output[valueRange])
    }
}

private enum TCPProbe {
    static func measure(address: String, port: UInt16, callbackQueue: DispatchQueue) -> ProbeMeasurement {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return ProbeMeasurement.classify(transport: .tcp, milliseconds: nil)
        }

        let connection = NWConnection(host: NWEndpoint.Host(address), port: endpointPort, using: .tcp)
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var completed = false
        var elapsedMilliseconds: Double?
        let started = DispatchTime.now().uptimeNanoseconds

        func finish(_ result: Double?) {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return }
            completed = true
            elapsedMilliseconds = result
            semaphore.signal()
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                finish(elapsed)
                connection.cancel()
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: callbackQueue)
        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            connection.cancel()
            finish(nil)
        }

        lock.lock()
        let result = elapsedMilliseconds
        lock.unlock()
        return ProbeMeasurement.classify(transport: .tcp, milliseconds: result)
    }
}

private enum DefaultGatewayResolver {
    static func resolve() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "gateway" else { continue }
            let address = String(parts[1])
            guard IPv4AddressValidator.isLiteral(address) else { return nil }
            return address
        }
        return nil
    }
}

private enum IPv4AddressValidator {
    static func isLiteral(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, let number = Int(part), (0...255).contains(number) else { return false }
            return String(number) == part || part == "0"
        }
    }
}
