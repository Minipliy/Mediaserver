import Foundation

/// Songs around the current one as files, so skipping in either direction
/// starts at once instead of waiting for a stream. Kept in the caches directory:
/// iOS may purge it, the songs then simply stream again.
@MainActor
final class StreamCache {
    static let shared = StreamCache()
    private static let budget: Int64 = 1_024 * 1_024 * 1_024
    private static let largestFile: UInt64 = 200 * 1_024 * 1_024
    private static let parallelDownloads = 3

    private var running: [String: Task<Void, Never>] = [:]
    private var wanted: [Media] = []
    private var keep: Set<String> = []
    private var failed: Set<String> = []
    private var lastPlan = ""
    private var api: API?
    private var scope = ""

    private init() {}

    private static func directory(scope: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamCache/\(scope)", isDirectory: true)
    }

    /// The date keeps a replaced file on the server from playing its old copy.
    private static func fileURL(_ media: Media, scope: String) -> URL {
        let suffix = media.playback?.fileExtension ?? (media.name as NSString).pathExtension
        return directory(scope: scope).appendingPathComponent("\(media.id)-\(media.modified).\(suffix)")
    }

    /// The finished file of this song, if there is one.
    func file(for media: Media, scope: String) -> URL? {
        guard media.kind == "audio" else { return nil }
        let url = Self.fileURL(media, scope: scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Returns whether a copy existed, so that a failed start can try the stream.
    @discardableResult
    func remove(_ media: Media, scope: String) -> Bool {
        let url = Self.fileURL(media, scope: scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        failed.insert(media.id)
        return true
    }

    /// Load `wanted` in this order and spare `keep` when space runs out.
    func update(wanted: [Media], keep: [Media], api: API, scope: String) {
        let plan = scope + "|" + wanted.map(\.id).joined(separator: ",") + "|" + keep.map(\.id).joined(separator: ",")
        guard plan != lastPlan else { return }
        lastPlan = plan
        // A lost connection must not rule a song out for good.
        failed = []
        self.wanted = wanted
        self.keep = Set(keep.map(\.id))
        self.api = api
        self.scope = scope
        pump()
    }

    /// The network allows no loading right now; what is there stays.
    func pause() {
        lastPlan = ""
        wanted = []
        pump()
    }

    func clear(scope: String) {
        pause()
        try? FileManager.default.removeItem(at: Self.directory(scope: scope))
        failed = []
        api = nil
    }

    private func pump() {
        let ids = Set(wanted.map(\.id))
        for (id, task) in running where !ids.contains(id) {
            task.cancel()
            running[id] = nil
        }
        guard let api else { return }
        for media in wanted where running.count < Self.parallelDownloads {
            guard running[media.id] == nil, !failed.contains(media.id),
                  (media.playback?.bytes ?? media.bytes) <= Self.largestFile,
                  !FileManager.default.fileExists(atPath: Self.fileURL(media, scope: scope).path),
                  let request = try? api.downloadRequest(media, allowsCellular: true) else { continue }
            let target = Self.fileURL(media, scope: scope)
            running[media.id] = Task { [weak self] in
                await self?.load(request, media: media, to: target, api: api)
            }
        }
    }

    private func load(_ request: URLRequest, media: Media, to target: URL, api: API) async {
        do {
            let downloaded = try await api.downloadFile(request)
            defer { try? FileManager.default.removeItem(at: downloaded) }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: downloaded, to: target)
            evict()
        } catch {
            if !Task.isCancelled { failed.insert(media.id) }
        }
        if !Task.isCancelled { running[media.id] = nil }
        pump()
    }

    /// Oldest first, never what is needed around the current song.
    private func evict() {
        let files = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? files.contentsOfDirectory(at: Self.directory(scope: scope), includingPropertiesForKeys: Array(keys)) else { return }
        let entries = urls.compactMap { url -> (url: URL, date: Date, size: Int64)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, Int64(values.fileSize ?? 0))
        }.sorted { $0.date < $1.date }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries where total > Self.budget {
            let id = entry.url.lastPathComponent.split(separator: "-").first.map(String.init) ?? ""
            if keep.contains(id) { continue }
            try? files.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
