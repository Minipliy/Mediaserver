import CryptoKit
import Foundation

/// Favourites, play statistics and watched episodes. Kept on this iPhone and
/// shared with other devices through the server (media IDs are hashes of the
/// server path, so they stay valid per server).
/// Shuffle and repeat chosen for one album or playlist. Kept on this device.
struct CollectionPlayback: Codable, Equatable {
    var shuffle = false
    var repeatValue = RepeatMode.off.rawValue

    var repeatMode: RepeatMode {
        get { RepeatMode(rawValue: repeatValue) ?? .off }
        set { repeatValue = newValue.rawValue }
    }

    private static func key(_ collection: String) -> String { "mediaserver.collection." + collection }

    static func load(_ collection: String, from defaults: UserDefaults = .standard) -> CollectionPlayback? {
        defaults.data(forKey: key(collection)).flatMap { try? JSONDecoder().decode(CollectionPlayback.self, from: $0) }
    }

    func save(_ collection: String, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key(collection)) }
    }
}

/// A playlist or album on the start screen.
enum MusicCollection: Identifiable, Equatable {
    case playlist(Playlist)
    case album(Album)

    var id: String {
        switch self {
        case .playlist(let playlist): "playlist:" + playlist.id
        case .album(let album): "album:" + album.id
        }
    }
    static func == (a: MusicCollection, b: MusicCollection) -> Bool { a.id == b.id }
}

@MainActor
final class Personal: ObservableObject {
    enum SyncState: Equatable { case unknown, synced(Date), unsupported, failed }

    private struct Snapshot: Codable {
        var favorites: Set<String> = []
        var playCounts: [String: Int] = [:]
        var lastPlayed: [String: Double] = [:]
        var watched: Set<String> = []
        // Optional: older snapshots do not have them.
        var favoriteFlags: [String: PersonalFlag]?
        var watchedFlags: [String: PersonalFlag]?
        var ownPlays: [String: Int]?
        var dirtyFavorites: Set<String>?
        var dirtyWatched: Set<String>?
        var dirtyPlays: Set<String>?
        var syncCursor: Int64?
        var syncServer: String?
        var lastPlaylists: [String: Double]?
        var lastAlbums: [String: Double]?
    }

    @Published private(set) var favorites: Set<String> = []
    /// Plays over all devices.
    @Published private(set) var playCounts: [String: Int] = [:]
    @Published private(set) var lastPlayed: [String: Double] = [:]
    @Published private(set) var watched: Set<String> = []
    /// Only on this device: the server does not know about playlist plays.
    @Published private(set) var lastPlaylists: [String: Double] = [:]
    @Published private(set) var lastAlbums: [String: Double] = [:]
    @Published private(set) var syncState = SyncState.unknown
    private var favoriteFlags: [String: PersonalFlag] = [:]
    private var watchedFlags: [String: PersonalFlag] = [:]
    /// Plays on this device; only these are reported as its own.
    private var ownPlays: [String: Int] = [:]
    // Changes the server has not confirmed yet, and where it left off.
    private var dirtyFavorites: Set<String> = []
    private var dirtyWatched: Set<String> = []
    private var dirtyPlays: Set<String> = []
    private var syncCursor: Int64 = 0
    private var syncServer: String?
    var pendingChanges: Int { dirtyFavorites.count + dirtyWatched.count + dirtyPlays.count }
    private static let finishedShare = 0.93
    private let key: String
    private let defaults: UserDefaults
    let device: String
    /// Set while connected; changes are then shared shortly after they happen.
    var api: API? {
        didSet { if api?.connection != oldValue?.connection { syncState = .unknown } }
    }
    private var pendingSync: Task<Void, Never>?
    private var syncing = false
    var syncDelay = 5.0

    init(defaults: UserDefaults = .standard, key: String = "mediaserver.personal.v1") {
        self.defaults = defaults
        self.key = key
        if let saved = defaults.string(forKey: key + ".device") {
            device = saved
        } else {
            device = UUID().uuidString.lowercased()
            defaults.set(device, forKey: key + ".device")
        }
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        favorites = snapshot.favorites
        playCounts = snapshot.playCounts
        lastPlayed = snapshot.lastPlayed
        watched = snapshot.watched
        // Marks from before sharing have no time: any real change wins.
        favoriteFlags = snapshot.favoriteFlags ?? Dictionary(uniqueKeysWithValues: favorites.map { ($0, PersonalFlag(id: $0, on: true, at: 0)) })
        watchedFlags = snapshot.watchedFlags ?? Dictionary(uniqueKeysWithValues: watched.map { ($0, PersonalFlag(id: $0, on: true, at: 0)) })
        ownPlays = snapshot.ownPlays ?? playCounts
        dirtyFavorites = snapshot.dirtyFavorites ?? Set(favoriteFlags.keys)
        dirtyWatched = snapshot.dirtyWatched ?? Set(watchedFlags.keys)
        dirtyPlays = snapshot.dirtyPlays ?? Set(ownPlays.keys).union(lastPlayed.keys)
        syncCursor = snapshot.syncCursor ?? 0
        syncServer = snapshot.syncServer
        lastPlaylists = snapshot.lastPlaylists ?? [:]
        lastAlbums = snapshot.lastAlbums ?? [:]
    }

    private func save(sync: Bool = true) {
        let snapshot = Snapshot(favorites: favorites, playCounts: playCounts, lastPlayed: lastPlayed, watched: watched,
                                favoriteFlags: favoriteFlags, watchedFlags: watchedFlags, ownPlays: ownPlays,
                                dirtyFavorites: dirtyFavorites, dirtyWatched: dirtyWatched, dirtyPlays: dirtyPlays,
                                syncCursor: syncCursor, syncServer: syncServer, lastPlaylists: lastPlaylists,
                                lastAlbums: lastAlbums)
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: key) }
        if sync { scheduleSync() }
    }

    // MARK: Sharing between devices

    private func scheduleSync() {
        guard api != nil, syncState != .unsupported else { return }
        pendingSync?.cancel()
        pendingSync = Task {
            try? await Task.sleep(for: .seconds(syncDelay))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    /// Send what changed and take over what changed elsewhere. Safe to repeat:
    /// changes made meanwhile stay marked, and the next sync carries them.
    func sync() async {
        guard api != nil, !syncing else { return }
        syncing = true
        defer { syncing = false }
        if await exchange() { _ = await exchange() }
        if pendingChanges > 0, case .synced = syncState { scheduleSync() }
    }

    /// True when the server lost its state and needs everything again.
    private func exchange() async -> Bool {
        guard let api else { return false }
        let server = api.connection.baseURL.absoluteString
        if syncServer != server {
            syncServer = server
            markEverythingChanged()
        }
        let sentFavorites = dirtyFavorites.compactMap { favoriteFlags[$0] }
        let sentWatched = dirtyWatched.compactMap { watchedFlags[$0] }
        let sentPlays = ownPlays
        let sentTimes = dirtyPlays.compactMap { id in lastPlayed[id].map { PersonalLastPlayed(id: id, at: $0) } }
        let sentCounts = dirtyPlays.compactMap { id in ownPlays[id].map { PersonalPlayCount(id: id, count: $0) } }
        let since = syncCursor
        let request = PersonalSyncRequest(device: device, since: since, favorites: sentFavorites, watched: sentWatched,
                                          plays: sentCounts, lastPlayed: sentTimes)
        do {
            guard let merged = try await api.syncPersonal(request) else { syncState = .unsupported; return false }
            guard api.connection == self.api?.connection else { return false }
            if merged.cursor < since {
                markEverythingChanged()
                return true
            }
            for flag in sentFavorites where favoriteFlags[flag.id] == flag { dirtyFavorites.remove(flag.id) }
            for flag in sentWatched where watchedFlags[flag.id] == flag { dirtyWatched.remove(flag.id) }
            let sentTime = Dictionary(uniqueKeysWithValues: sentTimes.map { ($0.id, $0.at) })
            for id in dirtyPlays where ownPlays[id] == sentPlays[id] && lastPlayed[id] == sentTime[id] { dirtyPlays.remove(id) }
            syncCursor = merged.cursor
            apply(merged, sentPlays: sentPlays)
            syncState = .synced(Date())
        } catch { syncState = .failed }
        return false
    }

    /// A new server, or one that lost its state, knows nothing of this device.
    private func markEverythingChanged() {
        syncCursor = 0
        dirtyFavorites = Set(favoriteFlags.keys)
        dirtyWatched = Set(watchedFlags.keys)
        dirtyPlays = Set(ownPlays.keys).union(lastPlayed.keys)
    }

    func apply(_ merged: PersonalSyncResponse, sentPlays: [String: Int]) {
        for flag in merged.favorites { favoriteFlags[flag.id] = favoriteFlags[flag.id]?.merged(with: flag) ?? flag }
        for flag in merged.watched { watchedFlags[flag.id] = watchedFlags[flag.id]?.merged(with: flag) ?? flag }
        let nextFavorites = Set(favoriteFlags.values.filter(\.on).map(\.id))
        if nextFavorites != favorites { favorites = nextFavorites }
        let nextWatched = Set(watchedFlags.values.filter(\.on).map(\.id))
        if nextWatched != watched { watched = nextWatched }
        var counts = playCounts
        for play in merged.plays {
            // Plays since the request was sent are not in the server's sum yet.
            counts[play.id] = play.count + (ownPlays[play.id] ?? 0) - (sentPlays[play.id] ?? 0)
        }
        if counts != playCounts { playCounts = counts }
        var times = lastPlayed
        for played in merged.lastPlayed { times[played.id] = max(times[played.id] ?? 0, played.at) }
        if times != lastPlayed { lastPlayed = times }
        save(sync: false)
    }

    // MARK: Favourites

    func isFavorite(_ media: Media) -> Bool { favorites.contains(media.id) }
    func toggleFavorite(_ media: Media) { toggleFavorite(id: media.id) }

    /// Alben haben keine Medien-ID; der Server nimmt nur 64 Hexziffern an, darum ein Hash
    /// des Albumschlüssels. So gleicht er sich wie Lieblingssongs zwischen Geräten ab.
    static func favoriteID(of album: Album) -> String {
        SHA256.hash(data: Data("album:\(album.id)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func isFavorite(_ album: Album) -> Bool { favorites.contains(Self.favoriteID(of: album)) }
    func toggleFavorite(_ album: Album) { toggleFavorite(id: Self.favoriteID(of: album)) }
    /// Wann das Album zum Favoriten wurde, für die Reihenfolge.
    func favoriteDate(_ album: Album) -> Double { favoriteFlags[Self.favoriteID(of: album)]?.at ?? 0 }

    private func toggleFavorite(id: String) {
        let on = !favorites.contains(id)
        if on { favorites.insert(id) } else { favorites.remove(id) }
        favoriteFlags[id] = PersonalFlag(id: id, on: on, at: Date().timeIntervalSince1970)
        dirtyFavorites.insert(id)
        save()
    }

    // MARK: Statistics

    func recordPlay(_ media: Media) {
        playCounts[media.id, default: 0] += 1
        ownPlays[media.id, default: 0] += 1
        lastPlayed[media.id] = Date().timeIntervalSince1970
        dirtyPlays.insert(media.id)
        save()
    }
    func plays(_ media: Media) -> Int { playCounts[media.id] ?? 0 }

    func recordPlaylistPlay(_ id: String) {
        lastPlaylists[id] = Date().timeIntervalSince1970
        save(sync: false)
    }

    func recordAlbumPlay(_ id: String) {
        lastAlbums[id] = Date().timeIntervalSince1970
        save(sync: false)
    }

    /// Playlists and albums played as a whole, latest first, then the albums heard most.
    /// A song played from a playlist does not count for its album.
    func collectionsToHear(playlists: [Playlist], albums: [Album], limit: Int) -> [MusicCollection] {
        let recent = playlists.compactMap { list in lastPlaylists[list.id].map { (MusicCollection.playlist(list), $0) } }
            + albums.compactMap { album in lastAlbums[album.id].map { (MusicCollection.album(album), $0) } }
        var result = recent.sorted { $0.1 > $1.1 }.map { $0.0 }
        let heard = albums.map { album in (album, album.tracks.reduce(0) { $0 + plays($1) }) }
        for (album, _) in heard.filter({ $0.1 > 0 }).sorted(by: { $0.1 > $1.1 })
        where !result.contains(.album(album)) {
            result.append(.album(album))
        }
        return Array(result.prefix(limit))
    }

    func favoriteTracks(in library: [String: Media]) -> [Media] {
        var result: [Media] = []
        for id in favorites {
            if let media = library[id], media.kind == "audio" { result.append(media) }
        }
        result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return result
    }

    /// The most recently marked favorites come first.
    func latestFavorites(in library: [String: Media], limit: Int) -> [Media] {
        let sorted = favorites.sorted { favoriteFlags[$0]?.at ?? 0 > favoriteFlags[$1]?.at ?? 0 }
        return Array(sorted.compactMap { library[$0] }.filter { $0.kind == "audio" }.prefix(limit))
    }

    private struct Ranked {
        let media: Media
        let value: Double
    }

    func mostPlayed(in library: [String: Media], limit: Int = 50) -> [Media] {
        var ranked: [Ranked] = []
        for (id, count) in playCounts where count > 0 {
            if let media = library[id], media.kind == "audio" {
                ranked.append(Ranked(media: media, value: Double(count)))
            }
        }
        ranked.sort { a, b in
            if a.value != b.value { return a.value > b.value }
            return a.media.title < b.media.title
        }
        return ranked.prefix(limit).map { $0.media }
    }

    func recentlyPlayed(in library: [String: Media], kind: String = "audio", limit: Int = 50) -> [Media] {
        var ranked: [Ranked] = []
        for (id, time) in lastPlayed {
            if let media = library[id], media.kind == kind {
                ranked.append(Ranked(media: media, value: time))
            }
        }
        ranked.sort { $0.value > $1.value }
        return ranked.prefix(limit).map { $0.media }
    }

    /// What can be carried on with, latest first: unfinished films, and for each
    /// series the episode to go on with. Whatever is finished stays out.
    func continueWatching(in library: [String: Media], series: [SeriesGroup], resume: (Media) -> Double, limit: Int) -> [Media] {
        var seen = Set<String>()
        var result: [Media] = []
        for media in recentlyPlayed(in: library, kind: "video", limit: .max) where result.count < limit {
            guard seen.insert(media.seriesPath ?? media.id).inserted else { continue }
            if let path = media.seriesPath {
                if let group = series.first(where: { $0.id == path }),
                   let next = continueEpisode(in: group, resume: resume) { result.append(next.1) }
            } else if !isFinished(media, position: resume(media)) {
                result.append(media)
            }
        }
        return result
    }

    // MARK: Watched episodes and films

    func isWatched(_ media: Media) -> Bool { watched.contains(media.id) }
    func setWatched(_ media: Media, _ value: Bool) {
        guard value != watched.contains(media.id) else { return }
        mark(media, watched: value)
        save()
    }
    func setWatched(_ list: [Media], _ value: Bool) {
        for media in list where value != watched.contains(media.id) { mark(media, watched: value) }
        save()
    }
    private func mark(_ media: Media, watched value: Bool) {
        if value { watched.insert(media.id) } else { watched.remove(media.id) }
        watchedFlags[media.id] = PersonalFlag(id: media.id, on: value, at: Date().timeIntervalSince1970)
        dirtyWatched.insert(media.id)
    }

    private func isFinished(_ media: Media, position: Double) -> Bool {
        if watched.contains(media.id) { return true }
        guard let duration = media.duration, duration > 0 else { return false }
        return position >= duration * Self.finishedShare
    }

    /// The episode last played while it is unfinished, otherwise the next unseen one
    /// after it. An old episode that was only looked into does not hold the series back.
    func continueEpisode(in series: SeriesGroup, resume: (Media) -> Double) -> (Season, Media)? {
        let order = series.seasons.flatMap { season in season.episodes.map { (season, $0) } }
        let played = order.indices.filter { lastPlayed[order[$0].1.id] != nil }
        guard let latest = played.max(by: { lastPlayed[order[$0].1.id, default: 0] < lastPlayed[order[$1].1.id, default: 0] }) else {
            return nextEpisode(in: series)
        }
        let episode = order[latest].1
        if !isFinished(episode, position: resume(episode)) { return order[latest] }
        return order[(latest + 1)...].first { !watched.contains($0.1.id) } ?? nextEpisode(in: series)
    }

    /// First unwatched episode in broadcast order, or nil when all are seen.
    func nextEpisode(in series: SeriesGroup) -> (Season, Media)? {
        for season in series.seasons {
            if let episode = season.episodes.first(where: { !watched.contains($0.id) }) { return (season, episode) }
        }
        return nil
    }
}
