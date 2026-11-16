import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension String {
    /// Die Texte sprechen vom iPhone. Auf dem iPad und dem Mac steht das passende Gerät,
    /// auf dem Mac auch mit dem passenden Artikel („dieser Mac“).
    var forThisDevice: String {
        #if targetEnvironment(macCatalyst)
        let words = [("dieses iPhones", "dieses Macs"), ("Dieses iPhone", "Dieser Mac"), ("dieses iPhone", "dieser Mac"),
                     ("this iPhone", "this Mac"), ("iPhone", "Mac")]
        #elseif canImport(UIKit)
        guard UIDevice.current.userInterfaceIdiom == .pad else { return self }
        let words = [("iPhone", "iPad")]
        #else
        let words: [(String, String)] = []
        #endif
        return words.reduce(self) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}

struct PlaybackVariant: Codable, Hashable {
    let fileExtension: String
    let bytes: UInt64
}

struct Media: Codable, Identifiable, Hashable {
    let id: String
    let path: String
    let name: String
    let kind: String
    let title: String
    let artist: String?
    let album: String?
    let duration: Double?
    let bytes: UInt64
    let modified: UInt64
    var playback: PlaybackVariant? = nil
    /// The server has an adaptive copy of this video.
    var hls: Bool? = nil
    /// Folder that forms the album (server: every music folder is one album).
    var albumKey: String? = nil
    var albumArtist: String? = nil
    var trackNumber: Int? = nil
    var discNumber: Int? = nil
    /// Artwork ID for `/v1/artwork/{id}` (folder image or embedded cover).
    var coverId: String? = nil
    var seriesKey: String? = nil
    var seasonFolder: String? = nil
    var season: Int? = nil
    var episode: Int? = nil
    var subtitles: [SubtitleRef]? = nil
    var hasLyrics: Bool? = nil
    /// Guest artists ("feat.") and the full credit for display.
    var featured: [String]? = nil
    var artistCredit: String? = nil
    /// ReplayGain in dB for volume levelling (from the tags or measured by the server).
    var gainDb: Double? = nil
    /// Intro of an episode that is the same in every episode of its season.
    var intro: IntroRange? = nil
    /// The server could only find a censored version of this song.
    var censored: Bool? = nil
    /// When the file first appeared on the server; a song loaded again keeps the old date.
    var added: UInt64? = nil
    var addedAt: UInt64 { added ?? modified }

    var subtitle: String { [artistCredit ?? artist, album].compactMap { $0 }.joined(separator: " · ") }
    /// Main artist plus guests.
    var allArtists: [String] { (artist.map { [$0] } ?? []) + (featured ?? []) }
    // This labels the container, not the codecs or a guarantee of playability.
    var formatLabel: String {
        let suffix = (name as NSString).pathExtension
        let original = suffix.isEmpty ? "Datei" : suffix.uppercased()
        guard let playback else { return original }
        return original + " · optimierte " + playback.fileExtension.uppercased() + "-Kopie"
    }
    var downloadMedia: Media {
        guard let playback, ["mp4", "m4a"].contains(playback.fileExtension) else { return self }
        return Media(id: id, path: path,
                     name: (name as NSString).deletingPathExtension + "." + playback.fileExtension,
                     kind: kind, title: title, artist: artist, album: album, duration: duration,
                     bytes: playback.bytes, modified: modified, playback: nil,
                     albumKey: albumKey, albumArtist: albumArtist, trackNumber: trackNumber,
                     discNumber: discNumber, coverId: coverId, seriesKey: seriesKey,
                     seasonFolder: seasonFolder, season: season, episode: episode,
                     subtitles: subtitles, hasLyrics: hasLyrics, featured: featured,
                     artistCredit: artistCredit, gainDb: gainDb, intro: intro, censored: censored, added: added)
    }
    var symbol: String { kind == "video" ? "film" : kind == "audio" ? "music.note" : "doc" }
    private var seriesRootIndex: Int? {
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(where: { ["serien", "series", "tv shows", "tv-serien", "tvshows"].contains($0.lowercased()) }),
              index + 2 < parts.count else { return nil }
        return index
    }
    /// Series folder path, e.g. "Serien/Two and a Half Men".
    var seriesPath: String? {
        guard kind == "video" else { return nil }
        if let seriesKey { return seriesKey }
        guard let index = seriesRootIndex else { return nil }
        return path.split(separator: "/").prefix(index + 2).joined(separator: "/")
    }
    var series: String? { seriesPath.map { displayName(($0 as NSString).lastPathComponent) } }
    /// Season folder name below the series folder (old caches: derived from the path).
    var seasonGroup: String? {
        guard kind == "video", seriesPath != nil else { return nil }
        if let seasonFolder { return seasonFolder }
        if seriesKey == nil, let index = seriesRootIndex {
            let parts = path.split(separator: "/").map(String.init)
            if index + 3 < parts.count { return parts[index + 2] }
        }
        return nil
    }
    /// Album grouping key: the folder, otherwise album tag + artist.
    var albumGroup: String {
        albumKey ?? "tag:" + (album ?? "Ohne Album") + "\u{1f}" + (albumArtist ?? artist ?? "")
    }
    /// Episode title without the series name or SxxEyy prefix.
    var episodeTitle: String {
        let cleaned = title.replacingOccurrences(of: "_", with: " ")
        if let range = cleaned.range(of: #"(?i)s\d{1,3}\s*e\d{1,4}|\b\d{1,2}x\d{1,3}\b"#, options: .regularExpression) {
            let rest = cleaned[range.upperBound...]
                .replacingOccurrences(of: ".", with: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–·:").union(.whitespaces))
            return rest.isEmpty ? (episode.map { String(localized: "Folge \($0)") } ?? cleaned) : rest
        }
        return cleaned
    }
}

// MARK: Online information (server `/v1/metadata`)

extension Array where Element == Media {
    /// Songs that fit `song`, closest first: the rest of its album from the next
    /// track on, more by the same artist, then songs linked to it by a guest ("feat.").
    /// There is no genre in the library, so nothing else counts as similar.
    func similarSongs(to song: Media, limit: Int = 50) -> [Media] {
        func key(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
            return text
        }
        func mainArtist(_ media: Media) -> String? { key(media.artist ?? media.albumArtist) }
        func album(_ media: Media) -> String? {
            key(media.albumKey) ?? key(media.album).map { $0 + "\n" + (mainArtist(media) ?? "") }
        }
        func position(_ media: Media) -> (Int, Int) { (media.discNumber ?? 1, media.trackNumber ?? 0) }
        func inOrder(_ first: Media, _ second: Media) -> Bool {
            let one = (first.album ?? "").lowercased(), other = (second.album ?? "").lowercased()
            if one != other { return one < other }
            if position(first) != position(second) { return position(first) < position(second) }
            return first.title.localizedStandardCompare(second.title) == .orderedAscending
        }

        let songs = filter { $0.kind == "audio" && $0.id != song.id }
        let songAlbum = album(song), artist = mainArtist(song)
        let sameAlbum = songAlbum == nil ? [] : songs.filter { album($0) == songAlbum }.sorted(by: inOrder)
        let later = sameAlbum.filter { position($0) > position(song) }
        let earlier = sameAlbum.filter { position($0) <= position(song) }
        let sameArtist = artist == nil ? [] : songs.filter { mainArtist($0) == artist }.sorted(by: inOrder)
        let names = Set(song.allArtists.compactMap(key) + [artist].compactMap { $0 })
        let linked = names.isEmpty ? [] : songs.filter { other in
            !Set(other.allArtists.compactMap(key) + [mainArtist(other)].compactMap { $0 }).isDisjoint(with: names)
        }.sorted(by: inOrder)

        // The same song can lie in two folders; it should not play twice in a row.
        var seen: Set<String> = [(key(song.title) ?? "") + "\n" + (artist ?? "")]
        var result: [Media] = []
        for candidate in later + earlier + sameArtist + linked where result.count < limit {
            if seen.insert((key(candidate.title) ?? "") + "\n" + (mainArtist(candidate) ?? "")).inserted {
                result.append(candidate)
            }
        }
        return result
    }
}

struct CoverEntry: Codable, Hashable {
    let directory: String
    let artwork: String
}

struct AlbumInfo: Codable, Hashable {
    let key: String
    var title: String? = nil
    var artist: String? = nil
    var genre: String? = nil
    var releaseDate: String? = nil
    var year: String? = nil
    var trackCount: Int? = nil
    var copyright: String? = nil
    var artwork: String? = nil
    var description: String? = nil
    var shortDescription: String? = nil
    var wikipediaUrl: String? = nil
}

struct ArtistInfo: Codable, Hashable {
    let key: String
    var genre: String? = nil
    var image: String? = nil
    var description: String? = nil
    var shortDescription: String? = nil
    var wikipediaUrl: String? = nil
}

struct TrackInfo: Codable, Hashable {
    let key: String
    var title: String? = nil
    var artist: String? = nil
    var album: String? = nil
    var genre: String? = nil
    var releaseDate: String? = nil
    var year: String? = nil
    var trackNumber: Int? = nil
    var trackCount: Int? = nil
    var discNumber: Int? = nil
    var explicit: Bool? = nil
}

struct EpisodeInfo: Codable, Hashable {
    let season: Int
    let number: Int
    var name: String? = nil
    var airdate: String? = nil
    var runtime: Int? = nil
    var summary: String? = nil
}

struct SeriesInfo: Codable, Hashable {
    let key: String
    var name: String? = nil
    var summary: String? = nil
    var genres: [String]? = nil
    var premiered: String? = nil
    var ended: String? = nil
    var status: String? = nil
    var network: String? = nil
    var rating: Double? = nil
    var runtime: Int? = nil
    var tvmazeUrl: String? = nil
    var poster: String? = nil
    var description: String? = nil
    var shortDescription: String? = nil
    var wikipediaUrl: String? = nil
    var episodes: [EpisodeInfo]? = nil
}

struct MovieInfo: Codable, Hashable {
    let key: String
    var title: String? = nil
    var year: Int? = nil
    var poster: String? = nil
    var description: String? = nil
    var shortDescription: String? = nil
    var wikipediaUrl: String? = nil
}

struct LibraryMetadata: Codable {
    var enabled: Bool? = nil
    var pending: Int? = nil
    var covers: [CoverEntry]? = nil
    /// Media IDs with a generated video still (`thumb-<id>`).
    var thumbnails: [String]? = nil
    var albums: [AlbumInfo]? = nil
    var artists: [ArtistInfo]? = nil
    var tracks: [TrackInfo]? = nil
    var series: [SeriesInfo]? = nil
    var movies: [MovieInfo]? = nil
}

// MARK: Library groups built from the media list

struct Album: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String?
    let tracks: [Media]
    let coverId: String?

    /// Wann der neueste Titel des Albums auf den Server kam.
    var addedAt: UInt64 { tracks.map(\.addedAt).max() ?? 0 }
}

struct Season: Identifiable, Hashable {
    let id: String
    let title: String
    let number: Int?
    let episodes: [Media]
}

struct SeriesGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let seasons: [Season]
    let coverId: String?
    var episodeCount: Int { seasons.reduce(0) { $0 + $1.episodes.count } }
}

enum RepeatMode: String, CaseIterable {
    case off, all, one
    var next: RepeatMode { self == .off ? .all : self == .all ? .one : .off }
    var symbol: String { self == .one ? "repeat.1" : "repeat" }
    var label: String { self == .off ? String(localized: "Wiederholen aus") : self == .all ? String(localized: "Alle wiederholen") : String(localized: "Titel wiederholen") }
}

/// First number in a folder name: "Season 12" -> 12, "Staffel 04" -> 4.
func seasonNumber(from folder: String) -> Int? {
    let lower = folder.lowercased()
    if lower.contains("special") { return 0 }
    guard let range = lower.range(of: #"\d{1,4}"#, options: .regularExpression) else { return nil }
    return Int(lower[range])
}

func trackOrder(_ a: Media, _ b: Media) -> Bool {
    let discA = a.discNumber ?? 1, discB = b.discNumber ?? 1
    if discA != discB { return discA < discB }
    switch (a.trackNumber, b.trackNumber) {
    case let (x?, y?) where x != y: return x < y
    case (_?, nil): return true
    case (nil, _?): return false
    default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

func episodeOrder(_ a: Media, _ b: Media) -> Bool {
    switch (a.episode, b.episode) {
    case let (x?, y?) where x != y: return x < y
    case (_?, nil): return true
    case (nil, _?): return false
    default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

func durationLabel(_ value: Double?) -> String? {
    guard let value, value.isFinite, value > 0 else { return nil }
    let s = Int(value)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

struct LibraryPage: Decodable {
    let items: [Media]
    let total: Int
    let scanErrors: Int
}

struct DirectoryPage: Decodable {
    let path: String
    let directories: [String]
    let files: [Media]
    let total: Int
}

struct Playlist: Codable, Identifiable {
    let id: String
    var name: String
    var mediaIds: [String]
}

struct PlaylistInput: Encodable {
    let name: String
    let mediaIds: [String]
}

extension PlaybackProgress {
    /// Which position to start from: the one saved last, here (also offline) or
    /// on another device. Positions saved before the app kept times stay as before:
    /// one not yet sent wins, otherwise the server's.
    static func resumePosition(local: Double, localAt: Double, localPending: Bool, remote: PlaybackProgress) -> Double {
        let remoteAt = Double(remote.updatedAt ?? 0)
        if remoteAt == 0 && remote.seconds == 0 { return local }
        if localAt > 0 { return remoteAt >= localAt ? remote.seconds : local }
        return localPending ? local : remote.seconds
    }
}

struct FollowedArtist: Codable, Hashable, Identifiable {
    let name: String
    /// Unix seconds; what arrives after this counts as new.
    let since: UInt64
    var id: String { name.lowercased() }
}

struct FollowList: Codable {
    let follows: [FollowedArtist]
    /// The server's music service loads new releases (not only remembers the artists).
    let loading: Bool
}

struct FollowChange: Encodable {
    let name: String
    let follow: Bool
}

struct PlaybackProgress: Codable {
    var seconds: Double
    /// When the position was saved (Unix seconds); the newest one wins between devices.
    var updatedAt: UInt64? = nil
}

struct StorageInfo: Decodable {
    let totalBytes: UInt64
    let availableBytes: UInt64
    let indexedBytes: UInt64
    let fileCount: Int
    let scanErrors: Int
    var uploads: Bool? = nil
    var deletes: Bool? = nil
}

struct ServerDeleteRequest: Encodable { let ids: [String] }
struct ServerDeleteResult: Decodable {
    let deleted: Int
    let failed: Int
}

struct SubtitleRef: Codable, Hashable, Identifiable {
    let id: String
    var language: String? = nil
    let label: String
    var forced: Bool = false
}

struct LyricsPayload: Codable {
    var synced: String? = nil
    var plain: String? = nil
    var instrumental: Bool? = nil
    var source: String? = nil
}

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double
    let text: String
}

struct SubtitleCue: Hashable {
    let start: Double
    let end: Double
    let text: String
}

/// "[01:23.45] Text" lines (several stamps per line allowed), sorted by time.
func parseLRC(_ text: String) -> [LyricLine] {
    var entries: [(Double, String)] = []
    for raw in text.split(whereSeparator: \.isNewline) {
        var line = Substring(raw)
        var times: [Double] = []
        while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            let stamp = line[line.index(after: line.startIndex)..<close]
            let parts = stamp.split(separator: ":")
            if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1].replacingOccurrences(of: ",", with: ".")) {
                times.append(minutes * 60 + seconds)
            } else if times.isEmpty {
                break // metadata such as [ar:Artist]
            }
            line = line[line.index(after: close)...]
        }
        let content = line.trimmingCharacters(in: .whitespaces)
        for time in times { entries.append((time, content)) }
    }
    return entries.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
}

/// WebVTT cues; inline tags such as <i> are removed.
func parseWebVTT(_ text: String) -> [SubtitleCue] {
    func seconds(_ value: Substring) -> Double? {
        let clean = value.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let parts = clean.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return nil
        }
    }
    var cues: [SubtitleCue] = []
    let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
    for block in blocks {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
        let bounds = lines[timing].components(separatedBy: "-->")
        guard bounds.count == 2, let start = seconds(Substring(bounds[0])), let end = seconds(Substring(bounds[1])) else { continue }
        let body = lines[(timing + 1)...].joined(separator: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: body)) }
    }
    return cues.sorted { $0.start < $1.start }
}

struct StreamTicket: Decodable {
    let path: String
    var hlsPath: String? = nil
    let expiresAt: UInt64
}

struct Connection: Codable, Equatable {
    let baseURL: URL
    let token: String
}

/// `/v1/status`: the state of the Pi.
struct ServerStatusInfo: Decodable {
    var uptimeSeconds: Int?
    var load: Double?
    var memoryTotalBytes: UInt64?
    var memoryAvailableBytes: UInt64?
    var temperatureC: Double?
    var diskTotalBytes: UInt64?
    var diskAvailableBytes: UInt64?
    var musicServiceSecondsAgo: Int?
    var songs: Int?
    var songsLevelled: Int?
    var seasonsWithIntro: Int?
    var musicCatalog: MusicCatalogInfo?
}

/// The local copy of the music catalog on the Pi (faster music search).
struct MusicCatalogInfo: Decodable {
    var artistsReady: Int
    var artistsListed: Int
    var bytes: UInt64
}

struct IntroRange: Codable, Hashable {
    let start: Double
    let end: Double
}

struct OfflineRecord: Codable, Identifiable {
    var id: String { media.id }
    let media: Media
    let filename: String
}

enum MiniplyError: LocalizedError {
    case unauthorized
    case server(Int)
    case message(String)
    var errorDescription: String? {
        switch self {
        case .unauthorized: String(localized: "Zugriff verweigert. Bitte API-Token prüfen.")
        case .server(let status): String(localized: "Server meldet HTTP \(status).")
        case .message(let value): value
        }
    }
}

/// A favourite or watched mark including removals, so devices can tell which
/// change is the latest.
struct PersonalFlag: Codable, Equatable {
    let id: String
    var on: Bool
    var at: Double

    func merged(with other: PersonalFlag) -> PersonalFlag {
        if other.at != at { return other.at > at ? other : self }
        return on ? self : other
    }
}

struct PersonalPlayCount: Codable, Equatable {
    let id: String
    let count: Int
}

struct PersonalLastPlayed: Codable, Equatable {
    let id: String
    let at: Double
}

struct PersonalSyncRequest: Encodable {
    let device: String
    /// The cursor of the previous answer; 0 asks for everything.
    let since: Int64
    let favorites: [PersonalFlag]
    let watched: [PersonalFlag]
    let plays: [PersonalPlayCount]
    let lastPlayed: [PersonalLastPlayed]
}

struct PersonalSyncResponse: Decodable {
    var cursor: Int64 = 0
    let favorites: [PersonalFlag]
    let watched: [PersonalFlag]
    let plays: [PersonalPlayCount]
    let lastPlayed: [PersonalLastPlayed]
}

struct UploadStatus: Decodable {
    let received: Int64
}

/// Playlists and series this iPhone keeps available by itself.
struct AutoDownloadSettings: Codable, Equatable {
    var playlists: Set<String> = []
    var series: Set<String> = []
    /// Files the user removed or cancelled: never fetched again automatically.
    var skipped: Set<String> = []
    var isEmpty: Bool { playlists.isEmpty && series.isEmpty }

    static let wifiOnlyKey = "mediaserver.autoDownloadWifiOnly"
    static let removeWatchedKey = "mediaserver.removeWatchedDownloads"
    static let upcomingEpisodes = 3

    /// Every title of the marked playlists and the next unwatched episodes.
    func wanted(playlists lists: [Playlist], seriesGroups: [SeriesGroup], library: [String: Media], watched: Set<String>) -> [Media] {
        var seen = skipped
        var result: [Media] = []
        func add(_ media: Media) { if seen.insert(media.id).inserted { result.append(media) } }
        for list in lists where playlists.contains(list.id) {
            list.mediaIds.compactMap { library[$0] }.forEach(add)
        }
        for group in seriesGroups where series.contains(group.id) {
            // The episodes after the last watched one; an early episode that was skipped
            // does not hold the downloads back.
            let all = group.seasons.flatMap(\.episodes)
            let start = all.lastIndex { watched.contains($0.id) }.map { $0 + 1 } ?? 0
            let open = { (list: ArraySlice<Media>) in list.filter { !watched.contains($0.id) && !skipped.contains($0.id) } }
            let upcoming = open(all[start...])
            (upcoming.isEmpty ? open(all[...]) : upcoming).prefix(Self.upcomingEpisodes).forEach(add)
        }
        return result
    }
}

/// What the device currently knows about its network.
/// Apart from AppModel, whose changes redraw the whole app: progress changes
/// constantly and only concerns the few views that show it.
@MainActor
final class DownloadProgress: ObservableObject {
    static let shared = DownloadProgress()
    @Published private(set) var values: [String: Double] = [:]

    func update(_ next: [String: Double]) {
        if next != values { values = next }
    }
}

struct NetworkState: Equatable {
    var online = true
    /// Mobile data or a personal hotspot.
    var expensive = false
    /// Low Data Mode.
    var constrained = false
    var interface = ""
}

/// Streaming preferences per network. Without HLS a stream has one fixed
/// bitrate, so the choices are how far ahead to load and whether to stream.
enum StreamPolicy {
    static let cellularKey = "mediaserver.cellularStreaming"
    static let wifiBufferKey = "mediaserver.bufferWifi"
    static let cellularBufferKey = "mediaserver.bufferCellular"
    static let wifiQualityKey = "mediaserver.qualityWifi"
    static let cellularQualityKey = "mediaserver.qualityCellular"
    static let mediumBitrate = 3_000_000.0
    static let lowBitrate = 1_500_000.0
    static let saverSeconds = 10.0
    static let stableSeconds = 60.0
    /// "Automatisch" über Mobilfunk oder einen Hotspot: AVPlayer allein lädt dort nur wenige
    /// Sekunden voraus, und jeder kurze Einbruch hält ein Video an, auch im Bild-in-Bild.
    static let mobileAutoSeconds = 30.0

    /// Seconds to load ahead; 0 lets AVPlayer decide.
    static func forwardBuffer(_ network: NetworkState, defaults: UserDefaults = .standard) -> Double {
        if network.constrained { return saverSeconds }
        switch defaults.string(forKey: network.expensive ? cellularBufferKey : wifiBufferKey) {
        case "saver": return saverSeconds
        case "stable": return stableSeconds
        default: return network.expensive ? mobileAutoSeconds : 0
        }
    }

    /// Bits per second for adaptive video; 0 means no limit. Files without an
    /// adaptive copy have one fixed quality.
    static func peakBitrate(_ network: NetworkState, defaults: UserDefaults = .standard) -> Double {
        if network.constrained { return lowBitrate }
        switch defaults.string(forKey: network.expensive ? cellularQualityKey : wifiQualityKey) {
        case "medium": return mediumBitrate
        case "low": return lowBitrate
        default: return 0
        }
    }

    /// The unchanged file instead of a copy that can step down. Low Data Mode wins.
    static func prefersOriginal(_ network: NetworkState, defaults: UserDefaults = .standard) -> Bool {
        !network.constrained && defaults.string(forKey: network.expensive ? cellularQualityKey : wifiQualityKey) == "original"
    }

    static func blocks(kind: String, on network: NetworkState, defaults: UserDefaults = .standard) -> Bool {
        guard network.online, network.expensive else { return false }
        switch defaults.string(forKey: cellularKey) {
        case "off": return true
        case "audio": return kind != "audio"
        default: return false
        }
    }

    static func blockedMessage(kind: String) -> String {
        kind == "audio"
            ? String(localized: "Streaming über Mobilfunk ist in den Einstellungen ausgeschaltet.")
            : String(localized: "Videos über Mobilfunk sind in den Einstellungen ausgeschaltet.")
    }
}

/// How long and how often the player tries to get a lost stream back.
enum ReconnectPolicy {
    static let limit: TimeInterval = 300
    static func delay(attempt: Int) -> Double { min(30, pow(2, Double(min(attempt, 8)))) }
}

/// Where the connection to the media server currently fails.
enum ServerStatus: Equatable {
    case unknown, ok, emptyLibrary, noInternet, unreachable, homeServerDown, unauthorized, storageProblem

    init(failure: Error, online: Bool) {
        if !online { self = .noInternet; return }
        switch failure as? MiniplyError {
        case .unauthorized: self = .unauthorized
        case .server(let status) where (502...504).contains(status): self = .homeServerDown
        default: self = failure is URLError ? .unreachable : .storageProblem
        }
    }

    var title: String {
        switch self {
        case .unknown: String(localized: "Noch nicht geprüft")
        case .ok: String(localized: "Alles in Ordnung")
        case .emptyLibrary: String(localized: "Keine Dateien gefunden")
        case .noInternet: String(localized: "Kein Internet")
        case .unreachable: String(localized: "Server nicht erreichbar")
        case .homeServerDown: String(localized: "Medienserver antwortet nicht")
        case .unauthorized: String(localized: "Zugriff verweigert")
        case .storageProblem: String(localized: "Fehler am Server")
        }
    }

    var detail: String {
        switch self {
        case .unknown: String(localized: "Tippe auf „Jetzt prüfen“.")
        case .ok: String(localized: "Internet, Server und Bibliothek sind erreichbar.")
        case .emptyLibrary: String(localized: "Der Server läuft, findet aber keine Medien. Prüfe, ob die SSD eingebunden ist und Dateien enthält.")
        case .noInternet: String(localized: "Dieses iPhone ist nicht mit dem Internet verbunden. Downloads bleiben abspielbar.").forThisDevice
        case .unreachable: String(localized: "Internet ist da, aber die Serveradresse antwortet nicht. Prüfe die Adresse und ob der Zugangspunkt läuft.")
        case .homeServerDown: String(localized: "Der Zugangspunkt ist erreichbar, der Medienserver dahinter aber nicht. Prüfe, ob er eingeschaltet ist und der Tunnel läuft.")
        case .unauthorized: String(localized: "Der Server lehnt das API-Token ab. Verbinde dich mit dem aktuellen Token neu.")
        case .storageProblem: String(localized: "Der Server meldet einen internen Fehler. Prüfe, ob die SSD eingebunden ist, und sieh ins Serverprotokoll.")
        }
    }

    var symbol: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .ok: "checkmark.circle.fill"
        case .emptyLibrary, .storageProblem: "externaldrive.badge.exclamationmark"
        case .noInternet: "wifi.slash"
        case .unreachable, .homeServerDown: "server.rack"
        case .unauthorized: "lock.trianglebadge.exclamationmark"
        }
    }
}

func byteLabel(_ count: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
}

/// Folder names copied over the Finder share can contain Samba's private-use
/// stand-ins for `" * : < > ? \ |` (shown as boxes). Map them back for display.
func displayName(_ value: String) -> String {
    let map: [UInt32: String] = [0xF020: "\"", 0xF021: "*", 0xF022: ":", 0xF023: "<", 0xF024: ">",
                                 0xF025: "?", 0xF026: "\\", 0xF027: "|", 0xF028: " ", 0xF029: "."]
    var result = ""
    for scalar in value.unicodeScalars {
        if let replacement = map[scalar.value] { result += replacement }
        else if (0xF001...0xF01F).contains(scalar.value) { continue }
        else { result.unicodeScalars.append(scalar) }
    }
    return result.trimmingCharacters(in: .whitespaces)
}

