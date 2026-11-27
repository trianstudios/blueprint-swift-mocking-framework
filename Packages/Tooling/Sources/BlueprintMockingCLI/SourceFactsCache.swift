import Foundation
#if os(macOS) && canImport(CryptoKit) && canImport(MachO)
import CryptoKit
import Darwin
import MachO
#endif

/// The only persisted fact is that a valid source has no declarations used by the index.
final class SourceFactsCache {
    struct Source {
        let text: String
        let digest: String
    }

    #if os(macOS) && canImport(CryptoKit) && canImport(MachO)
    private struct Record: Codable {
        let schema: Int
        let profile: String
        let noIndexableSources: [String]
        let checksum: String
    }

    private static let recordName = "no-indexable-source-facts-v1.json"
    private static let maximumRecordBytes = 32_768
    private static let maximumSourceBytes = 4 * 1_048_576
    private static let maximumEntries = 256

    private let directory: URL
    private let profile: String
    private var persisted: Set<String> = []
    private var pending: Set<String> = []
    #endif

    init?(directory: URL) {
        #if os(macOS) && canImport(CryptoKit) && canImport(MachO)
        guard let profile = Self.loadedParserProfile() else { return nil }
        self.directory = directory
        self.profile = profile
        let descriptor = privateDirectory()
        if descriptor >= 0 {
            defer { _ = close(descriptor) }
            persisted = readRecord(in: descriptor)
        }
        #else
        return nil
        #endif
    }

    func readSource(at path: String) -> Source? {
        #if os(macOS) && canImport(CryptoKit) && canImport(MachO)
        // Open the authored spelling. Lexically collapsing '..' can change a symlink traversal.
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { _ = close(descriptor) }
        guard let data = Self.boundedRead(descriptor, maximum: Self.maximumSourceBytes),
              !data.starts(with: [0xef, 0xbb, 0xbf]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Source(text: text, digest: Self.sha(data))
        #else
        return nil
        #endif
    }

    func skipsIndexing(_ source: Source) -> Bool {
        #if os(macOS) && canImport(CryptoKit) && canImport(MachO)
        persisted.contains(source.digest) || pending.contains(source.digest)
        #else
        false
        #endif
    }

    func rememberNoIndexableDeclarations(_ source: Source) {
        #if os(macOS) && canImport(CryptoKit) && canImport(MachO)
        if pending.count < Self.maximumEntries { pending.insert(source.digest) }
        #endif
    }

    /// Cache I/O is opportunistic. Generation already succeeded with the current inputs.
    func commit() {
        #if os(macOS) && canImport(CryptoKit) && canImport(MachO)
        guard !pending.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let descriptor = privateDirectory()
        guard descriptor >= 0 else { return }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        let previous = readRecord(in: descriptor)
        let current = Array(previous.union(pending).sorted().prefix(Self.maximumEntries))
        guard Set(current) != previous else { return }
        let record = Record(schema: 1, profile: profile, noIndexableSources: current, checksum: checksum(current))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        let temporary = ".source-facts-\(UUID().uuidString)"
        let output = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { return }
        defer { _ = unlinkat(descriptor, temporary, 0) }
        let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            _ = renameat(descriptor, temporary, descriptor, Self.recordName)
        } catch {
            return
        }
        #endif
    }

    #if os(macOS) && canImport(CryptoKit) && canImport(MachO)
    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadedParserProfile() -> String? {
        guard let executable = Bundle.main.executableURL,
              let executableBytes = try? Data(contentsOf: executable, options: .mappedIfSafe) else { return nil }
        let required = ["libSwiftParser.dylib", "libSwiftSyntax.dylib"]
        var images: [String: [URL]] = [:]
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let image = URL(fileURLWithPath: String(cString: name))
            if required.contains(image.lastPathComponent) {
                images[image.lastPathComponent, default: []].append(image)
            }
        }
        var identities = ["source-facts-schema-1", ProcessInfo.processInfo.operatingSystemVersionString,
                          sha(executableBytes)]
        for name in required {
            guard let loaded = images[name], loaded.count == 1,
                  let data = try? Data(contentsOf: loaded[0], options: .mappedIfSafe) else { return nil }
            identities.append(sha(data))
        }
        return sha(Data(identities.joined(separator: "\n").utf8))
    }

    private func privateDirectory() -> Int32 {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        var details = stat()
        guard fstat(descriptor, &details) == 0, details.st_uid == geteuid(),
              details.st_mode & 0o077 == 0 else {
            _ = close(descriptor)
            return -1
        }
        return descriptor
    }

    private func checksum(_ sources: [String]) -> String {
        Self.sha(Data(([profile] + sources).joined(separator: "\n").utf8))
    }

    private func readRecord(in directory: Int32) -> Set<String> {
        let descriptor = openat(directory, Self.recordName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return [] }
        defer { _ = close(descriptor) }
        guard let data = Self.boundedRead(descriptor, maximum: Self.maximumRecordBytes, requirePrivate: true),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schema == 1, record.profile == profile,
              record.noIndexableSources.count <= Self.maximumEntries,
              record.noIndexableSources == Array(Set(record.noIndexableSources)).sorted(),
              record.noIndexableSources.allSatisfy(Self.isDigest),
              record.checksum == checksum(record.noIndexableSources) else { return [] }
        return Set(record.noIndexableSources)
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func boundedRead(_ descriptor: Int32, maximum: Int, requirePrivate: Bool = false) -> Data? {
        var details = stat()
        guard fstat(descriptor, &details) == 0, details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              details.st_size >= 0, details.st_size <= maximum else { return nil }
        if requirePrivate, details.st_uid != geteuid() || details.st_mode & 0o077 != 0 { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while data.count <= maximum {
            let remaining = maximum + 1 - data.count
            do {
                guard let chunk = try handle.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else { break }
                data.append(chunk)
            } catch {
                return nil
            }
        }
        // A read error or a concurrent truncation cannot furnish a cache fact.
        guard data.count <= maximum, data.count == details.st_size else { return nil }
        return data
    }
    #endif
}
