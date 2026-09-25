import Foundation

/// A critically damped spring, the curve of SwiftUI's `.smooth` (bounce 0).
/// No overshoot: the status item's width pushes its neighbors, so it must not grow past its target.
/// Retargeting keeps position and velocity, so an interrupted animation reverses without a jump.
public struct CriticalSpring: Sendable {
    public private(set) var value: Double
    public private(set) var velocity: Double = 0
    private let stiffness: Double
    private let damping: Double

    public init(value: Double, duration: Double = 0.4) {
        self.value = value
        stiffness = pow(2 * .pi / duration, 2)
        damping = 4 * .pi / duration
    }

    public mutating func advance(toward target: Double, by elapsed: Double) {
        // Fixed substeps keep the integration stable across uneven frame times.
        let steps = max(1, Int((elapsed * 480).rounded(.up)))
        let dt = elapsed / Double(steps)
        for _ in 0..<steps {
            velocity += (-stiffness * (value - target) - damping * velocity) * dt
            value += velocity * dt
        }
        if isSettled(at: target) { snap(to: target) }
    }

    public mutating func snap(to target: Double) {
        value = target
        velocity = 0
    }

    public func isSettled(at target: Double) -> Bool {
        abs(value - target) < 0.001 && abs(velocity) < 0.01
    }
}
