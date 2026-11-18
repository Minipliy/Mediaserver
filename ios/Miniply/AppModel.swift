import SwiftUI
import CryptoKit

private struct LibraryCache: Codable {
    let items: [Media]
    let playlists: [Playlist]
    let savedAt: Date
    var metadata: LibraryMetadata? = nil
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var connection: Connection?
    @Published var items: [Media] = [] {
        didSet {
            mediaByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            rebuildGroups()
        }
    }
    private(set) var mediaByID: [String: Media] = [:]
    /// All that is known to be on the server. `items` is what the app shows:
    /// without a connection only what can actually be played, the downloads.
    private var library: [Media] = []
    /// Online information and folder covers from the server.
    @Published var metadata = LibraryMetadata() {
        didSet { rebuildMetadataIndexes(); rebuildGroups() }
    }
    @Published private(set) var albums: [Album] = []
    @Published private(set) var seriesGroups: [SeriesGroup] = []
    private(set) var coverByDirectory: [String: String] = [:]
    private(set) var albumInfoByKey: [String: AlbumInfo] = [:]
    private(set) var artistInfoByKey: [String: ArtistInfo] = [:]
    private(set) var trackInfoByKey: [String: TrackInfo] = [:]
    private(set) var seriesInfoByKey: [String: SeriesInfo] = [:]
    private(set) var movieInfoByKey: [String: MovieInfo] = [:]
    private var episodeInfoByKey: [String: EpisodeInfo] = [:]
    private(set) var thumbnailIDs: Set<String> = []
    @Published var playlists: [Playlist] = []
    @Published var storage: StorageInfo?
    @Published var offline: [OfflineRecord] = []
    @Published var downloading: Set<String> = []
    @Published var queuedDownloads: [Media] = []
    @Published private(set) var pausedDownloads: Set<String> = []
    /// Downloads asked for without a connection (or on mobile data with mobile downloads off):
    /// they start by themselves once the iPhone is on Wi-Fi and the server answers.
    @Published private(set) var waitingDownloads: [Media] = []
    @Published private(set) var autoDownloads = AutoDownloadSettings()
    /// Artists whose new releases the server loads; kept on the server for every device.
    @Published private(set) var follows: [FollowedArtist] = []
    /// The server knows about following (older servers do not).
    @Published private(set) var followsSupported = false
    /// The music service is set up, so new releases are really loaded.
    @Published private(set) var followsLoaded = false
    /// Watched episodes live in `Personal`; set by the root view.
    var watchedIDs: () -> Set<String> = { [] }
    private var autoDownloadsRunning = false
    private var downloadObserver: NSObjectProtocol?
    @Published private(set) var loading = false
    @Published private(set) var isOffline = false {
        didSet { if isOffline != oldValue { updateVisibleItems() } }
    }
    /// Result of the latest refresh, shown in the banner and status screen.
    @Published private(set) var serverStatus = ServerStatus.unknown
    private var network = NetworkState()
    @Published private(set) var lastRefresh: Date?
    @Published var error: String?
    @Published var notice: String?
    private(set) var api: API?
    private(set) var revision = UUID()
    private var refreshRevision = UUID()
    private var playlistRevision = UUID()
    private var playlistMutationInProgress = false
    private var operations: Set<UUID> = []
    private var lyricsByID: [String: LyricsPayload] = [:]
    private var lyricsRequests: [String: Task<LyricsPayload?, Error>] = [:]
    private var lyricsChecked: Set<String> = []
    private var offlineByID: [String: OfflineRecord] = [:] {
     didSet { if isOffline { updateVisibleItems() } }
 }

    init() {
        downloadObserver = NotificationCenter.default.addObserver(forName: .miniplyDownloadsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadDownloads(scanDisk: false) }
        }
        DownloadManager.shared.restore()
        connection = Keychain.load()
        if let connection {
            api = API(connection)
            loadCache()
        }
    }

    deinit {
        if let downloadObserver { NotificationCenter.default.removeObserver(downloadObserver) }
    }

    var downloadScope: String {
        let address = connection?.baseURL.absoluteString ?? "disconnected"
        return SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var offlineBytes: UInt64 {
        offline.reduce(0) { total, record in
            let sum = total.addingReportingOverflow(record.media.bytes)
            return sum.overflow ? UInt64.max : sum.partialValue
        }
    }
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Miniply/\(downloadScope)", isDirectory: true)
    }

    private func loadCache() {
        if let data = try? Data(contentsOf: directory.appendingPathComponent("library.json")) {
            if let cached = try? JSONDecoder().decode(LibraryCache.self, from: data) {
                metadata = cached.metadata ?? LibraryMetadata()
                setLibrary(cached.items); playlists = cached.playlists; lastRefresh = cached.savedAt
            } else if let legacy = try? JSONDecoder().decode([Media].self, from: data) {
                setLibrary(legacy)
            }
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("auto-downloads.json")),
           let saved = try? JSONDecoder().decode(AutoDownloadSettings.self, from: data) { autoDownloads = saved }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("waiting-downloads.json")),
           let saved = try? JSONDecoder().decode([Media].self, from: data) { waitingDownloads = saved }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("follows.json")),
           let saved = try? JSONDecoder().decode(FollowList.self, from: data) {
            follows = saved.follows; followsSupported = true; followsLoaded = saved.loading
        }
        reloadDownloads()
    }

    private func reloadDownloads(scanDisk: Bool = true) {
        guard connection != nil else { return }
        let manager = DownloadManager.shared
        let paused = manager.paused.values.filter { $0.job.scope == downloadScope }
        let tasks = manager.active.values.filter { $0.job.scope == downloadScope }.map { (job: $0.job, fraction: $0.fraction) }
            + paused.map { (job: $0.job, fraction: $0.fraction) }
        let nextIDs = Set(tasks.map { $0.job.media.id })
        let nextPaused = Set(paused.map { $0.job.media.id })
        if nextPaused != pausedDownloads { pausedDownloads = nextPaused }
        // Progress notifications must not reread every offline sidecar on each percent.
        if scanDisk || nextIDs != downloading {
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            offline = urls.filter { $0.lastPathComponent.hasSuffix(".offline.json") }.compactMap { url in
                guard let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(OfflineRecord.self, from: data),
                      url.lastPathComponent == record.id + ".offline.json",
                      DownloadJob.localURL(for: record, in: directory) != nil else { return nil }
                return record
            }.sorted { $0.media.path.localizedStandardCompare($1.media.path) == .orderedAscending }
            offlineByID = Dictionary(offline.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        }
        DownloadProgress.shared.update(Dictionary(tasks.map { ($0.job.media.id, $0.fraction) }, uniquingKeysWith: max))
        // Every published change redraws all views of the model: only when something really changed.
        if nextIDs != downloading {
            downloading = nextIDs
            queuedDownloads = tasks.map { $0.job.media }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        if let message = manager.takeFailure(scope: downloadScope) { error = message }
    }

    private func setLibrary(_ value: [Media]) {
        library = value
        updateVisibleItems()
    }

    private func updateVisibleItems() {
        // Without a connection the whole remembered library stays visible: what is not on
        // this iPhone is shown dimmed and can be marked for download on Wi-Fi.
        var next = library
        if isOffline {
            let known = Set(next.map(\.id))
            next += offline.filter { !known.contains($0.id) }.map(\.media)
        }
        if next != items { items = next }
    }

    /// Without a connection, playlists with nothing to play stay out of sight.
    var availablePlaylists: [Playlist] {
        guard isOffline else { return playlists }
        return playlists.filter { $0.mediaIds.contains { offlineByID[$0] != nil } }
    }

    private func persistCache() {
        do { try persist(LibraryCache(items: library, playlists: playlists, savedAt: lastRefresh ?? Date(), metadata: metadata), name: "library.json") }
        catch { notice = String(localized: "Die Bibliothek wurde geladen, konnte aber nicht für die Offline-Nutzung gesichert werden: \(error.localizedDescription)") }
    }

    private func persist<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    private func beginOperation() -> UUID {
        let id = UUID()
        operations.insert(id); loading = true
        return id
    }

    private func endOperation(_ id: UUID) {
        operations.remove(id); loading = !operations.isEmpty
    }

    func connect(address: String, token: String) async {
        let expected = revision
        let operation = beginOperation()
        defer { endOperation(operation) }
        error = nil
        do {
            let next = try API.validate(address: address, token: token)
            let candidate = API(next)
            let _: StorageInfo = try await candidate.get("/v1/storage")
            guard revision == expected, !Task.isCancelled else { return }
            try Keychain.save(next)
            revision = UUID()
            connection = next
            api = candidate
            setLibrary([]); playlists = []; offline = []; offlineByID = [:]; storage = nil; notice = nil
            autoDownloads = AutoDownloadSettings(); pausedDownloads = []; waitingDownloads = []
            metadata = LibraryMetadata()
            isOffline = false; lastRefresh = nil; serverStatus = .unknown
            loadCache()
            await refresh()
        } catch {
            guard revision == expected, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func disconnect() {
        let scope = downloadScope
        Task { await DownloadManager.shared.cancelAll(scope: scope) }
        StreamCache.shared.clear(scope: scope)
        revision = UUID()
        Keychain.delete()
        operations.removeAll(); loading = false; error = nil
        playlistMutationInProgress = false; playlistRevision = UUID()
        api = nil; connection = nil
        setLibrary([]); playlists = []; offline = []; offlineByID = [:]; storage = nil; downloading = []; DownloadProgress.shared.update([:]); queuedDownloads = []; notice = nil
        autoDownloads = AutoDownloadSettings(); pausedDownloads = []; waitingDownloads = []
        follows = []; followsSupported = false; followsLoaded = false
        metadata = LibraryMetadata()
        lyricsByID = [:]; lyricsRequests = [:]; lyricsChecked = []
        isOffline = false; lastRefresh = nil; serverStatus = .unknown
    }

    /// Reflect network changes at once and reload when the connection returns.
    func networkChanged(_ state: NetworkState) {
        let previous = network
        network = state
        guard connection != nil, state != previous else { return }
        if !state.online {
            isOffline = true
            serverStatus = .noInternet
        } else if !previous.online || (isOffline && state.interface != previous.interface) {
            Task { await refresh() }
        } else if state.expensive != previous.expensive || state.constrained != previous.constrained {
            Task { await startWaitingDownloads(); await runAutoDownloads() }
        }
    }

    /// Coming back to the app after a moment should not load the whole library again.
    var refreshIsDue: Bool {
        isOffline || lastRefresh.map { Date().timeIntervalSince($0) >= refreshPause } ?? true
    }
    /// On mobile data the library is asked about less often; an unchanged one
    /// then costs only a few bytes anyway.
    private var refreshPause: Double { network.expensive ? 600 : 120 }

    /// A dropped request must not leave the app offline until it is reopened:
    /// try again while it is on screen. Costs nothing once the server answers.
    func retryWhileOffline() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled, isOffline, network.online, connection != nil, error == nil { await refresh() }
        }
    }

    func refresh() async {
        guard let api else { return }
        let expected = revision
        let requestID = UUID()
        refreshRevision = requestID
        let expectedPlaylists = playlistRevision
        let operation = beginOperation()
        defer { endOperation(operation) }
        do {
            var all: [Media] = []
            var scanErrors = 0
            while true {
                let page: LibraryPage = try await api.get("/v1/library", query: [URLQueryItem(name: "offset", value: "\(all.count)"), URLQueryItem(name: "limit", value: "500")])
                guard expected == revision, requestID == refreshRevision, !Task.isCancelled else { return }
                all += page.items
                scanErrors = page.scanErrors
                if all.count >= page.total || page.items.isEmpty { break }
            }
            let lists: [Playlist] = try await api.get("/v1/playlists")
            let info: StorageInfo = try await api.get("/v1/storage")
            // Optional: older servers have no metadata route.
            let online: LibraryMetadata? = try? await api.get("/v1/metadata")
            // Optional too: only servers with following answer here.
            let followed: FollowList? = try? await api.get("/v1/music/follows")
            guard expected == revision, requestID == refreshRevision, !Task.isCancelled else { return }
            if let online { metadata = online }
            if let followed { applyFollows(followed) } else { followsSupported = false }
            setLibrary(all); storage = info
            if expectedPlaylists == playlistRevision && !playlistMutationInProgress { playlists = lists }
            isOffline = false; lastRefresh = Date()
            serverStatus = all.isEmpty ? .emptyLibrary : .ok
            notice = scanErrors > 0 ? String(localized: "Beim Scan wurden \(scanErrors) Einträge übersprungen. Details im Serverprotokoll prüfen.") : nil
            persistCache()
            await DownloadManager.shared.resumeInterrupted(scope: downloadScope) { try api.downloadRequest($0) }
            await startWaitingDownloads()
            await runAutoDownloads()
            await renewChangedDownloads()
            await sendDiagnostics()
            await registerPushDevice()
            Task {
                await keepMissingLyrics()
                await keepMissingSubtitles()
            }
        } catch {
            guard expected == revision, requestID == refreshRevision, !Task.isCancelled else { return }
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
            serverStatus = ServerStatus(failure: error, online: network.online)
            let offlineCodes: [URLError.Code] = [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                                                  .dnsLookupFailed, .networkConnectionLost, .timedOut, .dataNotAllowed]
            let networkFailure = (error as? URLError).map { offlineCodes.contains($0.code) } ?? false
            if networkFailure || serverStatus == .homeServerDown {
                isOffline = true
                if !library.isEmpty || !offline.isEmpty || !playlists.isEmpty {
                    notice = String(localized: "Server nicht erreichbar. Was auf diesem iPhone liegt, spielt; anderes kannst du für das WLAN vormerken.").forThisDevice
                } else { self.error = error.localizedDescription }
            } else { isOffline = false; notice = nil; self.error = error.localizedDescription }
        }
    }

    func rescan() async {
        guard let api else { return }
        let expected = revision
        refreshRevision = UUID()
        let operation = beginOperation()
        defer { endOperation(operation) }
        do {
            try await api.perform("/v1/scan", method: "POST")
            guard expected == revision, !Task.isCancelled else { return }
            await refresh()
        } catch {
            guard expected == revision, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func savePlaylist(name: String, ids: [String], id: String? = nil) async -> Bool {
        guard let api, !playlistMutationInProgress else { return false }
        let expected = revision
        playlistMutationInProgress = true; playlistRevision = UUID()
        defer {
            if expected == revision { playlistMutationInProgress = false; playlistRevision = UUID() }
        }
        do {
            let saved: Playlist = try await api.sendAndDecode(id.map { "/v1/playlists/\($0)" } ?? "/v1/playlists", method: id == nil ? "POST" : "PUT", value: PlaylistInput(name: name, mediaIds: ids))
            guard expected == revision else { return false }
            if let index = playlists.firstIndex(where: { $0.id == saved.id }) { playlists[index] = saved }
            else { playlists.append(saved) }
            persistCache()
            return true
        } catch {
            guard expected == revision, !Task.isCancelled else { return false }
            self.error = error.localizedDescription
            return false
        }
    }

    func deletePlaylist(_ playlist: Playlist) async {
        guard let api, !playlistMutationInProgress else { return }
        let expected = revision
        playlistMutationInProgress = true; playlistRevision = UUID()
        defer {
            if expected == revision { playlistMutationInProgress = false; playlistRevision = UUID() }
        }
        do {
            try await api.perform("/v1/playlists/\(playlist.id)", method: "DELETE")
            guard expected == revision else { return }
            playlists.removeAll { $0.id == playlist.id }
            persistCache()
            if autoDownloads.playlists.remove(playlist.id) != nil { saveAutoDownloads() }
        } catch {
            guard expected == revision, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func localURL(_ media: Media) -> URL? {
        guard let record = offlineByID[media.id] else { return nil }
        return DownloadJob.localURL(for: record, in: directory)
    }

    func download(_ media: Media) async {
        if autoDownloads.skipped.remove(media.id) != nil { saveAutoDownloads() }
        if mustWaitForWiFi {
            waitForWiFi(media)
            return
        }
        if let failure = await startDownload(media, allowsCellular: nil) { error = failure }
    }

    private var cellularDownloads: Bool { UserDefaults.standard.bool(forKey: "miniply.cellularDownloads") }

    /// No connection to the server, or mobile data while downloads may only use Wi-Fi.
    var mustWaitForWiFi: Bool {
        isOffline || !network.online || (network.expensive && !cellularDownloads)
    }

    func isWaiting(_ media: Media) -> Bool { waitingDownloads.contains { $0.id == media.id } }

    private func waitForWiFi(_ media: Media) {
        guard !isWaiting(media), localURL(media) == nil, !downloading.contains(media.id) else { return }
        waitingDownloads.append(media)
        saveWaitingDownloads()
    }

    func stopWaiting(_ media: Media) {
        waitingDownloads.removeAll { $0.id == media.id }
        saveWaitingDownloads()
    }

    private func saveWaitingDownloads() {
        try? persist(waitingDownloads, name: "waiting-downloads.json")
    }

    /// Starts what was asked for without a connection, once that is possible.
    func startWaitingDownloads() async {
        guard !waitingDownloads.isEmpty, api != nil, !mustWaitForWiFi, !network.constrained else { return }
        for waiting in waitingDownloads {
            // The current library entry: the file may have changed or be gone from the server.
            guard let media = mediaByID[waiting.id], localURL(media) == nil, !downloading.contains(media.id) else {
                stopWaiting(waiting)
                continue
            }
            if let failure = await startDownload(media, allowsCellular: nil) {
                notice = String(localized: "Vorgemerkte Downloads angehalten: \(failure)")
                return
            }
            stopWaiting(media)
        }
    }

    /// Returns the reason a download could not start.
    private func startDownload(_ media: Media, allowsCellular: Bool?, replacing: Bool = false) async -> String? {
        guard let api, !downloading.contains(media.id), replacing || localURL(media) == nil else { return nil }
        let expected = revision
        let scope = downloadScope
        do {
            downloading.insert(media.id)
            try await DownloadManager.shared.start(media: media.downloadMedia, scope: scope, request: api.downloadRequest(media, allowsCellular: allowsCellular), shouldStart: { [weak self] in self?.revision == expected })
            if expected == revision {
                reloadDownloads()
                if media.kind == "audio" { Task { await keepLyrics(media) } }
                if media.kind == "video" { Task { await keepSubtitles(media) } }
            }
            return nil
        } catch {
            guard expected == revision else { return nil }
            downloading.remove(media.id)
            return error is CancellationError ? nil : error.localizedDescription
        }
    }

    func pauseDownload(_ media: Media) async {
        await DownloadManager.shared.pause(scope: downloadScope, id: media.id)
    }

    func resumeDownload(_ media: Media) async {
        guard let api else { return }
        do { try await DownloadManager.shared.resume(scope: downloadScope, id: media.id, request: api.downloadRequest(media)) }
        catch { self.error = error.localizedDescription }
    }

    func pauseDownloads(_ list: [Media]) async {
        for media in list where downloading.contains(media.id) && !pausedDownloads.contains(media.id) { await pauseDownload(media) }
    }

    func resumeDownloads(_ list: [Media]) async {
        for media in list where pausedDownloads.contains(media.id) { await resumeDownload(media) }
    }

    // MARK: Automatic downloads

    // MARK: Following artists

    func isFollowing(_ name: String) -> Bool { follows.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    func setFollowing(_ name: String, _ on: Bool) async {
        guard let api else { return }
        do {
            let list: FollowList = try await api.sendAndDecode("/v1/music/follows", method: "POST", value: FollowChange(name: name, follow: on))
            applyFollows(list)
            if on { await runAutoDownloads() }
        } catch {
            self.error = on ? String(localized: "Folgen hat nicht geklappt: \(error.localizedDescription)")
                            : String(localized: "Entfolgen hat nicht geklappt: \(error.localizedDescription)")
        }
    }

    private func applyFollows(_ list: FollowList) {
        follows = list.follows; followsSupported = true; followsLoaded = list.loading
        try? persist(list, name: "follows.json")
    }

    /// Songs of followed artists that arrived after following, newest first.
    var newFromFollowed: [Media] {
        guard !follows.isEmpty else { return [] }
        let since = Dictionary(follows.map { ($0.name.lowercased(), $0.since) }, uniquingKeysWith: min)
        return items.filter { media in
            media.kind == "audio" && media.allArtists.contains { since[$0.lowercased()].map { media.addedAt >= $0 } ?? false }
        }
        .sorted { $0.addedAt > $1.addedAt }
    }

    /// Albums with new songs of followed artists, for the start page.
    var newAlbumsFromFollowed: [Album] {
        let fresh = newFromFollowed
        guard !fresh.isEmpty else { return [] }
        let ids = Set(fresh.map(\.id))
        return albums.filter { $0.tracks.contains { ids.contains($0.id) } }.sorted { $0.addedAt > $1.addedAt }
    }

    func isAutoDownloading(playlist: Playlist) -> Bool { autoDownloads.playlists.contains(playlist.id) }
    func isAutoDownloading(series: SeriesGroup) -> Bool { autoDownloads.series.contains(series.id) }

    func setAutoDownload(playlist: Playlist, _ enabled: Bool) {
        if enabled {
            autoDownloads.playlists.insert(playlist.id)
            autoDownloads.skipped.subtract(playlist.mediaIds)
        } else { autoDownloads.playlists.remove(playlist.id) }
        saveAutoDownloads()
        Task { await runAutoDownloads() }
    }

    func setAutoDownload(series: SeriesGroup, _ enabled: Bool) {
        if enabled {
            autoDownloads.series.insert(series.id)
            autoDownloads.skipped.subtract(series.seasons.flatMap(\.episodes).map(\.id))
        } else { autoDownloads.series.remove(series.id) }
        saveAutoDownloads()
        Task { await runAutoDownloads() }
    }

    /// Start whatever the marked playlists and series still need. Does nothing
    /// in Low Data Mode, and on mobile data unless the setting allows it.
    func runAutoDownloads() async {
        guard api != nil, !autoDownloads.isEmpty || !follows.isEmpty, !autoDownloadsRunning, network.online, !network.constrained else { return }
        let wifiOnly = UserDefaults.standard.object(forKey: AutoDownloadSettings.wifiOnlyKey) as? Bool ?? true
        if wifiOnly && network.expensive { return }
        autoDownloadsRunning = true
        defer { autoDownloadsRunning = false }
        let wanted = autoDownloads.wanted(playlists: playlists, seriesGroups: seriesGroups, library: mediaByID, watched: watchedIDs())
            + newFromFollowed.filter { !autoDownloads.skipped.contains($0.id) }
        for media in wanted where localURL(media) == nil && !downloading.contains(media.id) {
            if let failure = await startDownload(media, allowsCellular: !wifiOnly) {
                notice = String(localized: "Automatische Downloads angehalten: \(failure)")
                return
            }
        }
    }

    /// A copy on this iPhone whose file changed on the server (for example after
    /// re-downloading a song in better quality) is fetched again, on Wi-Fi only.
    /// The old copy stays playable until the new one is complete.
    func renewChangedDownloads() async {
        guard api != nil, network.online, !network.expensive, !network.constrained else { return }
        let changed = offline.filter { record in
            guard let current = mediaByID[record.id], !downloading.contains(record.id) else { return false }
            return record.media.modified != current.modified || record.media.bytes != current.downloadMedia.bytes
        }
        for record in changed {
            guard let current = mediaByID[record.id] else { continue }
            if await startDownload(current, allowsCellular: false, replacing: true) != nil { return }
        }
    }

    /// Crash reports from MetricKit go to the own server once it answers.
    func sendDiagnostics() async {
        guard let api else { return }
        for file in DiagnosticsCollector.shared.pending() {
            guard let data = try? Data(contentsOf: file) else { continue }
            do { try await api.post("/v1/diagnostics", json: data) } catch { return }
            DiagnosticsCollector.shared.markSent(file)
        }
    }

    /// Hands the push address to the server once, so its watchers can send outage warnings.
    func registerPushDevice() async {
        guard let api, let token = OutageAlerts.unsentToken,
              let body = try? JSONEncoder().encode(["token": token, "environment": OutageAlerts.environment]) else { return }
        do { try await api.post("/v1/push/devices", json: body) } catch { return }
        OutageAlerts.markSent(token)
    }

    private func saveAutoDownloads() {
        do { try persist(autoDownloads, name: "auto-downloads.json") }
        catch { notice = String(localized: "Automatische Downloads konnten nicht gespeichert werden: \(error.localizedDescription)") }
    }

    /// A file the user no longer wants must not come back by itself.
    private func skipAutomatically(_ id: String) {
        guard !autoDownloads.isEmpty, autoDownloads.skipped.insert(id).inserted else { return }
        saveAutoDownloads()
    }

    /// Download every track of an album/playlist/season that is not yet on
    /// this iPhone. Starts them one after another; iOS runs them in the background.
    func downloadAll(_ list: [Media]) async {
        for media in list where localURL(media) == nil && !downloading.contains(media.id) {
            await download(media)
        }
    }

    func cancelDownloads(_ list: [Media]) async {
        for media in list where downloading.contains(media.id) { await cancelDownload(media) }
    }

    /// With the setting on, a downloaded episode or film leaves this iPhone once it is watched,
    /// also when that happened on another device, but not while the player still shows it.
    /// What is still loading or waiting for Wi-Fi stops too; it would only arrive to be removed again.
    func removeWatchedDownloads(watched: Set<String>, playing: String?) {
        guard UserDefaults.standard.bool(forKey: AutoDownloadSettings.removeWatchedKey) else { return }
        let removed = offline.filter { $0.media.kind == "video" && watched.contains($0.id) && $0.id != playing }
        for record in removed { removeDownload(record) }
        let following = nextEpisodes(after: removed.map(\.id), watched: watched)
        if !following.isEmpty { Task { for media in following { await download(media) } } }
        let unfinished = (downloading.compactMap { mediaByID[$0] } + waitingDownloads.filter { !downloading.contains($0.id) })
            .filter { $0.kind == "video" && watched.contains($0.id) && $0.id != playing }
        if !unfinished.isEmpty { Task { for media in unfinished { await cancelDownload(media) } } }
    }

    /// For each watched episode that left this device, the next unwatched one of
    /// the same series that is not here yet: someone who had episodes 20 and 21
    /// with them and watched 20 elsewhere finds 21 and 22. Files the person
    /// removed or cancelled before stay away.
    func nextEpisodes(after removed: [String], watched: Set<String>) -> [Media] {
        var present = Set(offline.map(\.id)).union(downloading).union(waitingDownloads.map(\.id))
        var result: [Media] = []
        for id in removed {
            guard let group = seriesGroups.first(where: { $0.seasons.contains { $0.episodes.contains { $0.id == id } } }) else { continue }
            let all = group.seasons.flatMap(\.episodes)
            // After the last episode of this series still here (or the one just watched).
            guard let start = all.lastIndex(where: { present.contains($0.id) || $0.id == id }) else { continue }
            let next = all[(start + 1)...].first {
                !watched.contains($0.id) && !present.contains($0.id) && !autoDownloads.skipped.contains($0.id)
            }
            if let next {
                result.append(next)
                present.insert(next.id)
            }
        }
        return result
    }

    func removeDownloads(_ list: [Media]) {
        for media in list {
            if let record = offline.first(where: { $0.id == media.id }) { removeDownload(record) }
        }
    }

    var canDeleteFromServer: Bool { storage?.deletes == true && !isOffline }

    /// Moves the files to the trash on the server. Their copies on this iPhone
    /// go too, since they could not be played from the library any more.
    func deleteFromServer(_ list: [Media]) async -> Bool {
        guard let api, !list.isEmpty else { return false }
        do {
            let result: ServerDeleteResult = try await api.sendAndDecode(
                "/v1/media/delete", method: "POST", value: ServerDeleteRequest(ids: list.map(\.id)))
            if result.failed > 0 {
                self.error = String(localized: "\(result.failed) Dateien konnte der Server nicht löschen.")
            }
            await cancelDownloads(list)
            await refresh()
            let gone = list.filter { mediaByID[$0.id] == nil }
            removeDownloads(gone)
            return result.failed == 0
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func cancelDownload(_ media: Media) async {
        stopWaiting(media)
        skipAutomatically(media.id)
        await DownloadManager.shared.cancel(scope: downloadScope, id: media.id)
        try? FileManager.default.removeItem(at: lyricsURL(media.id))
    }

    func removeDownload(_ record: OfflineRecord) {
        skipAutomatically(record.id)
        do {
            guard let url = DownloadJob.localURL(for: record, in: directory) else {
                reloadDownloads()
                throw MiniplyError.message(String(localized: "Diese lokale Kopie ist nicht mehr vollständig vorhanden."))
            }
            try FileManager.default.removeItem(at: url)
            let metadata = directory.appendingPathComponent(record.id + ".offline.json")
            if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
            try? FileManager.default.removeItem(at: lyricsURL(record.id))
            for subtitle in (mediaByID[record.id] ?? record.media).subtitles ?? [] {
                try? FileManager.default.removeItem(at: subtitleURL(subtitle.id))
            }
            reloadDownloads()
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Lyrics

    private func lyricsURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".lyrics.json") }

    /// What is there without asking the server: already loaded, or saved with a download.
    func availableLyrics(_ media: Media) -> LyricsPayload? {
        if let known = lyricsByID[media.id] { return known }
        guard let data = try? Data(contentsOf: lyricsURL(media.id)),
              let saved = try? JSONDecoder().decode(LyricsPayload.self, from: data) else { return nil }
        lyricsByID[media.id] = saved
        return saved
    }

    /// Nil when there are no lyrics. Requests for the same song share one answer.
    func lyrics(for media: Media) async throws -> LyricsPayload? {
        if let known = availableLyrics(media) { return known }
        guard let api else { return nil }
        let request = lyricsRequests[media.id] ?? Task { try await api.lyrics(media) }
        lyricsRequests[media.id] = request
        let expected = revision
        defer { if expected == revision { lyricsRequests[media.id] = nil } }
        let payload = try await request.value
        if expected == revision { lyricsByID[media.id] = payload }
        return payload
    }

    /// Before a song plays, so that its lyrics appear at once.
    func preloadLyrics(_ list: [Media]) async {
        guard !isOffline else { return }
        for media in list where media.kind == "audio" { _ = try? await lyrics(for: media) }
    }

    private func keepLyrics(_ media: Media) async {
        let expected = revision
        guard let payload = try? await lyrics(for: media), expected == revision,
              let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: lyricsURL(media.id), options: .atomic)
    }

    /// Downloads from before lyrics came along, and those whose lyrics were not ready yet.
    /// Once per song and launch, since a song may simply have none.
    private func keepMissingLyrics() async {
        for record in offline where record.media.kind == "audio" && lyricsChecked.insert(record.id).inserted {
            if !FileManager.default.fileExists(atPath: lyricsURL(record.id).path) { await keepLyrics(record.media) }
        }
    }

    // MARK: Subtitles of downloads

    private func subtitleURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".subtitle.vtt") }

    /// A subtitle kept with a download, to be read without a connection.
    func savedSubtitle(_ subtitle: SubtitleRef) -> String? {
        try? String(contentsOf: subtitleURL(subtitle.id), encoding: .utf8)
    }

    private func keepSubtitles(_ media: Media) async {
        guard let api else { return }
        let expected = revision
        for subtitle in media.subtitles ?? [] where savedSubtitle(subtitle) == nil {
            guard let text = try? await api.subtitles(subtitle), expected == revision else { continue }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? text.write(to: subtitleURL(subtitle.id), atomically: true, encoding: .utf8)
        }
    }

    /// Subtitles can turn up on the server long after the download.
    private func keepMissingSubtitles() async {
        for record in offline where record.media.kind == "video" {
            await keepSubtitles(mediaByID[record.id] ?? record.media)
        }
    }

    // MARK: Library structure

    private func rebuildMetadataIndexes() {
        coverByDirectory = Dictionary((metadata.covers ?? []).map { ($0.directory, $0.artwork) }, uniquingKeysWith: { first, _ in first })
        albumInfoByKey = Dictionary((metadata.albums ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        artistInfoByKey = Dictionary((metadata.artists ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        trackInfoByKey = Dictionary((metadata.tracks ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        seriesInfoByKey = Dictionary((metadata.series ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        movieInfoByKey = Dictionary((metadata.movies ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var episodes: [String: EpisodeInfo] = [:]
        for series in metadata.series ?? [] {
            for episode in series.episodes ?? [] { episodes["\(series.key)|\(episode.season)|\(episode.number)"] = episode }
        }
        episodeInfoByKey = episodes
        thumbnailIDs = Set(metadata.thumbnails ?? [])
    }

    /// Generated still of a video, if the server made one.
    func thumbnailID(for media: Media) -> String? {
        thumbnailIDs.contains(media.id) ? "thumb-" + media.id : nil
    }

    private func rebuildGroups() {
        let audio = items.filter { $0.kind == "audio" }
        albums = Dictionary(grouping: audio, by: \.albumGroup).compactMap { key, tracks -> Album? in
            let sorted = tracks.sorted(by: trackOrder)
            guard let first = sorted.first else { return nil }
            var counts: [String: Int] = [:]
            for track in sorted { if let artist = track.artist { counts[artist, default: 0] += 1 } }
            let artists: String? = counts.max { $0.value < $1.value }?.key
            var cover: String? = sorted.first(where: { $0.coverId != nil })?.coverId
            if cover == nil { cover = albumInfoByKey[key]?.artwork }
            if cover == nil { cover = coverByDirectory[key] }
            return Album(id: key, title: first.album ?? String(localized: "Ohne Album"), artist: first.albumArtist ?? artists, tracks: sorted, coverId: cover)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        let episodes = items.filter { $0.kind == "video" && $0.seriesPath != nil }
        let bySeries: [String: [Media]] = Dictionary(grouping: episodes) { $0.seriesPath ?? "" }
        seriesGroups = bySeries.map { (entry: (key: String, value: [Media])) -> SeriesGroup in
            let key = entry.key
            let list = entry.value
            let bySeason: [String: [Media]] = Dictionary(grouping: list) { (media: Media) -> String in
                if let folder = media.seasonGroup { return folder }
                if let number = media.season { return String(localized: "Staffel \(number)") }
                return String(localized: "Folgen")
            }
            let seasons: [Season] = bySeason.map { (entry: (key: String, value: [Media])) -> Season in
                let title = entry.key
                let members = entry.value
                var number: Int? = members.first(where: { $0.season != nil })?.season
                if number == nil && title != String(localized: "Folgen") { number = seasonNumber(from: title) }
                return Season(id: key + "/" + title, title: displayName(title), number: number, episodes: members.sorted(by: episodeOrder))
            }.sorted { (a: Season, b: Season) -> Bool in
                switch (a.number, b.number) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
            }
            var cover: String? = coverByDirectory[key]
            if cover == nil { cover = seriesInfoByKey[key]?.poster }
            if cover == nil { cover = seasons.compactMap { coverByDirectory[$0.id] }.first }
            if cover == nil { cover = list.compactMap(\.coverId).first }
            return SeriesGroup(id: key, name: displayName((key as NSString).lastPathComponent), seasons: seasons, coverId: cover)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Best artwork for a single item: folder/embedded cover, then online art.
    func artworkID(for media: Media) -> String? {
        if let cover = media.coverId { return cover }
        switch media.kind {
        case "audio": return albumInfoByKey[media.albumGroup]?.artwork
        case "video":
            if let series = media.seriesPath {
                return media.seasonGroup.flatMap { coverByDirectory[series + "/" + $0] } ?? coverByDirectory[series] ?? seriesInfoByKey[series]?.poster
            }
            return movieInfoByKey[media.id]?.poster ?? thumbnailID(for: media)
        default: return nil
        }
    }

    func album(for media: Media) -> Album? { albums.first { $0.id == media.albumGroup } }
    func albumInfo(_ album: Album) -> AlbumInfo? { albumInfoByKey[album.id] }
    func artistInfo(_ name: String?) -> ArtistInfo? {
        guard let name else { return nil }
        return artistInfoByKey[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }
    func trackInfo(_ media: Media) -> TrackInfo? { trackInfoByKey[media.id] }
    func seriesInfo(_ series: SeriesGroup) -> SeriesInfo? { seriesInfoByKey[series.id] }
    func movieInfo(_ media: Media) -> MovieInfo? { movieInfoByKey[media.id] }
    func episodeInfo(_ media: Media) -> EpisodeInfo? {
        guard let series = media.seriesPath, let season = media.season, let episode = media.episode else { return nil }
        return episodeInfoByKey["\(series)|\(season)|\(episode)"]
    }
    func seasonCover(_ season: Season, in series: SeriesGroup) -> String? {
        coverByDirectory[season.id] ?? series.coverId
    }

    /// Locally saved playback position (written by PlayerModel).
    func resumeSeconds(_ media: Media) -> Double {
        UserDefaults.standard.double(forKey: "miniply.progress.\(downloadScope).\(media.id)")
    }

    /// Albums ordered by their newest file.
    var recentAlbums: [Album] {
        albums.sorted { ($0.tracks.map(\.addedAt).max() ?? 0) > ($1.tracks.map(\.addedAt).max() ?? 0) }
    }
    /// Newest release first; without a known date, the newest files.
    func artistAlbums(_ name: String) -> [Album] {
        let key = name.lowercased()
        let list = albums.filter { album in
            album.artist?.lowercased() == key || album.tracks.contains { $0.artist?.lowercased() == key }
        }
        func released(_ album: Album) -> String { albumInfo(album)?.releaseDate ?? albumInfo(album)?.year ?? "" }
        func added(_ album: Album) -> UInt64 { album.tracks.map(\.modified).max() ?? 0 }
        return list.sorted { released($0) == released($1) ? added($0) > added($1) : released($0) > released($1) }
    }
    /// The songs of an artist, without those where they are only a guest.
    func artistTracks(_ name: String) -> [Media] {
        let key = name.lowercased()
        return items.filter { $0.kind == "audio" && ($0.artist ?? $0.albumArtist)?.lowercased() == key }
            .sorted { ($0.album ?? "", $0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.album ?? "", $1.discNumber ?? 1, $1.trackNumber ?? 0) }
    }
    /// Songs where `name` is only a guest ("feat.").
    func featuredTracks(_ name: String) -> [Media] {
        let key = name.lowercased()
        return items.filter { $0.kind == "audio" && ($0.featured ?? []).contains { $0.lowercased() == key } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var artists: [String] {
        // Only who has songs of their own: a guest appearance is no reason for a place here.
        let names = items.filter { $0.kind == "audio" }.compactMap { $0.artist ?? $0.albumArtist }
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Playlist shortcuts

    /// Append tracks (skipping duplicates) to an existing playlist.
    @discardableResult
    func add(_ tracks: [Media], to playlist: Playlist) async -> Bool {
        var ids = playlist.mediaIds
        for track in tracks where track.kind == "audio" && !ids.contains(track.id) { ids.append(track.id) }
        guard ids != playlist.mediaIds else { notice = nil; return true }
        guard ids.count <= 500 else { error = String(localized: "Eine Playlist kann höchstens 500 Titel enthalten."); return false }
        return await savePlaylist(name: playlist.name, ids: ids, id: playlist.id)
    }

    /// Create a new playlist that already contains `tracks`.
    @discardableResult
    func createPlaylist(named name: String, with tracks: [Media]) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 200 else { error = String(localized: "Bitte einen Namen mit 1 bis 200 Zeichen eingeben."); return false }
        var ids: [String] = []
        for track in tracks where track.kind == "audio" && !ids.contains(track.id) { ids.append(track.id) }
        return await savePlaylist(name: trimmed, ids: Array(ids.prefix(500)))
    }
}
