import AppKit
import CoreGraphics
import SwiftUI

@MainActor
protocol ApplicationCaptureBridging: AnyObject {
    func start() async throws
    func stop() async
}

extension LocalCaptureBridge: ApplicationCaptureBridging {}

@MainActor
protocol ApplicationPairingBridging: AnyObject {
    func startAvailability()
    func shutdown() async
}

extension PairingCoordinator: ApplicationPairingBridging {}

@MainActor
final class OrielApplicationDelegate: NSObject, NSApplicationDelegate {
    let pairingCoordinator: PairingCoordinator
    let screenProfiles: ScreenProfileController
    private(set) var captureRunning = false

    private var captureBridge: (any ApplicationCaptureBridging)?
    private let captureBridgeFactory: () throws -> any ApplicationCaptureBridging
    private let pairingBridge: any ApplicationPairingBridging
    private let screenCapturePreflight: () -> Bool
    private let screenCaptureRequest: () -> Bool
    private let presentsPairingAtLaunch: Bool
    /// Only a start the owner made asks for Screen Recording. A background start (launchd at
    /// login, `--headless`) left its system prompt behind other windows, where it kept
    /// resurfacing (Lucian 10-07); it waits for access instead.
    private let asksForScreenCapture: Bool
    var screenCapturePollInterval: Duration = .seconds(30)
    private var screenCaptureWait: Task<Void, Never>?
    private let pairingPresentationOverride: (() -> Void)?
    /// A unit-test run hosts its tests in a development build of the app. That copy stays
    /// inert: no Screen Recording request (macOS prompts for each unsigned build), no pairing
    /// service, no relay connection, no capture, so the installed Oriel is left alone.
    private let hostsTests: Bool
    /// The local capture bridge hands screen frames to local tools through files in the home
    /// folder, so any process of the user's could read the screen through Oriel's permission.
    /// It runs only when the owner turned it on (see docs/COMPATIBILITY.md).
    private let startsCaptureBridge: Bool
    static let captureBridgeDefaultsKey = "localCaptureBridge.enabled"

    static func captureBridgeEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: captureBridgeDefaultsKey)
    }
    /// The local goal bridge lets any process of the user's hand the assistant a goal through
    /// files beside the capture bridge's (see docs/COMPATIBILITY.md). It runs only when the
    /// owner turned it on, and only once the capture bridge runs, whose cache it shares.
    private let startsAssistantBridge: Bool
    private var assistantBridge: LocalAssistantBridge?
    /// The local input bridge puts the toolkit's input through Oriel's pipeline, so Oriel's
    /// cursor shows while Hermes acts. It starts with the goal bridge, under the same flag.
    private var inputBridge: LocalInputBridge?
    static let assistantBridgeDefaultsKey = "localAssistantBridge.enabled"

    static func assistantBridgeEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: assistantBridgeDefaultsKey)
    }
    private lazy var pairingWindowRegistry = PairingWindowRegistry { [unowned self] in
        OrielPairingWindowController(
            pairing: pairingCoordinator,
            screenProfiles: screenProfiles,
            prepareForTermination: { [weak self] in
                guard let self else { return }
                await self.prepareForTermination()
            }
        )
    }
    private var captureStartupTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var terminationPrepared = false
    private var terminationPending = false

    override init() {
        let pairingCoordinator = PairingCoordinator()
        self.pairingCoordinator = pairingCoordinator
        self.screenProfiles = ScreenProfileController()
        self.pairingBridge = pairingCoordinator
        self.captureBridgeFactory = { try LocalCaptureBridge.makeDefault() }
        self.screenCapturePreflight = { CGPreflightScreenCaptureAccess() }
        self.screenCaptureRequest = { CGRequestScreenCaptureAccess() }
        self.presentsPairingAtLaunch = !CommandLine.arguments.contains("--headless")
        self.asksForScreenCapture = !CommandLine.arguments.contains("--headless")
        self.pairingPresentationOverride = nil
        let environment = ProcessInfo.processInfo.environment
        self.hostsTests = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestSessionIdentifier"] != nil
        self.startsCaptureBridge = Self.captureBridgeEnabled(in: .standard)
        self.startsAssistantBridge = Self.assistantBridgeEnabled(in: .standard)
        super.init()
    }

    init(
        captureBridge: any ApplicationCaptureBridging,
        pairingBridge: any ApplicationPairingBridging,
        presentsPairingAtLaunch: Bool = false,
        presentPairing: (() -> Void)? = nil
    ) {
        self.pairingCoordinator = PairingCoordinator()
        self.screenProfiles = ScreenProfileController()
        self.pairingBridge = pairingBridge
        self.captureBridge = captureBridge
        self.captureBridgeFactory = { captureBridge }
        self.screenCapturePreflight = { true }
        self.screenCaptureRequest = { true }
        self.presentsPairingAtLaunch = presentsPairingAtLaunch
        self.asksForScreenCapture = presentsPairingAtLaunch
        self.pairingPresentationOverride = presentPairing
        self.hostsTests = false
        self.startsCaptureBridge = true
        self.startsAssistantBridge = false
        super.init()
    }

    init(
        captureBridgeFactory: @escaping () throws -> any ApplicationCaptureBridging,
        pairingBridge: any ApplicationPairingBridging,
        screenCapturePreflight: @escaping () -> Bool,
        screenCaptureRequest: @escaping () -> Bool = { false },
        asksForScreenCapture: Bool = true
    ) {
        self.pairingCoordinator = PairingCoordinator()
        self.screenProfiles = ScreenProfileController()
        self.pairingBridge = pairingBridge
        self.captureBridgeFactory = captureBridgeFactory
        self.screenCapturePreflight = screenCapturePreflight
        self.screenCaptureRequest = screenCaptureRequest
        self.asksForScreenCapture = asksForScreenCapture
        self.presentsPairingAtLaunch = false
        self.pairingPresentationOverride = nil
        self.hostsTests = false
        self.startsCaptureBridge = true
        self.startsAssistantBridge = false
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !hostsTests else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let permissions = PermissionState.current()
        ActivityLog.shared.write(.app, "Oriel \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) started"
            + " on \(ProcessInfo.processInfo.operatingSystemVersionString)"
            + "; Screen Recording \(permissions.screenRecordingGranted ? "granted" : "not granted")"
            + ", Accessibility \(permissions.accessibilityGranted ? "granted" : "not granted")")
        pairingBridge.startAvailability()
        if presentsPairingAtLaunch {
            presentPairing()
        }
        guard startsCaptureBridge, captureBridge == nil else { return }
        guard !terminationPending && !terminationPrepared else { return }
        if screenCapturePreflight() || (asksForScreenCapture && screenCaptureRequest()) {
            startCaptureBridge()
        } else if !asksForScreenCapture {
            waitForScreenCaptureAccess()
        }
    }

    /// Checks again now and then, without asking, and starts capture once access is there.
    private func waitForScreenCaptureAccess() {
        screenCaptureWait?.cancel()
        screenCaptureWait = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.screenCapturePollInterval ?? .seconds(30))
                guard let self, !Task.isCancelled, !self.terminationPending, !self.terminationPrepared,
                      self.captureBridge == nil else { return }
                if self.screenCapturePreflight() {
                    self.startCaptureBridge()
                    return
                }
            }
        }
    }

    private func startCaptureBridge() {
        guard captureBridge == nil else { return }
        do {
            let bridge = try captureBridgeFactory()
            captureBridge = bridge
            captureStartupTask = Task {
                do {
                    try await bridge.start()
                    captureRunning = true
                    startAssistantBridge()
                } catch {
                    captureRunning = false
                    NSLog("Oriel could not start its local capture bridge: %@", String(describing: error))
                }
            }
        } catch {
            NSLog("Oriel could not initialize its local capture bridge: %@", String(describing: error))
        }
    }

    private func startAssistantBridge() {
        guard startsAssistantBridge, assistantBridge == nil, terminationTask == nil,
              !terminationPending, !terminationPrepared else { return }
        let bridge = LocalAssistantBridge.makeDefault()
        do {
            try bridge.start()
            assistantBridge = bridge
        } catch {
            NSLog("Oriel could not start its local goal bridge: %@", String(describing: error))
        }
        let input = LocalInputBridge.makeDefault(goalRunActive: { [weak self] in self?.assistantBridge?.isRunning ?? false })
        do {
            try input.start()
            inputBridge = input
        } catch {
            NSLog("Oriel could not start its local input bridge: %@", String(describing: error))
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        presentPairing()
        // The owner opened Oriel: a capture still waiting for access may ask now.
        if startsCaptureBridge, captureBridge == nil, !terminationPending, !terminationPrepared,
           screenCapturePreflight() || screenCaptureRequest() {
            screenCaptureWait?.cancel()
            startCaptureBridge()
        }
        return true
    }

    private func presentPairing() {
        if let pairingPresentationOverride {
            pairingPresentationOverride()
            return
        }
        pairingWindowRegistry.showPairing()
    }

    func prepareForTermination() async {
        if let terminationTask {
            await terminationTask.value
            return
        }
        let captureBridge = captureBridge
        let captureStartupTask = captureStartupTask
        let pairingBridge = pairingBridge
        let assistantBridge = assistantBridge
        let inputBridge = inputBridge
        screenCaptureWait?.cancel()
        let task = Task {
            captureStartupTask?.cancel()
            if let captureStartupTask {
                await captureStartupTask.value
            }
            await inputBridge?.stop()
            await assistantBridge?.stop()
            await pairingBridge.shutdown()
            if let captureBridge {
                await captureBridge.stop()
            }
            captureRunning = false
        }
        terminationTask = task
        await task.value
        terminationPrepared = true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPrepared {
            return .terminateNow
        }
        if terminationPending {
            return .terminateLater
        }
        terminationPending = true
        Task {
            await prepareForTermination()
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
protocol PairingWindowControlling: AnyObject {
    func showPairing()
}

@MainActor
final class PairingWindowRegistry {
    private let makeWindowController: () -> any PairingWindowControlling
    private var windowController: (any PairingWindowControlling)?

    init(makeWindowController: @escaping () -> any PairingWindowControlling) {
        self.makeWindowController = makeWindowController
    }

    func showPairing() {
        if windowController == nil {
            windowController = makeWindowController()
        }
        windowController?.showPairing()
    }
}

@MainActor
private final class OrielPairingWindowController: NSWindowController, PairingWindowControlling {
    init(
        pairing: PairingCoordinator,
        screenProfiles: ScreenProfileController,
        prepareForTermination: @escaping @MainActor () async -> Void
    ) {
        let content = MacStatusView(
            pairing: pairing,
            screenProfiles: screenProfiles,
            prepareForTermination: prepareForTermination
        )
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Oriel"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 430, height: 700))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showPairing() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
