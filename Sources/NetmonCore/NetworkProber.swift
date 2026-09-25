import Foundation

public enum ProbeEvent: Sendable {
    /// A slot closed one interval after it was sent: on time, or provisionally lost.
    case closed(sequence: Int, sample: NetworkSample, gatewayReachable: Bool?)
    /// A reply arrived after its slot closed — the case where `ping` prints a timeout, then the reply.
    case corrected(sequence: Int, sample: NetworkSample)
    case failed(String)
}

/// Sends one ICMP echo per interval to a public IP and to the gateway.
/// No TCP probe: in-flight and satellite links run proxies that answer TCP handshakes locally,
/// so connect time measures the proxy, not the internet.
/// Everything runs on one serial queue, and nothing on it blocks, so slots never compress.
public final class NetworkProbeCoordinator {
    public typealias EventHandler = (ProbeEvent) -> Void

    /// Replies later than this many slots are no longer matched to their slot.
    private static let graceSlots = 10

    private let queue = DispatchQueue(label: "netmon-menubar.probes", qos: .utility)
    private let publicAddress: String
    private let interval: TimeInterval
    private let handler: EventHandler
    private var timer: DispatchSourceTimer?
    private var echo: ICMPEchoSocket?
    private var activity: NSObjectProtocol?
    private var nextSequence = 0
    private var slots: [Int: Slot] = [:]
    private var gatewayAddress: String?
    private var lastGatewayReply: Int?

    private struct Slot {
        let sentAt: UInt64
        var sample: NetworkSample?
        var isClosed = false
    }

    public init(
        publicAddress: String = "1.1.1.1",
        interval: TimeInterval = 1,
        handler: @escaping EventHandler
    ) {
        self.publicAddress = publicAddress
        self.interval = interval
        self.handler = handler
    }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            // App Nap would coalesce the timer and silently stretch the strip's time axis.
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Per-second network probes"
            )
            do {
                echo = try ICMPEchoSocket(queue: queue) { [weak self] address, sequence in
                    self?.receiveEcho(from: address, sequence: sequence)
                }
            } catch {
                emit(.failed("ICMP unavailable: \(error)"))
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            echo?.close()
            echo = nil
            slots.removeAll()
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }
    }

    private func tick() {
        closeSlot(nextSequence - 1)
        slots = slots.filter { $0.key >= nextSequence - Self.graceSlots }
        if nextSequence % 30 == 0 {
            gatewayAddress = DefaultGatewayResolver.resolve()
        }
        sendSlot(nextSequence)
        nextSequence += 1
    }

    private func sendSlot(_ sequence: Int) {
        slots[sequence] = Slot(sentAt: DispatchTime.now().uptimeNanoseconds)
        let icmpSequence = UInt16(truncatingIfNeeded: sequence)
        echo?.send(to: publicAddress, sequence: icmpSequence)
        if let gatewayAddress {
            echo?.send(to: gatewayAddress, sequence: icmpSequence)
        }
    }

    private func receiveEcho(from address: String, sequence icmpSequence: UInt16) {
        guard let sequence = slots.keys.first(where: { UInt16(truncatingIfNeeded: $0) == icmpSequence }) else { return }
        if address == publicAddress {
            receiveReply(for: sequence)
        } else if address == gatewayAddress {
            lastGatewayReply = max(lastGatewayReply ?? sequence, sequence)
        }
    }

    private func receiveReply(for sequence: Int) {
        guard var slot = slots[sequence], slot.sample == nil else { return }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - slot.sentAt) / 1_000_000
        let sample = NetworkSample.classify(milliseconds: milliseconds, interval: interval)
        slot.sample = sample
        slots[sequence] = slot
        if slot.isClosed {
            emit(.corrected(sequence: sequence, sample: sample))
        }
    }

    private func closeSlot(_ sequence: Int) {
        guard var slot = slots[sequence] else { return }
        slot.isClosed = true
        slots[sequence] = slot
        let gatewayReachable = gatewayAddress.map { _ in (lastGatewayReply ?? .min) >= sequence - 2 }
        emit(.closed(sequence: sequence, sample: slot.sample ?? .lost, gatewayReachable: gatewayReachable))
    }

    private func emit(_ event: ProbeEvent) {
        let handler = self.handler
        DispatchQueue.main.async { handler(event) }
    }
}

/// Unprivileged ICMP echo over SOCK_DGRAM. Replies arrive with their IPv4 header attached.
private final class ICMPEchoSocket {
    enum SocketError: Error {
        case open(errno: Int32)
    }

    private let descriptor: Int32
    private let identifier = UInt16(truncatingIfNeeded: getpid())
    private let readSource: DispatchSourceRead

    init(queue: DispatchQueue, onReply: @escaping (_ address: String, _ sequence: UInt16) -> Void) throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard descriptor >= 0 else { throw SocketError.open(errno: errno) }
        self.descriptor = descriptor
        readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)

        let identifier = self.identifier
        readSource.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 1_500)
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, &buffer, buffer.count, 0, $0, &sourceLength)
                }
            }
            let header = buffer[0] >> 4 == 4 ? Int(buffer[0] & 0x0f) * 4 : 0
            guard count >= header + 8,
                  buffer[header] == 0,
                  UInt16(buffer[header + 4]) << 8 | UInt16(buffer[header + 5]) == identifier else { return }
            let sequence = UInt16(buffer[header + 6]) << 8 | UInt16(buffer[header + 7])
            onReply(String(cString: inet_ntoa(source.sin_addr)), sequence)
        }
        readSource.setCancelHandler { Darwin.close(descriptor) }
        readSource.resume()
    }

    func send(to address: String, sequence: UInt16) {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &destination.sin_addr) == 1 else { return }

        var packet: [UInt8] = [8, 0, 0, 0, UInt8(identifier >> 8), UInt8(identifier & 0xff), UInt8(sequence >> 8), UInt8(sequence & 0xff)]
        packet += [UInt8](repeating: 0, count: 16)
        let checksum = Self.checksum(packet)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 0xff)
        // A failed send (no route) is loss, and the slot records it as such.
        _ = withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(descriptor, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    func close() {
        readSource.cancel()
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for index in stride(from: 0, to: bytes.count, by: 2) {
            sum += UInt32(bytes[index]) << 8 | UInt32(index + 1 < bytes.count ? bytes[index + 1] : 0)
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return ~UInt16(sum)
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
            guard parts.count >= 2, parts[0] == "gateway:" else { continue }
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
