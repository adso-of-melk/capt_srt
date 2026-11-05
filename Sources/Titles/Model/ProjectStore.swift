import Foundation

/// A project opened before, listed on the home screen.
struct RecentProject: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var path: String?
    var opened: Date
    var videoCount: Int
    var languages: [String]
}

/// Reading and writing projects. Every project is saved twice: where the person keeps it
/// (which may be iCloud Drive), and as a local working copy in Application Support,
/// which iCloud never syncs or evicts. Timestamped backups are kept next to the local copy.
enum ProjectStore {
    static let fileExtension = "kptnsub"

    static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("KPTN.SUB", isDirectory: true)
    }

    /// Default home for new projects: outside iCloud's Desktop & Documents sync.
    static var defaultProjectsFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("KPTN.SUB", isDirectory: true)
    }

    static func localCopyURL(_ id: UUID) -> URL {
        supportFolder.appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).\(fileExtension)")
    }

    static func backupFolder(_ id: UUID) -> URL {
        supportFolder.appendingPathComponent("Backups/\(id.uuidString)", isDirectory: true)
    }

    // MARK: Encoding

    static func encode(_ file: ProjectFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    static func decode(_ data: Data) throws -> ProjectFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectFile.self, from: data)
    }

    // MARK: Local copy and backups (always on this Mac, so fast and safe on the main thread)

    static func writeLocalCopy(_ data: Data, id: UUID) throws {
        let url = localCopyURL(id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func readLocalCopy(_ id: UUID) -> ProjectFile? {
        guard let data = try? Data(contentsOf: localCopyURL(id)) else { return nil }
        return try? decode(data)
    }

    /// Keeps the newest 30 backups per project.
    static func writeBackup(_ data: Data, id: UUID) {
        let folder = backupFolder(id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? data.write(to: folder.appendingPathComponent("\(stamp).\(fileExtension)"), options: .atomic)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let sorted = files.filter { $0.pathExtension == fileExtension }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in sorted.dropFirst(30) { try? FileManager.default.removeItem(at: old) }
    }

    // MARK: iCloud

    /// True when the file is an iCloud placeholder whose contents aren't on this Mac.
    /// Uses only `lstat`, which never waits on iCloud (unlike resource values or reading).
    nonisolated static func isDataless(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_flags & 0x4000_0000) != 0   // SF_DATALESS
    }

    /// True when a file at `url` is inside iCloud Drive (including Desktop & Documents sync).
    nonisolated static func isInICloud(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/Library/Mobile Documents")
            || path.contains("/com~apple~CloudDocs")
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    }
}
