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
        self.pairingPresentationOverride = nil
        let environment = ProcessInfo.processInfo.environment
        self.hostsTests = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestSessionIdentifier"] != nil
        self.startsCaptureBridge = Self.captureBridgeEnabled(in: .standard)
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
        self.pairingPresentationOverride = presentPairing
        self.hostsTests = false
        self.startsCaptureBridge = true
        super.init()
    }

    init(
        captureBridgeFactory: @escaping () throws -> any ApplicationCaptureBridging,
        pairingBridge: any ApplicationPairingBridging,
        screenCapturePreflight: @escaping () -> Bool,
        screenCaptureRequest: @escaping () -> Bool = { false }
    ) {
        self.pairingCoordinator = PairingCoordinator()
        self.screenProfiles = ScreenProfileController()
        self.pairingBridge = pairingBridge
        self.captureBridgeFactory = captureBridgeFactory
        self.screenCapturePreflight = screenCapturePreflight
        self.screenCaptureRequest = screenCaptureRequest
        self.presentsPairingAtLaunch = false
        self.pairingPresentationOverride = nil
        self.hostsTests = false
        self.startsCaptureBridge = true
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
        guard screenCapturePreflight() || screenCaptureRequest() else { return }
        do {
            let bridge = try captureBridgeFactory()
            captureBridge = bridge
            captureStartupTask = Task {
                do {
                    try await bridge.start()
                    captureRunning = true
                } catch {
                    captureRunning = false
                    NSLog("Oriel could not start its local capture bridge: %@", String(describing: error))
                }
            }
        } catch {
            NSLog("Oriel could not initialize its local capture bridge: %@", String(describing: error))
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        presentPairing()
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
        let task = Task {
            captureStartupTask?.cancel()
            if let captureStartupTask {
                await captureStartupTask.value
            }
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
