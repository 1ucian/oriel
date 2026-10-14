import CryptoKit
import Foundation
import Testing
@testable import HermesCaptureMac

/// The Whisper files are read only when they match the hashes pinned in the model store: a good file passes, a bad
/// file of Oriel's own is deleted, and a bad file in another tool's cache is refused and left where it is.
struct WhisperModelStoreTests {
    typealias Pin = WhisperModelStore.PinnedFile

    static let revision = "0123456789abcdef0123456789abcdef01234567"
    static let good = Data((0 ..< 4_096).map { UInt8($0 % 251) })

    static func pin(_ name: String, _ data: Data = good) -> Pin {
        Pin(repo: "test/model", revision: revision, name: name, sha256: hex(SHA256.hash(data: data)), bytes: Int64(data.count))
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The same bytes with one flipped: the right size and the wrong hash.
    static var corrupted: Data {
        var data = good
        data[100] ^= 0xFF
        return data
    }

    static func isLowercaseHex(_ text: String, length: Int) -> Bool {
        text.count == length && text.allSatisfy { $0.isASCII && ($0.isNumber || ("a" ... "f").contains($0)) }
    }

    @Test func aFileThatMatchesItsPinPasses() throws {
        let cache = try TempCache()
        let weights = Self.pin("weights.npz")
        let url = try cache.oriel.install(Self.good, as: weights)
        try WhisperModelStore.verify([(url, weights)], ownedBy: cache.oriel.root)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aCorruptedFileOfOrielsOwnFailsAndItsCopyIsRemoved() throws {
        let cache = try TempCache()
        let weights = Self.pin("weights.npz")
        let url = try cache.oriel.install(Self.corrupted, as: weights)
        let blob = url.resolvingSymlinksInPath()
        #expect(FileManager.default.fileExists(atPath: blob.path))
        // The same file in another tool's cache is none of Oriel's business.
        let theirs = try cache.shared.install(Self.good, as: weights)

        #expect(throws: WhisperModelStore.Failure.failedCheck(file: "weights.npz", ownCopyRemoved: true)) {
            try WhisperModelStore.verify([(url, weights)], ownedBy: cache.oriel.root)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path), "the entry in Oriel's snapshot is gone")
        #expect(!FileManager.default.fileExists(atPath: blob.path), "so is the blob, or it would count as cached")
        #expect(FileManager.default.fileExists(atPath: theirs.path))
    }

    @Test func aFileOfTheWrongSizeFailsToo() throws {
        let cache = try TempCache()
        let weights = Self.pin("weights.npz")
        let url = try cache.oriel.install(Self.good.dropLast(), as: weights)
        #expect(throws: WhisperModelStore.Failure.failedCheck(file: "weights.npz", ownCopyRemoved: true)) {
            try WhisperModelStore.verify([(url, weights)], ownedBy: cache.oriel.root)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// The shared cache is writable here on purpose: a deletion attempt would succeed and show.
    @Test func aBadFileInTheSharedCacheIsRefusedAndLeftInPlace() throws {
        let cache = try TempCache()
        let weights = Self.pin("weights.npz")
        let url = try cache.shared.install(Self.corrupted, as: weights)
        let blob = url.resolvingSymlinksInPath()
        #expect(WhisperModelStore.snapshot(of: weights.repo, containing: [weights.name], in: cache.shared.root) != nil)

        #expect(throws: WhisperModelStore.Failure.failedCheck(file: "weights.npz", ownCopyRemoved: false)) {
            try WhisperModelStore.verify([(url, weights)], ownedBy: cache.oriel.root)
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: blob) == Self.corrupted, "not touched")
        #expect(
            WhisperModelStore.snapshot(of: weights.repo, containing: [weights.name], in: cache.shared.root) == nil,
            "the store looks past it, so the next download brings Oriel's own copy"
        )
    }

    @Test func aBadFileInAReadOnlySharedCacheIsRefusedAndLeftInPlace() throws {
        let cache = try TempCache()
        let weights = Self.pin("weights.npz")
        let url = try cache.shared.install(Self.corrupted, as: weights)
        let blob = url.resolvingSymlinksInPath()
        try cache.shared.makeReadOnly()

        #expect(throws: WhisperModelStore.Failure.failedCheck(file: "weights.npz", ownCopyRemoved: false)) {
            try WhisperModelStore.verify([(url, weights)], ownedBy: cache.oriel.root)
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: blob) == Self.corrupted)
    }

    @Test func aFileThatIsNotThereIsIncompleteNotBad() throws {
        let cache = try TempCache()
        let missing = cache.oriel.root.appendingPathComponent("nothing.npz")
        #expect(throws: WhisperModelStore.Failure.incomplete) {
            try WhisperModelStore.verify([(missing, Self.pin("weights.npz"))], ownedBy: cache.oriel.root)
        }
    }

    @Test func onlyTheBadFileOfOrielsIsDeleted() throws {
        let cache = try TempCache()
        let config = Self.pin("config.json")
        let weights = Self.pin("weights.npz")
        let badConfig = try cache.oriel.install(Self.corrupted, as: config)
        let goodWeights = try cache.oriel.install(Self.good, as: weights)
        #expect(throws: WhisperModelStore.Failure.failedCheck(file: "config.json", ownCopyRemoved: true)) {
            try WhisperModelStore.verify([(badConfig, config), (goodWeights, weights)], ownedBy: cache.oriel.root)
        }
        #expect(FileManager.default.fileExists(atPath: goodWeights.path), "only the bad file of Oriel's goes")
    }

    // MARK: The pins

    @Test func downloadsComeFromPinnedCommitsNeverABranch() {
        for fetch in [WhisperModelStore.tokenizerFetch, WhisperModelStore.weightsFetch] {
            #expect(Self.isLowercaseHex(fetch.revision, length: 40), "\(fetch.repo) at \(fetch.revision)")
            #expect(fetch.revision != "main")
        }
        #expect(WhisperModelStore.weightsFetch.revision == WhisperModelStore.modelRevision)
        #expect(WhisperModelStore.tokenizerFetch.revision == WhisperModelStore.tokenizerRevision)
    }

    @Test func everyFileTheEngineLoadsIsPinnedAtTheRevisionItIsFetchedAt() {
        let pins = [WhisperModelStore.pinnedConfig, WhisperModelStore.pinnedWeights, WhisperModelStore.pinnedVocabulary]
        #expect(Set(pins.map(\.name)) == ["config.json", "weights.npz", "vocab.json"])
        for pin in pins {
            #expect(Self.isLowercaseHex(pin.sha256, length: 64), "\(pin.name)")
            let fetch = pin.repo == WhisperModelStore.modelID ? WhisperModelStore.weightsFetch : WhisperModelStore.tokenizerFetch
            #expect(fetch.repo == pin.repo && fetch.revision == pin.revision && fetch.files.contains(pin.name))
        }
        #expect(WhisperModelStore.weightsFetch.bytes == WhisperModelStore.pinnedConfig.bytes + WhisperModelStore.pinnedWeights.bytes)
        #expect(WhisperModelStore.tokenizerFetch.bytes == WhisperModelStore.pinnedVocabulary.bytes)
    }

    /// The pins against the copy on this Mac (Hermes's weights, Oriel's or Hermes's tokenizer). Nothing here is
    /// owned, so a mismatch deletes nothing.
    @Test func thePinsMatchTheModelOnThisMac() throws {
        guard let directory = WhisperModelStore.installedDirectory(), let vocabulary = WhisperModelStore.vocabularyURL() else {
            #expect(!WhisperEngineTests.requireModel, "Whisper large-v3 is not on this Mac; download it from Settings, Assistant")
            return
        }
        try WhisperModelStore.verify(
            [
                (directory.appendingPathComponent("config.json"), WhisperModelStore.pinnedConfig),
                (vocabulary, WhisperModelStore.pinnedVocabulary),
                (directory.appendingPathComponent("weights.npz"), WhisperModelStore.pinnedWeights),
            ],
            ownedBy: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
    }

    /// Opt in with ORIEL_NETWORK_TESTS=1: the real client fetches the tokenizer file at the pinned commit into an empty
    /// cache, and it is the file that was pinned.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORIEL_NETWORK_TESTS"] == "1"))
    func theTokenizerDownloadsAtThePinnedCommit() async throws {
        let cache = try TempCache()
        let fetch = WhisperModelStore.tokenizerFetch
        try await WhisperModelStore.fetch(fetch.repo, revision: fetch.revision, files: fetch.files, into: cache.oriel.root) { _ in }
        let snapshot = try #require(WhisperModelStore.snapshot(of: fetch.repo, containing: fetch.files, in: cache.oriel.root))
        #expect(snapshot.lastPathComponent == WhisperModelStore.tokenizerRevision)
        try WhisperModelStore.verify(
            [(snapshot.appendingPathComponent("vocab.json"), WhisperModelStore.pinnedVocabulary)],
            ownedBy: cache.oriel.root
        )
    }
}

/// Two hub-layout caches in a temporary folder, Oriel's own and another tool's.
private final class TempCache {
    let oriel: HubFolder
    let shared: HubFolder
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("oriel-model-store-\(UUID().uuidString)")
        oriel = HubFolder(root: root.appendingPathComponent("oriel"))
        shared = HubFolder(root: root.appendingPathComponent("shared"))
        try FileManager.default.createDirectory(at: oriel.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared.root, withIntermediateDirectories: true)
    }

    deinit {
        shared.makeWritable()
        try? FileManager.default.removeItem(at: root)
    }
}

private struct HubFolder {
    let root: URL

    /// `data` as the pin's file in the hub layout: a blob named by the hash of what it holds, and the snapshot entry
    /// linking to it.
    func install(_ data: some DataProtocol, as pin: WhisperModelStore.PinnedFile) throws -> URL {
        let manager = FileManager.default
        let blobName = WhisperModelStoreTests.hex(SHA256.hash(data: data))
        let repo = WhisperModelStore.repoDirectory(pin.repo, in: root)
        let blobs = repo.appendingPathComponent("blobs", isDirectory: true)
        let snapshot = repo.appendingPathComponent("snapshots/\(pin.revision)", isDirectory: true)
        try manager.createDirectory(at: blobs, withIntermediateDirectories: true)
        try manager.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data(data).write(to: blobs.appendingPathComponent(blobName))
        let entry = snapshot.appendingPathComponent(pin.name)
        try manager.createSymbolicLink(atPath: entry.path, withDestinationPath: "../../blobs/\(blobName)")
        return entry
    }

    func makeReadOnly() throws {
        try set(directories: 0o555, files: 0o444)
    }

    func makeWritable() {
        try? set(directories: 0o755, files: 0o644)
    }

    private func set(directories: Int, files: Int) throws {
        let manager = FileManager.default
        let paths = (manager.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).map { root.appendingPathComponent($0) }
        // A folder is locked after what is in it and unlocked before.
        let ordered = directories == 0o555 ? Array(paths.reversed()) + [root] : [root] + paths
        for url in ordered {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            let isLink = (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil
            if isLink { continue }
            try manager.setAttributes([.posixPermissions: isDirectory.boolValue ? directories : files], ofItemAtPath: url.path)
        }
    }
}
