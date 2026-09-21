import AppKit
import Foundation
import NetmonCore

final class MenubarApplicationDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var probes: NetworkProbeCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusController = StatusItemController()
        self.statusController = statusController
        let probes = NetworkProbeCoordinator { [weak statusController] snapshot in
            statusController?.accept(snapshot)
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
    private let stripView: StatusStripView
    private let popover: NSPopover
    private var samples = SampleRingBuffer(capacity: 300)
    private var stateMachine = MonitorStateMachine()
    private var state = MonitorState.initial
    private var pulseOn = false
    private var frozenDeadStripSamples: [NetworkSample]?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: 72)
        stripView = StatusStripView(frame: CGRect(origin: .zero, size: StripRenderer.statusSize))
        popover = NSPopover()
        super.init()

        stripView.onClick = { [weak self] in self?.togglePopover() }
        stripView.update(samples: [], state: state)
        statusItem.view = stripView

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NetworkPopoverViewController()
    }

    func accept(_ snapshot: ProbeSnapshot) {
        samples.append(snapshot.publicSample)
        pulseOn.toggle()
        state = stateMachine.update(
            snapshot: snapshot,
            samples: samples.samples,
            now: Date(),
            pulseOn: pulseOn
        )
        if state.mode != .dead {
            frozenDeadStripSamples = nil
        } else if state.showsOutageDuration, frozenDeadStripSamples == nil {
            frozenDeadStripSamples = Array(samples.samples.suffix(60))
        }
        let statusSamples = frozenDeadStripSamples ?? Array(samples.samples.suffix(60))
        stripView.update(samples: statusSamples, state: state)
        (popover.contentViewController as? NetworkPopoverViewController)?.update(samples: samples.samples, state: state)
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let view = statusItem.view {
            (popover.contentViewController as? NetworkPopoverViewController)?.update(samples: samples.samples, state: state)
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }
}

final class StatusStripView: NSView {
    var onClick: (() -> Void)?
    private var image = NSImage(size: StripRenderer.statusSize)

    override var intrinsicContentSize: NSSize { StripRenderer.statusSize }

    func update(samples: [NetworkSample], state: MonitorState) {
        image = StripRenderer.image(
            samples: samples,
            state: state,
            size: StripRenderer.statusSize,
            windowSeconds: 60,
            scale: max(window?.backingScaleFactor ?? 2, 2),
            palette: .menuBar
        )
        needsDisplay = true
        setAccessibilityLabel(accessibilityDescription(for: state))
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
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

    func update(samples: [NetworkSample], state: MonitorState) {
        guard isViewLoaded else { return }
        stripView.update(samples: samples, state: state)
        guard state.hasData else {
            modeLabel.stringValue = "waiting for first probe"
            statsLabel.stringValue = "No fallback samples"
            deltaLabel.stringValue = "Bufferbloat delta: —"
            return
        }

        modeLabel.stringValue = state.mode.rawValue
        let p50 = formattedMilliseconds(state.stats.p50Milliseconds)
        let p95 = formattedMilliseconds(state.stats.p95Milliseconds)
        let max = formattedMilliseconds(state.stats.maxMilliseconds)
        statsLabel.stringValue = String(
            format: "loss %5.1f%%   p50 %@   p95 %@   max %@   outage %02ds",
            state.stats.lossPercent,
            p50,
            p95,
            max,
            state.outageSeconds
        )
        if let delta = state.bufferbloatDeltaMilliseconds {
            deltaLabel.stringValue = String(format: "Bufferbloat delta: %+0.1f ms   longest outage: %ds", delta, state.stats.longestLossRun)
        } else {
            deltaLabel.stringValue = "Bufferbloat delta: — (no load probe)   longest outage: \(state.stats.longestLossRun)s"
        }
    }

    private func formattedMilliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%4.0fms", value)
    }
}

final class PopoverStripView: NSView {
    private var image = NSImage(size: StripRenderer.popoverSize)

    override var intrinsicContentSize: NSSize { StripRenderer.popoverSize }

    func update(samples: [NetworkSample], state: MonitorState) {
        image = StripRenderer.image(
            samples: samples,
            state: state,
            size: StripRenderer.popoverSize,
            windowSeconds: 300,
            scale: max(window?.backingScaleFactor ?? 2, 2),
            palette: .menuBar
        )
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
