import CoreGraphics
import CoreImage
import CoreVideo
import Darwin
import Foundation
import HermesCaptureCore

@MainActor
protocol LocalCaptureServicing: AnyObject {
    var frames: AsyncStream<CaptureFrame> { get }

    func start(displayID: UInt32) async throws
    func stop() async
    func updateFramesPerSecond(_ framesPerSecond: Int32) async throws
    func setCompatibilityWritingEnabled(_ enabled: Bool)
}

extension ScreenCaptureService: LocalCaptureServicing {}

@MainActor
protocol FrameImageEncoding: AnyObject {
    func encodePNG(_ pixelBuffer: CVPixelBuffer, to url: URL) throws
}

@MainActor
final class PNGFrameEncoder: FrameImageEncoding {
    enum EncodingError: Error {
        case conversionFailed
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    func encodePNG(_ pixelBuffer: CVPixelBuffer, to url: URL) throws {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let data = context.pngRepresentation(
            of: image,
            format: .BGRA8,
            colorSpace: colorSpace
        ) else {
            throw EncodingError.conversionFailed
        }
        try data.write(to: url, options: .atomic)
    }
}

@MainActor
final class LocalCaptureBridge {
    enum BridgeError: Error {
        case cacheOwnedByProcess(Int32)
        case invalidPIDFile
    }

    static var defaultCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/cache/oriel", isDirectory: true)
    }

    private let cacheDirectory: URL
    private let displayID: UInt32
    private let processIdentifier: Int32
    private let pollInterval: Duration
    private let service: any LocalCaptureServicing
    private let imageEncoder: any FrameImageEncoding
    private var frameTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var latestFrame: CVPixelBuffer?
    private var currentFramesPerSecond: Int32?
    private var compatibilityWritingEnabled = false
    private var lastRequestModification = Date.distantPast
    private var ownsCache = false
    private var serviceStarted = false
    private(set) var errorDescription: String?

    private var pidURL: URL { cacheDirectory.appendingPathComponent("pid") }
    private var frameURL: URL { cacheDirectory.appendingPathComponent("frame.raw") }
    private var requestURL: URL { cacheDirectory.appendingPathComponent("req") }
    private var rawControlURL: URL { cacheDirectory.appendingPathComponent("raw") }
    private var fpsURL: URL { cacheDirectory.appendingPathComponent("fps") }
    private var latestImageURL: URL { cacheDirectory.appendingPathComponent("latest.png") }

    init(
        cacheDirectory: URL,
        displayID: UInt32,
        processIdentifier: Int32,
        pollInterval: Duration = .milliseconds(30),
        service: any LocalCaptureServicing,
        imageEncoder: any FrameImageEncoding
    ) {
        self.cacheDirectory = cacheDirectory
        self.displayID = displayID
        self.processIdentifier = processIdentifier
        self.pollInterval = pollInterval
        self.service = service
        self.imageEncoder = imageEncoder
    }

    static func makeDefault() throws -> LocalCaptureBridge {
        let directory = defaultCacheDirectory
        let writer = try LegacySharedFrameWriter(
            url: directory.appendingPathComponent("frame.raw")
        )
        return LocalCaptureBridge(
            cacheDirectory: directory,
            displayID: CGMainDisplayID(),
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            service: ScreenCaptureService(compatibilityWriter: writer),
            imageEncoder: PNGFrameEncoder()
        )
    }

    func start() async throws {
        guard frameTask == nil, controlTask == nil, !serviceStarted else { return }
        do {
            try acquireCacheOwnership()
            if !FileManager.default.fileExists(atPath: frameURL.path) {
                FileManager.default.createFile(
                    atPath: frameURL.path,
                    contents: Data(repeating: 0, count: LegacyFrameHeader.encodedSize),
                    attributes: [.posixPermissions: 0o600]
                )
            }
            lastRequestModification = modificationDate(of: requestURL) ?? .distantPast
            service.setCompatibilityWritingEnabled(false)
            try await service.start(displayID: displayID)
            serviceStarted = true
            try await service.updateFramesPerSecond(5)
            currentFramesPerSecond = 5
            errorDescription = nil
            frameTask = Task { [weak self] in
                guard let self else { return }
                for await frame in service.frames {
                    if Task.isCancelled { return }
                    latestFrame = frame.pixelBuffer
                }
            }
            controlTask = Task { [weak self] in
                await self?.runControlLoop()
            }
        } catch {
            errorDescription = String(describing: error)
            await cleanupAfterFailedStart()
            NSLog("Oriel local capture bridge failed: %@", String(describing: error))
            throw error
        }
    }

    func stop() async {
        frameTask?.cancel()
        controlTask?.cancel()
        frameTask = nil
        controlTask = nil
        latestFrame = nil
        currentFramesPerSecond = nil
        if compatibilityWritingEnabled {
            service.setCompatibilityWritingEnabled(false)
            compatibilityWritingEnabled = false
        }
        if serviceStarted {
            await service.stop()
            serviceStarted = false
        }
        releaseCacheOwnership()
    }

    private func cleanupAfterFailedStart() async {
        frameTask?.cancel()
        controlTask?.cancel()
        frameTask = nil
        controlTask = nil
        if compatibilityWritingEnabled {
            service.setCompatibilityWritingEnabled(false)
            compatibilityWritingEnabled = false
        }
        if serviceStarted {
            await service.stop()
            serviceStarted = false
        }
        currentFramesPerSecond = nil
        latestFrame = nil
        releaseCacheOwnership()
    }

    private func runControlLoop() async {
        while !Task.isCancelled {
            await processControls()
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return
            }
        }
    }

    private func processControls(now: Date = .now) async {
        let rawRequested = isFresh(rawControlURL, now: now)
        if rawRequested != compatibilityWritingEnabled {
            service.setCompatibilityWritingEnabled(rawRequested)
            compatibilityWritingEnabled = rawRequested
        }

        let desiredFramesPerSecond = requestedFramesPerSecond(now: now)
        if desiredFramesPerSecond != currentFramesPerSecond {
            do {
                try await service.updateFramesPerSecond(desiredFramesPerSecond)
                currentFramesPerSecond = desiredFramesPerSecond
            } catch {
                errorDescription = String(describing: error)
            }
        }

        guard let requestModification = modificationDate(of: requestURL),
              requestModification > lastRequestModification,
              let latestFrame else {
            return
        }
        do {
            try imageEncoder.encodePNG(latestFrame, to: latestImageURL)
            lastRequestModification = requestModification
        } catch {
            errorDescription = String(describing: error)
        }
    }

    private func requestedFramesPerSecond(now: Date) -> Int32 {
        guard isFresh(fpsURL, now: now),
              let text = try? String(contentsOf: fpsURL, encoding: .utf8),
              let requested = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 5
        }
        return max(5, min(60, requested))
    }

    private func isFresh(_ url: URL, now: Date) -> Bool {
        guard let modification = modificationDate(of: url) else { return false }
        return now.timeIntervalSince(modification) < 3
    }

    private func acquireCacheOwnership() throws {
        // Owner only: the cache sits in the home folder, which other local accounts can list.
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDirectory.path)
        if FileManager.default.fileExists(atPath: pidURL.path) {
            guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
                  let existingPID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw BridgeError.invalidPIDFile
            }
            if processIsAlive(existingPID) {
                throw BridgeError.cacheOwnedByProcess(existingPID)
            }
            try FileManager.default.removeItem(at: pidURL)
        }

        let descriptor = Darwin.open(
            pidURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == EEXIST,
               let text = try? String(contentsOf: pidURL, encoding: .utf8),
               let existingPID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                throw BridgeError.cacheOwnedByProcess(existingPID)
            }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { Darwin.close(descriptor) }
        let payload = Array(String(processIdentifier).utf8)
        let written = payload.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == payload.count else {
            try? FileManager.default.removeItem(at: pidURL)
            throw CocoaError(.fileWriteUnknown)
        }
        ownsCache = true
    }

    private func releaseCacheOwnership() {
        guard ownsCache else { return }
        defer { ownsCache = false }
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) == processIdentifier else {
            return
        }
        try? FileManager.default.removeItem(at: pidURL)
    }

    private func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}
