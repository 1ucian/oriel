import AppKit
import Testing
@testable import HermesCaptureMac

@MainActor
struct OrielApplicationDelegateTests {
    @Test func preparedTerminationStopsPairingAndCaptureOnce() async {
        let events = LifecycleEvents()
        let captureBridge = FakeApplicationCaptureBridge(events: events)
        let pairingBridge = FakeApplicationPairingBridge(events: events)
        let delegate = OrielApplicationDelegate(
            captureBridge: captureBridge,
            pairingBridge: pairingBridge
        )

        await delegate.prepareForTermination()
        await delegate.prepareForTermination()

        #expect(events.values == [.pairingStopped, .captureStopped])
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    @Test func terminationWaitsForCaptureStartupBeforeStoppingServices() async {
        let events = LifecycleEvents()
        let captureBridge = FakeApplicationCaptureBridge(
            events: events,
            suspendStart: true
        )
        let pairingBridge = FakeApplicationPairingBridge(events: events)
        let delegate = OrielApplicationDelegate(
            captureBridgeFactory: { captureBridge },
            pairingBridge: pairingBridge,
            screenCapturePreflight: { true }
        )

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        await Task.yield()
        #expect(events.values == [.pairingAvailabilityStarted, .captureStartBegan])

        let termination = Task { await delegate.prepareForTermination() }
        await Task.yield()
        #expect(events.values == [.pairingAvailabilityStarted, .captureStartBegan])

        captureBridge.finishStarting()
        await termination.value

        #expect(events.values == [
            .pairingAvailabilityStarted,
            .captureStartBegan,
            .captureStartFinished,
            .pairingStopped,
            .captureStopped,
        ])
    }

    @Test func failedScreenCapturePreflightRequestsPermissionAndDoesNotConstructBridgeWhenDenied() async {
        let events = LifecycleEvents()
        let pairingBridge = FakeApplicationPairingBridge(events: events)
        var bridgeCreationCount = 0
        var permissionRequestCount = 0
        let delegate = OrielApplicationDelegate(
            captureBridgeFactory: {
                bridgeCreationCount += 1
                return FakeApplicationCaptureBridge(events: events)
            },
            pairingBridge: pairingBridge,
            screenCapturePreflight: { false },
            screenCaptureRequest: {
                permissionRequestCount += 1
                return false
            }
        )

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        await Task.yield()

        #expect(permissionRequestCount == 1)
        #expect(bridgeCreationCount == 0)
        #expect(!delegate.captureRunning)
        #expect(events.values == [.pairingAvailabilityStarted])
    }

    @Test func grantedScreenCaptureRequestStartsCaptureAfterFailedPreflight() async {
        let events = LifecycleEvents()
        let captureBridge = FakeApplicationCaptureBridge(events: events)
        let pairingBridge = FakeApplicationPairingBridge(events: events)
        var permissionRequestCount = 0
        let delegate = OrielApplicationDelegate(
            captureBridgeFactory: { captureBridge },
            pairingBridge: pairingBridge,
            screenCapturePreflight: { false },
            screenCaptureRequest: {
                permissionRequestCount += 1
                return true
            }
        )

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        await Task.yield()

        #expect(permissionRequestCount == 1)
        #expect(delegate.captureRunning)
        #expect(events.values == [
            .pairingAvailabilityStarted,
            .captureStartBegan,
            .captureStartFinished,
        ])

        await delegate.prepareForTermination()
        #expect(!delegate.captureRunning)
    }

    @Test func theLocalCaptureBridgeIsOffUntilTheOwnerTurnsItOn() throws {
        let suite = "oriel.tests.capture-bridge.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!OrielApplicationDelegate.captureBridgeEnabled(in: defaults), "Off when never set")
        defaults.set(true, forKey: OrielApplicationDelegate.captureBridgeDefaultsKey)
        #expect(OrielApplicationDelegate.captureBridgeEnabled(in: defaults))
    }

    @Test func interactiveLaunchPresentsPairingWindow() {
        let events = LifecycleEvents()
        var presentationCount = 0
        let delegate = OrielApplicationDelegate(
            captureBridge: FakeApplicationCaptureBridge(events: events),
            pairingBridge: FakeApplicationPairingBridge(events: events),
            presentsPairingAtLaunch: true,
            presentPairing: { presentationCount += 1 }
        )

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        #expect(presentationCount == 1)
    }

    @Test func headlessLaunchDoesNotPresentPairingWindow() {
        let events = LifecycleEvents()
        var presentationCount = 0
        let delegate = OrielApplicationDelegate(
            captureBridge: FakeApplicationCaptureBridge(events: events),
            pairingBridge: FakeApplicationPairingBridge(events: events),
            presentsPairingAtLaunch: false,
            presentPairing: { presentationCount += 1 }
        )

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        #expect(presentationCount == 0)
    }

    @Test func reopeningRunningAppPresentsPairingWindow() {
        let events = LifecycleEvents()
        var presentationCount = 0
        let delegate = OrielApplicationDelegate(
            captureBridge: FakeApplicationCaptureBridge(events: events),
            pairingBridge: FakeApplicationPairingBridge(events: events),
            presentsPairingAtLaunch: false,
            presentPairing: { presentationCount += 1 }
        )

        let handled = delegate.applicationShouldHandleReopen(
            NSApplication.shared,
            hasVisibleWindows: false
        )

        #expect(handled)
        #expect(presentationCount == 1)
    }

    @Test func repeatedPresentationsReuseOnePairingWindowController() {
        var creationCount = 0
        let window = FakePairingWindowController()
        let registry = PairingWindowRegistry {
            creationCount += 1
            return window
        }

        registry.showPairing()
        registry.showPairing()
        registry.showPairing()

        #expect(creationCount == 1)
        #expect(window.showCount == 3)
    }
}

@MainActor
private final class LifecycleEvents {
    enum Value: Equatable {
        case pairingAvailabilityStarted
        case captureStartBegan
        case captureStartFinished
        case pairingStopped
        case captureStopped
    }

    private(set) var values: [Value] = []

    func append(_ value: Value) {
        values.append(value)
    }
}

@MainActor
private final class FakeApplicationCaptureBridge: ApplicationCaptureBridging {
    private let events: LifecycleEvents
    private let suspendStart: Bool
    private var startContinuation: CheckedContinuation<Void, Never>?

    init(events: LifecycleEvents, suspendStart: Bool = false) {
        self.events = events
        self.suspendStart = suspendStart
    }

    func start() async throws {
        events.append(.captureStartBegan)
        if suspendStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        events.append(.captureStartFinished)
    }

    func stop() async {
        events.append(.captureStopped)
    }

    func finishStarting() {
        startContinuation?.resume()
        startContinuation = nil
    }
}

@MainActor
private final class FakeApplicationPairingBridge: ApplicationPairingBridging {
    private let events: LifecycleEvents

    init(events: LifecycleEvents) {
        self.events = events
    }

    func startAvailability() {
        events.append(.pairingAvailabilityStarted)
    }

    func shutdown() async {
        events.append(.pairingStopped)
    }
}

@MainActor
private final class FakePairingWindowController: PairingWindowControlling {
    private(set) var showCount = 0

    func showPairing() {
        showCount += 1
    }
}
