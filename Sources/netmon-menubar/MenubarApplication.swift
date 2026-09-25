import AppKit
import Foundation
import NetmonCore

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

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var samples = SampleRingBuffer(capacity: 300)
    private var latestSequence = 0
    private var gatewayReachable: Bool?
    private var state = MonitorState.initial
    private var pulseOn = false
    private var probeFailure: String?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: StripRenderer.statusSize.width)
        popover = NSPopover()
        super.init()

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        renderStatus(samples: [])

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NetworkPopoverViewController()
    }

    func accept(_ event: ProbeEvent) {
        switch event {
        case let .closed(sequence, sample, gatewayReachable):
            samples.append(sample)
            latestSequence = sequence
            self.gatewayReachable = gatewayReachable
            pulseOn.toggle()
        case let .corrected(sequence, sample):
            samples.replace(fromEnd: latestSequence - sequence, with: sample)
        case let .failed(message):
            probeFailure = message
        }
        let statusSamples = Array(samples.samples.suffix(60))
        state = MonitorState.evaluate(samples: statusSamples, gatewayReachable: gatewayReachable, pulseOn: pulseOn)
        renderStatus(samples: statusSamples)
        (popover.contentViewController as? NetworkPopoverViewController)?.update(samples: samples.samples, state: state, failure: probeFailure)
    }

    private func renderStatus(samples: [NetworkSample]) {
        guard let button = statusItem.button else { return }
        // All on time is a template image so the system owns light/dark, tinting, and highlight.
        // Colored strips resolve against the menubar's own appearance, not the app's.
        let isTemplate = samples.allSatisfy { $0.outcome == .ok }
        let appearance = isTemplate ? NSAppearance(named: .aqua)! : button.effectiveAppearance
        var image = NSImage(size: StripRenderer.statusSize)
        appearance.performAsCurrentDrawingAppearance {
            image = StripRenderer.image(samples: samples, state: state)
        }
        image.isTemplate = isTemplate
        button.image = image
        button.setAccessibilityLabel(accessibilityDescription(for: state))
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            (popover.contentViewController as? NetworkPopoverViewController)?.update(samples: samples.samples, state: state, failure: probeFailure)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func accessibilityDescription(for state: MonitorState) -> String {
        guard state.hasData else { return "Network monitor waiting for first probe" }
        let mode = state.mode.rawValue
        if state.mode == .dead, state.showsOutageDuration {
            return "Network monitor: \(mode), outage \(state.outageSeconds) seconds"
        }
        return String(format: "Network monitor: %@, %.1f percent loss", mode, state.stats.lossPercent)
    }
}

final class NetworkPopoverViewController: NSViewController {
    private let stripView = PopoverStripView(frame: .zero)
    private let modeLabel = NSTextField(labelWithString: "Waiting for probe…")
    private let statsLabel = NSTextField(labelWithString: "")
    private let deltaLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView(frame: CGRect(origin: .zero, size: CGSize(width: 440, height: 240)))
        root.wantsLayer = true

        let title = NSTextField(labelWithString: "Network quality")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        modeLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        deltaLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        deltaLabel.textColor = .secondaryLabelColor
        deltaLabel.translatesAutoresizingMaskIntoConstraints = false

        stripView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)
        root.addSubview(modeLabel)
        root.addSubview(stripView)
        root.addSubview(statsLabel)
        root.addSubview(deltaLabel)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            modeLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            modeLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            stripView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stripView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stripView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            stripView.heightAnchor.constraint(equalToConstant: StripRenderer.popoverSize.height),
            statsLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            statsLabel.topAnchor.constraint(equalTo: stripView.bottomAnchor, constant: 14),
            deltaLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            deltaLabel.topAnchor.constraint(equalTo: statsLabel.bottomAnchor, constant: 5)
        ])
        view = root
    }

    func update(samples: [NetworkSample], state: MonitorState, failure: String?) {
        guard isViewLoaded else { return }
        stripView.update(samples: samples, state: state)
        guard state.hasData else {
            modeLabel.stringValue = "waiting for first probe"
            statsLabel.stringValue = failure ?? ""
            deltaLabel.stringValue = ""
            return
        }

        // The popover strip spans 5 minutes, so its numbers do too.
        let stats = WindowStats(samples: samples)
        modeLabel.stringValue = state.mode.rawValue
        let p50 = formattedMilliseconds(stats.p50Milliseconds)
        let p95 = formattedMilliseconds(stats.p95Milliseconds)
        let max = formattedMilliseconds(stats.maxMilliseconds)
        statsLabel.stringValue = String(
            format: "loss %5.1f%%   p50 %@   p95 %@   max %@   outage %02ds",
            stats.lossPercent,
            p50,
            p95,
            max,
            state.outageSeconds
        )
        // Late replies are queueing made visible: the in-band bufferbloat signal.
        deltaLabel.stringValue = failure ?? "late \(stats.lateCount)   longest outage \(stats.longestLossRun)s"
    }

    private func formattedMilliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%4.0fms", value)
    }
}

final class PopoverStripView: NSView {
    private var samples: [NetworkSample] = []
    private var state = MonitorState.initial

    override var intrinsicContentSize: NSSize { StripRenderer.popoverSize }

    func update(samples: [NetworkSample], state: MonitorState) {
        self.samples = samples
        self.state = state
        needsDisplay = true
    }

    // Rendered inside draw() so labelColor resolves against this view's appearance.
    override func draw(_ dirtyRect: NSRect) {
        StripRenderer.image(samples: samples, state: state, size: StripRenderer.popoverSize, windowSeconds: 300)
            .draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
