import CryptoKit
import Foundation
import HuggingFace

/// Where the Whisper model lives and how it gets there: the float16 weights of
/// mlx-community/whisper-large-v3-mlx (the model Hermes runs) and the tokenizer vocabulary of
/// openai/whisper-large-v3, both from Hugging Face, kept in the hub cache layout. Both are fetched at fixed
/// commits, and the engine reads a file only after its SHA-256 matches the one pinned here, wherever the file
/// came from.
enum WhisperModelStore {
    static let modelID = "mlx-community/whisper-large-v3-mlx"
    static let tokenizerID = "openai/whisper-large-v3"
    static let displayName = "Whisper large-v3"

    /// One file as Hugging Face serves it at a fixed commit.
    struct PinnedFile: Equatable, Sendable {
        let repo: String
        let revision: String
        let name: String
        /// Lowercase hex SHA-256 of the bytes; for the weights, Hugging Face's LFS oid.
        let sha256: String
        let bytes: Int64
    }

    /// The commits everything is fetched at, never a branch. A newer model means checking its files again and
    /// changing these and the pins below together.
    static let modelRevision = "49e6aa286ad60c14352c404340ded53710378a11"
    static let tokenizerRevision = "06f233fe06e710322aca913c1bc4249a0d71fce1"

    /// Every file the engine loads.
    static let pinnedConfig = PinnedFile(
        repo: modelID, revision: modelRevision, name: "config.json",
        sha256: "34982ce6ae286095000f82ae9583b3431639e8b092bf60c961f203745e6500e3", bytes: 269)
    static let pinnedWeights = PinnedFile(
        repo: modelID, revision: modelRevision, name: "weights.npz",
        sha256: "05ff791ce3630fae47e7c51004e9666204d786246ec07cac6110af768099b40d", bytes: 3_083_520_416)
    static let pinnedVocabulary = PinnedFile(
        repo: tokenizerID, revision: tokenizerRevision, name: "vocab.json",
        sha256: "e2aa043ef015641d363d8288e7c241c85e36a5c761fb303598e0710233344387", bytes: 1_036_558)

    static let weightFiles = [pinnedConfig.name, pinnedWeights.name]
    static let tokenizerFiles = [pinnedVocabulary.name]
    /// weights.npz and config.json as Hugging Face serves them.
    static let weightBytes: Int64 = pinnedWeights.bytes + pinnedConfig.bytes
    /// vocab.json as Hugging Face serves it.
    static let tokenizerBytes: Int64 = pinnedVocabulary.bytes
    static let approximateBytes: Int64 = weightBytes + tokenizerBytes

    /// What a download fetches from one repository.
    struct Fetch: Equatable {
        let repo: String
        let revision: String
        let files: [String]
        let bytes: Int64
    }

    static let tokenizerFetch = Fetch(repo: tokenizerID, revision: tokenizerRevision, files: tokenizerFiles, bytes: tokenizerBytes)
    static let weightsFetch = Fetch(repo: modelID, revision: modelRevision, files: weightFiles, bytes: weightBytes)

    /// What `download` would fetch right now: 0 when installed, about 1 MB when only the
    /// vocabulary is missing (another tool's weights in the shared cache), the full size otherwise.
    static var missingBytes: Int64 {
        (weightsDirectory() == nil ? weightBytes : 0) + (vocabularyURL() == nil ? tokenizerBytes : 0)
    }

    enum Failure: Error, CustomStringConvertible, Equatable {
        case incomplete
        /// A file differs from its pin, so nothing was loaded. `ownCopyRemoved`: it was Oriel's own copy and is
        /// deleted; otherwise it belongs to another tool and stays where it is.
        case failedCheck(file: String, ownCopyRemoved: Bool)

        var description: String {
            switch self {
            case .incomplete:
                "The Whisper model download did not complete. Try again."
            case .failedCheck(file: _, ownCopyRemoved: true):
                "The voice model didn't pass its check, so Oriel deleted its copy. Try again to download it fresh."
            case .failedCheck(file: _, ownCopyRemoved: false):
                "The voice model in your Hugging Face cache didn't pass its check, so Oriel did not load it. Try again to download its own copy."
            }
        }
    }

    /// Oriel's own models folder, where downloads go.
    static var orielCache: URL { EmbeddedModelEngine.modelsDirectory }

    /// The standard Hugging Face cache other tools fill (Hermes's copy lives here); read only.
    static var sharedCache: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// A complete local copy: the weights from Oriel's folder or the shared cache, with the
    /// tokenizer vocabulary from either. Nil when something is missing.
    static func installedDirectory() -> URL? {
        guard vocabularyURL() != nil else { return nil }
        return weightsDirectory()
    }

    static func weightsDirectory() -> URL? {
        snapshot(of: modelID, containing: weightFiles, in: orielCache)
            ?? snapshot(of: modelID, containing: weightFiles, in: sharedCache)
    }

    static func vocabularyURL() -> URL? {
        let directory = snapshot(of: tokenizerID, containing: tokenizerFiles, in: orielCache)
            ?? snapshot(of: tokenizerID, containing: tokenizerFiles, in: sharedCache)
        return directory?.appendingPathComponent("vocab.json")
    }

    /// Fetches what is missing into Oriel's folder. Progress runs 0…1 by bytes; cancelling the
    /// task stops the transfer and deletes the partial files.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        var plan: [Fetch] = []
        if vocabularyURL() == nil { plan.append(tokenizerFetch) }
        if weightsDirectory() == nil { plan.append(weightsFetch) }
        let total = Double(max(plan.reduce(0) { $0 + $1.bytes }, 1))
        var finished = 0.0
        progress(0)
        for item in plan {
            let offset = finished
            let share = Double(item.bytes)
            try await fetch(item.repo, revision: item.revision, files: item.files, into: orielCache) { fraction in
                progress(min(1, (offset + fraction * share) / total))
            }
            finished += share
        }
        progress(1)
        guard let directory = installedDirectory() else { throw Failure.incomplete }
        return directory
    }

    /// One repository's files at `revision` into `cache`, in the hub layout. Cancelling deletes partial files.
    static func fetch(
        _ repoID: String,
        revision: String,
        files: [String],
        into cache: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let repo = Repo.ID(rawValue: repoID) else { throw Failure.incomplete }
        let client = HubClient(host: HubClient.defaultHost, tokenProvider: .none, cache: HubCache(cacheDirectory: cache))
        do {
            try Task.checkCancellation()
            _ = try await client.downloadSnapshot(
                of: repo,
                revision: revision,
                matching: files,
                progressHandler: { status in progress(status.fractionCompleted) }
            )
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled || error is CancellationError { removePartialFiles(of: repoID, in: cache) }
            throw error
        }
    }

    /// Deletes Oriel's own copy, never the shared Hugging Face cache.
    static func removeDownloaded() throws {
        let manager = FileManager.default
        for repo in [modelID, tokenizerID] {
            for url in [repoDirectory(repo, in: orielCache), orielCache.appendingPathComponent(".locks/\(folderName(repo))")]
            where manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
        }
    }

    // MARK: Checking the files

    /// The three files the engine is about to load, each against its pin, smallest first.
    static func verify(config: URL, vocabulary: URL, weights: URL) throws {
        try verify([(config, pinnedConfig), (vocabulary, pinnedVocabulary), (weights, pinnedWeights)], ownedBy: orielCache)
    }

    /// Hashes each file and compares it with its pin before anything reads it. A file that differs throws and is
    /// never loaded. If it sits in `owned` (Oriel's folder) it is deleted, with the blob it links to, so the next
    /// download starts clean. A file anywhere else belongs to another tool and is left alone, and the store looks
    /// past it from then on, so the next download brings Oriel's own copy.
    static func verify(_ files: [(url: URL, pin: PinnedFile)], ownedBy owned: URL) throws {
        for (url, pin) in files {
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.incomplete }
            if try sha256(of: url, bytes: pin.bytes) == pin.sha256 { continue }
            let removed = removeOwnCopy(at: url, in: owned)
            if !removed { refused.insert(url.path) }
            throw Failure.failedCheck(file: pin.name, ownCopyRemoved: removed)
        }
    }

    /// The file's SHA-256 as lowercase hex, or nil when its size is not `bytes`, which settles it without a read.
    private static func sha256(of url: URL, bytes: Int64) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try Int64(handle.seekToEnd()) == bytes else { return nil }
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        var reading = true
        while reading {
            try autoreleasepool {
                if let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                    hasher.update(data: chunk)
                } else {
                    reading = false
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Deletes `url` and the blob it links to when they sit in `owned`; whether the entry is gone.
    private static func removeOwnCopy(at url: URL, in owned: URL) -> Bool {
        guard isInside(url.deletingLastPathComponent(), owned) else { return false }
        let manager = FileManager.default
        // A hub cache entry links to a blob named by its hash; a corrupt blob left there would count as cached.
        let blob = url.resolvingSymlinksInPath()
        try? manager.removeItem(at: url)
        if blob != url, isInside(blob, owned) { try? manager.removeItem(at: blob) }
        return !manager.fileExists(atPath: url.path)
    }

    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
    }

    /// Files of another tool's cache that failed their check in this run.
    private static let refused = RefusedFiles()

    private final class RefusedFiles: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []

        func insert(_ path: String) { lock.withLock { _ = paths.insert(path) } }
        func contains(_ path: String) -> Bool { lock.withLock { paths.contains(path) } }
    }

    // MARK: Hub cache layout

    static func folderName(_ repo: String) -> String {
        "models--" + repo.replacingOccurrences(of: "/", with: "--")
    }

    static func repoDirectory(_ repo: String, in cache: URL) -> URL {
        cache.appendingPathComponent(folderName(repo), isDirectory: true)
    }

    /// The snapshot that `refs/main` names, or any snapshot, holding every file (links resolved)
    /// that has not failed its check.
    static func snapshot(of repo: String, containing files: [String], in cache: URL) -> URL? {
        let directory = repoDirectory(repo, in: cache)
        let snapshots = directory.appendingPathComponent("snapshots", isDirectory: true)
        let manager = FileManager.default
        var candidates: [String] = []
        if let main = try? String(contentsOf: directory.appendingPathComponent("refs/main"), encoding: .utf8) {
            candidates.append(main.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        candidates += ((try? manager.contentsOfDirectory(atPath: snapshots.path)) ?? []).sorted()
        for name in candidates where !name.isEmpty && !name.hasPrefix(".") {
            let snapshot = snapshots.appendingPathComponent(name, isDirectory: true)
            let complete = files.allSatisfy { file in
                let entry = snapshot.appendingPathComponent(file)
                let size = (try? manager.attributesOfItem(atPath: entry.resolvingSymlinksInPath().path)[.size] as? NSNumber)?.int64Value ?? 0
                return size > 0 && !refused.contains(entry.path)
            }
            if complete { return snapshot }
        }
        return nil
    }

    private static func removePartialFiles(of repo: String, in cache: URL) {
        let blobs = repoDirectory(repo, in: cache).appendingPathComponent("blobs", isDirectory: true)
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: blobs.path)) ?? [] where name.hasSuffix(".incomplete") {
            try? manager.removeItem(at: blobs.appendingPathComponent(name))
        }
    }
}
