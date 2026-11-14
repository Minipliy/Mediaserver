// Compile with the real AppModel and Models, using deterministic service doubles.
// No Keychain, network or production downloads are touched.
import SwiftUI
import CryptoKit

@MainActor
final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
enum Keychain {
    static var value: Connection?
    static func load() -> Connection? { value }
    static func save(_ connection: Connection) throws { value = connection }
    static func delete() { value = nil }
}

@MainActor
final class API {
    static var handler: (String, String) async throws -> Data = { _, _ in throw URLError(.notConnectedToInternet) }
    let connection: Connection
    init(_ connection: Connection) { self.connection = connection }
    static func validate(address: String, token: String) throws -> Connection {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        return Connection(baseURL: url, token: token)
    }
    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await Self.handler(path, "GET")
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
    func sendAndDecode<T: Encodable, Response: Decodable>(_ path: String, method: String, value: T) async throws -> Response {
        let data = try await Self.handler(path, method)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data)
    }
    func perform(_ path: String, method: String) async throws { _ = try await Self.handler(path, method) }
    func post(_ path: String, json: Data) async throws { _ = try await Self.handler(path, "POST") }
    func subtitles(_ subtitle: SubtitleRef) async throws -> String {
        String(decoding: try await Self.handler("/v1/subtitles/" + subtitle.id, "GET"), as: UTF8.self)
    }
    func lyrics(_ media: Media) async throws -> LyricsPayload? {
        let data = try await Self.handler("/v1/lyrics/" + media.id, "GET")
        return try JSONDecoder().decode(LyricsPayload.self, from: data)
    }
    func downloadRequest(_ media: Media, allowsCellular: Bool? = nil) throws -> URLRequest {
        var request = URLRequest(url: connection.baseURL)
        request.allowsCellularAccess = allowsCellular ?? false
        return request
    }
}

/// No crash reports in this test.
final class DiagnosticsCollector {
    static let shared = DiagnosticsCollector()
    func pending() -> [URL] { [] }
    func markSent(_ file: URL) {}
}

/// No push in this test.
enum OutageAlerts {
    static var unsentToken: String? { nil }
    static let environment = "sandbox"
    static func markSent(_ token: String) {}
}

extension Notification.Name {
    static let miniplyDownloadsChanged = Notification.Name("miniplyRegressionDownloadsChanged")
}

struct DownloadJob {
    let scope: String
    let media: Media
    static func localURL(for record: OfflineRecord, in directory: URL) -> URL? { nil }
}

struct PausedDownload {
    let job: DownloadJob
    var fraction: Double
}

@MainActor
final class StreamCache {
    static let shared = StreamCache()
    func clear(scope: String) {}
}

@MainActor
final class DownloadManager {
    static let shared = DownloadManager()
    var active: [String: (job: DownloadJob, fraction: Double)] = [:]
    var paused: [String: PausedDownload] = [:]
    func pause(scope: String, id: String) async {}
    func resume(scope: String, id: String, request: URLRequest) async throws {}
    var startGate: Gate?
    var started = 0
    var lastStartedMedia: Media?
    var lastRequest: URLRequest?
    func restore() {}
    func start(media: Media, scope: String, request: URLRequest, shouldStart: @MainActor () -> Bool = { true }) async throws {
        if let startGate { await startGate.wait() }
        guard shouldStart(), !Task.isCancelled else { throw CancellationError() }
        started += 1
        lastStartedMedia = media
        lastRequest = request
    }
    var cancelled: [String] = []
    func cancel(scope: String, id: String) async { cancelled.append(id) }
    func cancelAll(scope: String) async {}
    func takeFailure(scope: String) -> String? { nil }
    func resumeInterrupted(scope: String, request: (Media) throws -> URLRequest) async {}
}

@MainActor
enum AppModelPersistenceCheck {
    /// The same connection in a new model, as after an app restart.
    static func reload(_ model: AppModel) -> Bool {
        Keychain.value = model.connection
        return AppModel().autoDownloads == model.autoDownloads
    }
}

private struct PlaylistWire: Encodable {
    let id: String
    let name: String
    let media_ids: [String]
}

private struct TestLibrary: Encodable {
    let items: [Media]
    var total: Int { items.count }
    let scanErrors = 0
    enum CodingKeys: String, CodingKey { case items, total, scanErrors }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encode(total, forKey: .total)
        try container.encode(scanErrors, forKey: .scanErrors)
    }
}

final class Counter: @unchecked Sendable {
    var value = 0
}

@main
struct AppModelRegression {
    @MainActor
    static func main() async throws {
        var failures = 0
        var checks = 0
        var directories: [URL] = []
        defer { for directory in directories { try? FileManager.default.removeItem(at: directory) } }
        func expect(_ condition: Bool, _ description: String) {
            checks += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(description)")
        }
        func encode<T: Encodable>(_ value: T) throws -> Data {
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
            return try encoder.encode(value)
        }
        func media(_ digit: Character, title: String) -> Media {
            let id = String(repeating: String(digit), count: 64)
            return Media(id: id, path: title + ".m4a", name: title + ".m4a", kind: "audio", title: title,
                         artist: "Test", album: "Test", duration: 60, bytes: 5, modified: 1)
        }
        let first = media("a", title: "Original")
        let second = media("b", title: "Aktuell")
        let original = Playlist(id: UUID().uuidString, name: "Original", mediaIds: [first.id])
        let saved = Playlist(id: UUID().uuidString, name: "Gespeichert", mediaIds: [second.id])
        let storage = Data(#"{"total_bytes":1000,"available_bytes":900,"indexed_bytes":5,"file_count":1,"scan_errors":0}"#.utf8)
        let library = try encode(TestLibrary(items: [first]))
        let newLibrary = try encode(TestLibrary(items: [second]))
        let playlists = try encode([original])
        let savedPlaylist = try encode(saved)
        func baseline(_ path: String, _ method: String) throws -> Data {
            switch path {
            case "/v1/library": return library
            case "/v1/playlists": return method == "GET" ? playlists : savedPlaylist
            case "/v1/storage": return storage
            default: return Data()
            }
        }
        func makeModel(connected: Bool = true) -> (AppModel, URL, Connection) {
            let connection = Connection(baseURL: URL(string: "https://\(UUID().uuidString.lowercased()).invalid")!, token: String(repeating: "x", count: 32))
            Keychain.value = connected ? connection : nil
            let address = connection.baseURL.absoluteString
            let scope = SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Miniply/\(scope)", isDirectory: true)
            directories.append(directory)
            return (AppModel(), directory, connection)
        }

        API.handler = { try baseline($0, $1) }
        let (model, cacheDirectory, connection) = makeModel()
        await model.refresh()
        expect(model.items == [first] && model.mediaByID[first.id] == first, "Refresh updates library and ID lookup")
        expect(model.playlists.map(\.id) == [original.id] && model.lastRefresh != nil, "Refresh loads playlists and timestamp")
        expect(FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent("library.json").path), "Refresh persists a local snapshot")
        Keychain.value = connection
        let restored = AppModel()
        expect(restored.items == [first] && restored.playlists.map(\.id) == [original.id], "Restart restores library and playlists together")
        API.handler = { _, _ in throw URLError(.notConnectedToInternet) }
        await restored.refresh()
        expect(restored.isOffline && restored.error == nil && restored.notice != nil, "Cached content stays accessible after network failure")
        expect(restored.serverStatus == .unreachable, "Status separates an unreachable server from missing internet")
        API.handler = { _, _ in throw MiniplyError.server(502) }
        await restored.refresh()
        expect(restored.isOffline && restored.error == nil && restored.serverStatus == .homeServerDown, "Gateway error shows the media server behind it is down")
        API.handler = { _, _ in throw MiniplyError.server(500) }
        await restored.refresh()
        expect(!restored.isOffline && restored.serverStatus == .storageProblem, "Internal server error points to the server")
        restored.error = nil
        var noNetwork = NetworkState(); noNetwork.online = false
        restored.networkChanged(noNetwork)
        expect(restored.isOffline && restored.serverStatus == .noInternet, "Losing the network updates the status at once")
        expect(restored.mediaByID[first.id] != nil, "Without a connection the remembered library stays visible")
        // A download asked for without a connection waits and starts on Wi-Fi.
        let startedOffline = DownloadManager.shared.started
        await restored.download(first)
        expect(restored.isWaiting(first) && DownloadManager.shared.started == startedOffline, "Download without a connection is remembered")
        await restored.download(first)
        expect(restored.waitingDownloads.count == 1, "Remembered once")
        API.handler = { try baseline($0, $1) }
        restored.networkChanged(NetworkState())
        await restored.refresh()
        expect(!restored.isOffline && restored.waitingDownloads.isEmpty && DownloadManager.shared.started == startedOffline + 1,
               "Remembered download starts once Wi-Fi and the server are back")
        restored.networkChanged(noNetwork)
        let suite = UserDefaults(suiteName: "quality-\(UUID().uuidString)")!
        suite.set("original", forKey: StreamPolicy.wifiQualityKey)
        expect(StreamPolicy.prefersOriginal(NetworkState(), defaults: suite)
               && !StreamPolicy.prefersOriginal(NetworkState(constrained: true), defaults: suite)
               && !StreamPolicy.prefersOriginal(NetworkState(expensive: true), defaults: suite),
               "Original applies to its own network and gives way to Low Data Mode")
        API.handler = { _, _ in throw URLError(.notConnectedToInternet) }
        await restored.refresh()
        expect(restored.serverStatus == .noInternet, "Failed refresh without network reports missing internet")
        var refreshes = 0
        API.handler = { _, _ in refreshes += 1; throw URLError(.notConnectedToInternet) }
        restored.networkChanged(NetworkState())
        while refreshes == 0 || restored.loading { await Task.yield() }
        expect(refreshes > 0, "Returning network reloads the library")
        API.handler = { _, _ in throw MiniplyError.unauthorized }
        await restored.refresh()
        expect(!restored.isOffline && restored.error != nil && restored.notice == nil, "Authentication failure is shown instead of hidden as offline mode")
        restored.error = nil
        API.handler = { _, _ in throw URLError(.serverCertificateUntrusted) }
        await restored.refresh()
        expect(!restored.isOffline && restored.error != nil, "Certificate failure remains visible with cached content")

        let (grouping, _, _) = makeModel()
        func file(_ digit: Character, _ path: String, kind: String, track: Int? = nil, albumKey: String? = nil,
                  series: String? = nil, folder: String? = nil, season: Int? = nil, episode: Int? = nil) -> Media {
            let name = (path as NSString).lastPathComponent
            return Media(id: String(repeating: String(digit), count: 64), path: path, name: name, kind: kind,
                         title: (name as NSString).deletingPathExtension, artist: kind == "audio" ? "Band" : nil,
                         album: albumKey.map { ($0 as NSString).lastPathComponent }, duration: 60, bytes: 1, modified: 1,
                         albumKey: albumKey, trackNumber: track, seriesKey: series, seasonFolder: folder, season: season, episode: episode)
        }
        let show = "Serien/Two and a Half Men"
        var withGuest = media("c", title: "Mit Gast")
        withGuest.featured = ["Gast"]
        grouping.items = [withGuest]
        expect(grouping.artists == ["Test"], "Artists list only those with songs of their own, not guests")
        grouping.items = [
            file("1", "Musik/Band/Album/02 Zwei.m4a", kind: "audio", track: 2, albumKey: "Musik/Band/Album"),
            file("2", "Musik/Band/Album/01 Eins.m4a", kind: "audio", track: 1, albumKey: "Musik/Band/Album"),
            file("3", "Musik/Band/Andere/01 Drei.m4a", kind: "audio", track: 1, albumKey: "Musik/Band/Andere"),
            file("4", show + "/Season 12/S12E01.mp4", kind: "video", series: show, folder: "Season 12", season: 12, episode: 1),
            file("5", show + "/Season 4/S04E02.mp4", kind: "video", series: show, folder: "Season 4", season: 4, episode: 2),
            file("6", show + "/Season 4/S04E01.mp4", kind: "video", series: show, folder: "Season 4", season: 4, episode: 1),
            file("7", show + "/Season 1/S01E01.mp4", kind: "video", series: show, folder: "Season 1", season: 1, episode: 1),
        ]
        expect(grouping.albums.map(\.title) == ["Album", "Andere"], "Every music folder becomes its own album")
        expect(grouping.albums.first?.tracks.map(\.trackNumber) == [1, 2], "Album tracks follow their track numbers")
        expect(grouping.seriesGroups.first?.seasons.map(\.number) == [1, 4, 12], "Seasons sort numerically, not alphabetically")
        expect(grouping.seriesGroups.first?.seasons[1].episodes.map(\.episode) == [1, 2], "Episodes sort by episode number")
        grouping.metadata = LibraryMetadata(covers: [CoverEntry(directory: "Musik/Band/Andere", artwork: "web-0123456789abcdef0123456789abcdef")])
        expect(grouping.albums.last?.coverId == "web-0123456789abcdef0123456789abcdef", "Folder cover from metadata is used for the album")

        let gate = Gate()
        var libraryCalls = 0
        API.handler = { path, method in
            if path == "/v1/library" {
                libraryCalls += 1
                if libraryCalls == 1 { await gate.wait(); return library }
                return newLibrary
            }
            return try baseline(path, method)
        }
        let (overlapping, _, _) = makeModel()
        let oldRefresh = Task { await overlapping.refresh() }
        await gate.waitUntilEntered()
        await overlapping.refresh()
        expect(overlapping.items == [second] && overlapping.loading, "Latest refresh wins while an older request remains pending")
        gate.release(); await oldRefresh.value
        expect(overlapping.items == [second] && !overlapping.loading, "Late response cannot overwrite latest refresh or leave loading active")

        let disconnectGate = Gate()
        API.handler = { path, method in
            if path == "/v1/library" { await disconnectGate.wait(); return library }
            return try baseline(path, method)
        }
        let (disconnected, _, _) = makeModel()
        let pendingRefresh = Task { await disconnected.refresh() }
        await disconnectGate.waitUntilEntered()
        disconnected.disconnect(); disconnectGate.release(); await pendingRefresh.value
        expect(disconnected.connection == nil && disconnected.items.isEmpty && disconnected.error == nil && !disconnected.loading,
               "Disconnect rejects a pending library response")

        let connectGate = Gate()
        API.handler = { path, method in
            if path == "/v1/storage" { await connectGate.wait(); return storage }
            return try baseline(path, method)
        }
        let (connecting, _, candidate) = makeModel(connected: false)
        let pendingConnect = Task { await connecting.connect(address: candidate.baseURL.absoluteString, token: candidate.token) }
        await connectGate.waitUntilEntered()
        connecting.disconnect(); connectGate.release(); await pendingConnect.value
        expect(connecting.connection == nil && Keychain.value == nil && !connecting.loading, "Disconnect cancels pending connection and credential save")

        var writes = 0
        API.handler = { path, method in
            if path == "/v1/playlists" && method == "POST" { writes += 1; return savedPlaylist }
            throw URLError(.notConnectedToInternet)
        }
        let (creating, _, creatingConnection) = makeModel()
        let created = await creating.savePlaylist(name: saved.name, ids: saved.mediaIds)
        expect(created && writes == 1 && creating.playlists.map(\.id) == [saved.id], "Create uses returned playlist without requiring a second network request")
        Keychain.value = creatingConnection
        expect(AppModel().playlists.map(\.id) == [saved.id], "New playlist survives offline restart immediately after creation")

        API.handler = { try baseline($0, $1) }
        let (editing, _, _) = makeModel()
        await editing.refresh()
        let playlistGate = Gate()
        API.handler = { path, method in
            if path == "/v1/playlists" && method == "GET" { await playlistGate.wait(); return playlists }
            return try baseline(path, method)
        }
        let stalePlaylists = Task { await editing.refresh() }
        await playlistGate.waitUntilEntered()
        let editSucceeded = await editing.savePlaylist(name: saved.name, ids: saved.mediaIds)
        playlistGate.release(); await stalePlaylists.value
        expect(editSucceeded && editing.playlists.contains(where: { $0.id == saved.id }), "Refresh cannot overwrite a concurrent playlist save")

        let mutationGate = Gate()
        API.handler = { _, _ in await mutationGate.wait(); return savedPlaylist }
        let (lateMutation, _, _) = makeModel()
        let mutation = Task { await lateMutation.savePlaylist(name: saved.name, ids: saved.mediaIds) }
        await mutationGate.waitUntilEntered()
        lateMutation.disconnect(); mutationGate.release()
        let mutationSucceeded = await mutation.value
        expect(!mutationSucceeded && lateMutation.playlists.isEmpty && lateMutation.error == nil, "Late playlist save cannot repopulate a disconnected app")

        let downloadGate = Gate()
        let startedEarlier = DownloadManager.shared.started
        DownloadManager.shared.startGate = downloadGate
        let (downloading, _, _) = makeModel()
        let pendingDownload = Task { await downloading.download(first) }
        await downloadGate.waitUntilEntered()
        downloading.disconnect(); downloadGate.release(); await pendingDownload.value
        expect(DownloadManager.shared.started == startedEarlier && downloading.error == nil, "Pending download cannot start after disconnect")
        DownloadManager.shared.startGate = nil

        var prepared = first
        prepared.playback = PlaybackVariant(fileExtension: "m4a", bytes: 123)
        let (preparedModel, _, _) = makeModel()
        await preparedModel.download(prepared)
        let downloaded = DownloadManager.shared.lastStartedMedia
        expect(downloaded?.id == first.id && downloaded?.name.hasSuffix(".m4a") == true && downloaded?.bytes == 123
               && downloaded?.playback == nil, "Download receives the prepared filename and byte count, preserving original media identity")

        // Lyrics come along with a download and stay after a restart.
        let (lyricsModel, lyricsDirectory, _) = makeModel()
        let lyricsRequests = Counter()
        let before = API.handler
        API.handler = { path, method in
            guard path.hasPrefix("/v1/lyrics/") else { return try await before(path, method) }
            lyricsRequests.value += 1
            return Data(#"{"plain":"la la","source":"genius"}"#.utf8)
        }
        await lyricsModel.download(first)
        try await Task.sleep(for: .milliseconds(100))
        let lyricsFile = lyricsDirectory.appendingPathComponent(first.id + ".lyrics.json")
        expect(FileManager.default.fileExists(atPath: lyricsFile.path), "A downloaded song keeps its lyrics on the device")
        expect(lyricsModel.availableLyrics(first)?.plain == "la la", "Lyrics are there without asking again")
        lyricsRequests.value = 0
        _ = try await lyricsModel.lyrics(for: first)
        expect(lyricsRequests.value == 0, "The server is asked once")
        let restartedLyrics = AppModel()
        expect(restartedLyrics.availableLyrics(first)?.plain == "la la", "Saved lyrics survive a restart without a request")
        API.handler = before

        // Subtitles too.
        let (subtitleModel, subtitleDirectory, _) = makeModel()
        let englisch = SubtitleRef(id: String(repeating: "c", count: 64), language: "en", label: "Englisch")
        var film = Media(id: String(repeating: "d", count: 64), path: "Filme/Film.mp4", name: "Film.mp4", kind: "video", title: "Film",
                         artist: nil, album: nil, duration: nil, bytes: 1, modified: 1)
        film.subtitles = [englisch]
        API.handler = { path, method in
            guard path.hasPrefix("/v1/subtitles/") else { return try await before(path, method) }
            return Data("WEBVTT".utf8)
        }
        await subtitleModel.download(film)
        try await Task.sleep(for: .milliseconds(100))
        expect(subtitleModel.savedSubtitle(englisch) == "WEBVTT"
               && FileManager.default.fileExists(atPath: subtitleDirectory.appendingPathComponent(englisch.id + ".subtitle.vtt").path),
               "A downloaded film keeps its subtitles for offline")
        API.handler = before

        // Automatic downloads.
        func track(_ name: String) -> Media {
            Media(id: String(repeating: name, count: 64), path: "Musik/\(name).mp3", name: "\(name).mp3", kind: "audio", title: name,
                  artist: nil, album: nil, duration: nil, bytes: 1, modified: 1)
        }
        let (a, b, c, d, e) = (track("a"), track("b"), track("c"), track("d"), track("e"))
        let catalog = Dictionary(uniqueKeysWithValues: [a, b, c, d, e].map { ($0.id, $0) })
        let list = Playlist(id: "list", name: "Liste", mediaIds: [a.id, b.id, "fehlt"])
        let marked = SeriesGroup(id: "show", name: "Serie", seasons: [
            Season(id: "s1", title: "1", number: 1, episodes: [a, c]),
            Season(id: "s2", title: "2", number: 2, episodes: [d, e])
        ], coverId: nil)
        var settings = AutoDownloadSettings()
        expect(settings.isEmpty && settings.wanted(playlists: [list], seriesGroups: [marked], library: catalog, watched: []).isEmpty,
               "Nothing is wanted unless marked")
        settings.playlists = ["list"]
        expect(settings.wanted(playlists: [list], seriesGroups: [marked], library: catalog, watched: []).map(\.id) == [a.id, b.id],
               "Marked playlist wants its existing titles")
        settings = AutoDownloadSettings(series: ["show"])
        expect(settings.wanted(playlists: [], seriesGroups: [marked], library: catalog, watched: [a.id]).map(\.id) == [c.id, d.id, e.id],
               "Marked series wants the next three unwatched episodes")
        settings.playlists = ["list"]; settings.skipped = [b.id, c.id]
        expect(settings.wanted(playlists: [list], seriesGroups: [marked], library: catalog, watched: []).map(\.id) == [a.id, d.id, e.id],
               "Skipped files stay away and duplicates count once")

        let (automatic, _, _) = makeModel()
        API.handler = { path, _ in
            if path == "/v1/library" { return try JSONEncoder().encode(TestLibrary(items: [a, b])) }
            if path == "/v1/playlists" { return try JSONEncoder().encode([PlaylistWire(id: "list", name: "Liste", media_ids: [a.id, b.id])]) }
            if path == "/v1/storage" { return Data(#"{"total_bytes":1,"available_bytes":1,"indexed_bytes":1,"file_count":2,"scan_errors":0}"#.utf8) }
            throw URLError(.fileDoesNotExist)
        }
        await automatic.refresh()
        let startedBefore = DownloadManager.shared.started
        automatic.setAutoDownload(playlist: automatic.playlists[0], true)
        for _ in 0..<1000 where DownloadManager.shared.started < startedBefore + 2 { await Task.yield() }
        expect(DownloadManager.shared.started == startedBefore + 2 && automatic.isAutoDownloading(playlist: automatic.playlists[0]),
               "Marking a playlist starts its missing titles")
        expect(DownloadManager.shared.lastRequest?.allowsCellularAccess == false, "Automatic downloads stay on Wi-Fi by default")
        var mobile = NetworkState(); mobile.expensive = true
        automatic.networkChanged(mobile)
        let startedOnWifi = DownloadManager.shared.started
        await automatic.cancelDownload(a)
        await automatic.runAutoDownloads()
        expect(DownloadManager.shared.started == startedOnWifi, "Mobile data starts nothing while Wi-Fi only is set")
        expect(automatic.autoDownloads.skipped.contains(a.id), "A cancelled file is not fetched again by itself")
        automatic.networkChanged(NetworkState())
        expect(AppModelPersistenceCheck.reload(automatic), "Marked playlists survive a restart")

        // Watched on the iPad or in the browser while this iPhone still loads it.
        let (watchedModel, _, _) = makeModel()
        let episode = Media(id: String(repeating: "f", count: 64), path: "Serien/Serie/Season 1/Folge 1.mp4", name: "Folge 1.mp4", kind: "video",
                            title: "Folge 1", artist: nil, album: nil, duration: nil, bytes: 1, modified: 1)
        let tune = track("g")
        API.handler = { path, _ in
            if path == "/v1/library" { return try JSONEncoder().encode(TestLibrary(items: [episode, tune])) }
            if path == "/v1/playlists" { return Data("[]".utf8) }
            if path == "/v1/storage" { return Data(#"{"total_bytes":1,"available_bytes":1,"indexed_bytes":1,"file_count":2,"scan_errors":0}"#.utf8) }
            throw URLError(.fileDoesNotExist)
        }
        await watchedModel.refresh()
        watchedModel.downloading = [episode.id, tune.id]
        UserDefaults.standard.set(false, forKey: AutoDownloadSettings.removeWatchedKey)
        DownloadManager.shared.cancelled = []
        watchedModel.removeWatchedDownloads(watched: [episode.id, tune.id], playing: nil)
        for _ in 0..<50 { await Task.yield() }
        expect(DownloadManager.shared.cancelled.isEmpty, "Without the setting a watched episode keeps loading")
        UserDefaults.standard.set(true, forKey: AutoDownloadSettings.removeWatchedKey)
        watchedModel.removeWatchedDownloads(watched: [episode.id, tune.id], playing: episode.id)
        for _ in 0..<50 { await Task.yield() }
        expect(DownloadManager.shared.cancelled.isEmpty, "The episode on screen keeps loading")
        watchedModel.removeWatchedDownloads(watched: [episode.id, tune.id], playing: nil)
        for _ in 0..<1000 where DownloadManager.shared.cancelled.isEmpty { await Task.yield() }
        expect(DownloadManager.shared.cancelled == [episode.id], "An episode watched elsewhere stops loading; songs are left alone")
        UserDefaults.standard.removeObject(forKey: AutoDownloadSettings.removeWatchedKey)

        let (_, legacyDirectory, legacyConnection) = makeModel()
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode([first]).write(to: legacyDirectory.appendingPathComponent("library.json"))
        Keychain.value = legacyConnection
        expect(AppModel().items == [first], "Existing library-only cache remains readable")

        func song(_ id: String, artist: String?, album: String?, track: Int? = nil, title: String? = nil, guests: [String]? = nil) -> Media {
            Media(id: id, path: id, name: id, kind: "audio", title: title ?? id, artist: artist, album: album, duration: nil,
                  bytes: 1, modified: 1, albumKey: album.map { "Musik/\($0)" }, trackNumber: track, featured: guests)
        }
        let hit = song("hit", artist: "Ada", album: "Eins", track: 2)
        let songs = [
            song("fremd", artist: "Zoe", album: "Drei", track: 1),
            song("gast", artist: "Zoe", album: "Vier", track: 1, guests: ["ada"]),
            song("anderes", artist: "Ada", album: "Zwei", track: 1),
            song("spaeter", artist: "Ada", album: "Eins", track: 3),
            song("vorher", artist: "Ada", album: "Eins", track: 1),
            song("kopie", artist: "ADA", album: "Zwei", track: 2, title: "hit"),
            hit,
            Media(id: "film", path: "film", name: "film", kind: "video", title: "film", artist: "Ada", album: nil, duration: nil, bytes: 1, modified: 1),
        ]
        expect(songs.similarSongs(to: hit).map(\.id) == ["spaeter", "vorher", "anderes", "gast"],
               "Similar songs: album from the next track, then artist, then guests; no copies, strangers or videos")
        expect(songs.similarSongs(to: hit, limit: 2).map(\.id) == ["spaeter", "vorher"], "Similar songs keep to the limit")
        let alone = song("allein", artist: nil, album: nil)
        expect((songs + [song("ohne", artist: nil, album: nil)]).similarSongs(to: alone).isEmpty,
               "Songs without artist and album are not similar to each other")
        print("\(checks - failures)/\(checks) AppModel regression checks passed")
        if failures > 0 { exit(1) }
    }
}
