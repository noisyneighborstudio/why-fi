import AppKit
import NetmonCore
import SwiftUI

final class MenubarApplicationDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var probes: NetworkProbeCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusController = StatusItemController()
        self.statusController = statusController
        let probes = NetworkProbeCoordinator { [weak statusController] event in
            statusController?.accept(event)
        }
        self.probes = probes
        probes.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        probes?.stop()
    }
}

/// State shared by the status item and the popover. Main thread only.
final class MonitorModel: ObservableObject {
    private static let displayModeKey = "displayMode"

    @Published private(set) var samples: [NetworkSample] = []
    @Published private(set) var state = MonitorState.initial
    @Published private(set) var failure: String?
    @Published var displayMode: DisplayMode {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: Self.displayModeKey)
            onChange?()
        }
    }
    var onChange: (() -> Void)?

    private var buffer = SampleRingBuffer(capacity: 300)
    private var latestSequence = 0
    private var gatewayReachable: Bool?

    init() {
        displayMode = UserDefaults.standard.string(forKey: Self.displayModeKey).flatMap(DisplayMode.init) ?? .auto
    }

    func accept(_ event: ProbeEvent) {
        switch event {
        case let .closed(sequence, sample, gatewayReachable):
            buffer.append(sample)
            latestSequence = sequence
            self.gatewayReachable = gatewayReachable
        case let .corrected(sequence, sample):
            buffer.replace(fromEnd: latestSequence - sequence, with: sample)
        case let .failed(message):
            failure = message
        }
        samples = buffer.samples
        state = MonitorState.evaluate(samples: Array(samples.suffix(60)), gatewayReachable: gatewayReachable)
        onChange?()
    }
}

final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = MonitorModel()

    override init() {
        super.init()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageOnly
        model.onChange = { [weak self] in self?.render() }
        render()

        let hosting = NSHostingController(rootView: PopoverView(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
    }

    func accept(_ event: ProbeEvent) {
        model.accept(event)
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        button.image = StatusRenderer.image(
            samples: model.samples,
            state: model.state,
            expanded: model.displayMode.isExpanded(for: model.state.mode),
            dark: dark
        )
        button.setAccessibilityLabel(StatusRenderer.accessibilityLabel(for: model.state))
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
