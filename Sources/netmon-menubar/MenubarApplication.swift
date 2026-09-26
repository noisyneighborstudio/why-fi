import AppKit
import Combine
import NetmonCore
import Sparkle
import SwiftUI
import WidgetKit

@MainActor
final class MenubarApplicationDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var probes: NetworkProbeCoordinator?
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let updateAvailability = UpdateAvailability()
        let updaterController = Self.makeUpdaterController(userDriverDelegate: updateAvailability)
        self.updaterController = updaterController
        updateAvailability.attach(updaterController?.updater)

        let statusController = StatusItemController(updateAvailability: updateAvailability)
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

    private static func makeUpdaterController(userDriverDelegate: SPUStandardUserDriverDelegate) -> SPUStandardUpdaterController? {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: userDriverDelegate
        )
    }
}

/// Update state for the status item and popover, and Sparkle's gentle reminders.
/// A menu bar app is never frontmost, so a scheduled update alert would open behind
/// other windows. Instead, Sparkle holds it back and the status item shows a blue dot
/// until the user opens the update from the popover.
@MainActor
final class UpdateAvailability: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    private(set) var updater: SPUUpdater?
    @Published private(set) var canCheckForUpdates = false
    /// Version of an update found by a scheduled check that the user hasn't looked at yet.
    @Published private(set) var pendingVersion: String?

    private var observation: NSKeyValueObservation?

    func attach(_ updater: SPUUpdater?) {
        self.updater = updater
        canCheckForUpdates = updater?.canCheckForUpdates ?? false
        observation = updater?.observe(\SPUUpdater.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func checkForUpdates() {
        // Brings a held-back update to the front instead of starting a new check.
        updater?.checkForUpdates()
    }

    private func refresh() {
        canCheckForUpdates = updater?.canCheckForUpdates ?? false
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Let Sparkle show it only when it can come up in front, such as right after launch.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            if handleShowingUpdate {
                // An accessory app's windows can't take focus, so become a regular app while the alert is up.
                NSApp.setActivationPolicy(.regular)
            }
            if !userInitiated {
                pendingVersion = version
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated {
            pendingVersion = nil
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            pendingVersion = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Hands the widget a snapshot and asks WidgetKit to reload, within its refresh budget.
final class WidgetPublisher {
    private let store: SnapshotStore
    private var policy = WidgetRefreshPolicy()

    init?() {
        guard let store = SnapshotStore() else { return nil }
        self.store = store
    }

    func publish(samples: [NetworkSample], state: MonitorState) {
        guard state.hasData, policy.shouldPublish(mode: state.mode, now: .now) else { return }
        do {
            try store.write(WidgetSnapshot(capturedAt: .now, mode: state.mode, samples: samples))
            WidgetCenter.shared.reloadTimelines(ofKind: NofiWidget.kind)
        } catch {
            NSLog("nofi: widget snapshot write failed: %@", String(describing: error))
        }
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

    private let widgets = WidgetPublisher()
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
        widgets?.publish(samples: samples, state: state)
        onChange?()
    }
}

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = MonitorModel()
    private var reveal: CriticalSpring
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    private let updateAvailability: UpdateAvailability
    private var pendingUpdateObservation: AnyCancellable?

    init(updateAvailability: UpdateAvailability) {
        self.updateAvailability = updateAvailability
        reveal = CriticalSpring(value: model.displayMode.isExpanded(for: model.state.mode) ? 1 : 0)
        super.init()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageOnly
        model.onChange = { [weak self] in self?.render() }
        render()
        // @Published fires before the value changes, so redraw on the next turn of the run loop.
        pendingUpdateObservation = updateAvailability.$pendingVersion
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.draw() }

        let hosting = NSHostingController(rootView: PopoverView(model: model, updateAvailability: updateAvailability))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
    }

    func accept(_ event: ProbeEvent) {
        model.accept(event)
    }

    private var revealTarget: Double {
        model.displayMode.isExpanded(for: model.state.mode) ? 1 : 0
    }

    private func render() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            reveal.snap(to: revealTarget)
        }
        if reveal.isSettled(at: revealTarget) {
            reveal.snap(to: revealTarget)
        } else if displayLink == nil, let button = statusItem.button {
            let link = button.displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        draw()
    }

    @objc private func step(_ link: CADisplayLink) {
        // Clamp so a stalled frame doesn't jump the animation to its end.
        let elapsed = lastFrame.map { min(link.targetTimestamp - $0, 1.0 / 30) } ?? link.duration
        lastFrame = link.targetTimestamp
        reveal.advance(toward: revealTarget, by: elapsed)
        draw()
        if reveal.isSettled(at: revealTarget) {
            link.invalidate()
            displayLink = nil
            lastFrame = nil
        }
    }

    private func draw() {
        guard let button = statusItem.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let updateAvailable = updateAvailability.pendingVersion != nil
        let image = StatusRenderer.image(samples: model.samples, state: model.state, reveal: reveal.value, dark: dark, updateAvailable: updateAvailable)
        // Set the length with the image so the item and its content move in the same frame.
        statusItem.length = image.size.width
        button.image = image
        let label = StatusRenderer.accessibilityLabel(for: model.state)
        button.setAccessibilityLabel(updateAvailable ? String(localized: "\(label), update available") : label)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
