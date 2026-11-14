import SwiftUI

struct MusicSearchResult: Decodable, Identifiable, Hashable {
    let id: UInt64
    let kind: String
    let title: String
    let artist: String?
    let album: String?
    let year: String?
    let trackCount: Int?
    let seconds: Int?
    let cover: String?
    let explicit: Bool?
    /// Erscheinungstag als „2026-10-11“ und bei Alben „album“, „single“ oder „ep“.
    var released: String? = nil
    var releaseType: String? = nil

    var releaseLabel: String {
        switch releaseType {
        case "single": String(localized: "Single")
        case "ep": String(localized: "EP")
        default: kind == "song" ? String(localized: "Song") : String(localized: "Album")
        }
    }

    var releaseDate: Date? {
        guard let released else { return nil }
        return try? Date(released, strategy: .iso8601.year().month().day())
    }

    var details: String {
        var parts = [artist ?? ""]
        if kind == "song", let album { parts.append(album) }
        if let year { parts.append(year) }
        if let trackCount { parts.append(String(localized: "\(trackCount) Titel")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct MusicSearchResponse: Decodable { let results: [MusicSearchResult] }

struct MusicJob: Decodable, Identifiable, Equatable {
    let id: String
    let kind: String
    let itemId: UInt64
    let title: String
    let artist: String?
    let cover: String?
    let state: String
    let done: Int
    let total: Int
    let current: String?
    let missing: [String]
    let message: String?

    var isActive: Bool { state == "queued" || state == "running" }

    var statusText: String {
        switch state {
        case "queued": String(localized: "Wartet auf den Server")
        case "running":
            if total == 0 { String(localized: "Sucht die Titelliste …") }
            else if let current { String(localized: "\(done + 1) von \(total): \(current)") }
            else { String(localized: "\(done) von \(total)") }
        case "done": String(localized: "Fertig: alles in der Bibliothek")
        case "partial": String(localized: "\(done) von \(total) geladen. Nicht gefunden: \(missing.joined(separator: ", "))")
        case "cancelled": String(localized: "Abgebrochen")
        default: message ?? String(localized: "Fehlgeschlagen")
        }
    }
}

private struct MusicJobList: Decodable {
    let serviceOnline: Bool
    let jobs: [MusicJob]
}

private struct NewMusicJob: Encodable {
    let kind: String
    let itemId: UInt64
    let title: String
    let artist: String?
    let cover: String?
}

/// Die Aufträge auf dem Server, für die Suche und die Künstlerseiten.
@MainActor
final class MusicJobs: ObservableObject {
    private static let refreshSeconds = 10.0
    /// Der Server liest neue Songs selbst ein; einen Moment später sind sie da.
    private static let rescanSeconds = 12.0

    @Published private(set) var jobs: [MusicJob] = []
    @Published private(set) var serviceOnline = true
    @Published private(set) var available = true
    @Published var problem: String?

    func active(_ result: MusicSearchResult) -> Bool {
        jobs.contains { $0.itemId == result.id && $0.kind == result.kind && $0.isActive }
    }

    func request(_ result: MusicSearchResult, api: API?) async {
        guard let api else { return }
        do {
            let job = NewMusicJob(kind: result.kind, itemId: result.id, title: result.title, artist: result.artist, cover: result.cover)
            let created: MusicJob = try await api.sendAndDecode("/v1/music/jobs", method: "POST", value: job)
            if !jobs.contains(where: { $0.id == created.id }) { jobs.insert(created, at: 0) }
            problem = nil
        } catch {
            problem = String(localized: "Der Auftrag kam nicht beim Server an.")
        }
    }

    func remove(_ job: MusicJob, model: AppModel) async {
        guard let api = model.api else { return }
        do {
            try await api.perform("/v1/music/jobs/\(job.id)", method: "DELETE")
            await load(model: model)
        } catch {
            problem = String(localized: "Der Auftrag ließ sich nicht entfernen.")
        }
    }

    /// Ändert sich, wenn das Abfragen anfangen oder aufhören soll.
    func watchKey(_ phase: ScenePhase) -> String {
        "\(phase == .active)|\(jobs.contains(where: \.isActive))"
    }

    /// Fragt einmal und danach nur, solange etwas läuft und die App offen ist. Jede Abfrage
    /// weckt das Funkmodul, auch wenn die App mit Musik im Hintergrund läuft.
    func watch(model: AppModel, phase: ScenePhase) async {
        guard phase == .active else { return }
        await load(model: model)
        while !Task.isCancelled, jobs.contains(where: \.isActive) {
            try? await Task.sleep(for: .seconds(Self.refreshSeconds))
            guard !Task.isCancelled else { return }
            await load(model: model)
        }
    }

    private func load(model: AppModel) async {
        guard let api = model.api else { return }
        do {
            let list: MusicJobList = try await api.get("/v1/music/jobs")
            let wasActive = Set(jobs.filter(\.isActive).map(\.id))
            let finished = list.jobs.contains { wasActive.contains($0.id) && !$0.isActive }
            jobs = list.jobs
            serviceOnline = list.serviceOnline
            available = true
            if finished {
                // Unabhängig vom Abfragen, das mit dem letzten Auftrag endet.
                Task {
                    try? await Task.sleep(for: .seconds(Self.rescanSeconds))
                    await model.refresh()
                }
            }
        } catch MiniplyError.server(404) {
            available = false
        } catch {
            // Ein Aussetzer beim Abfragen ist kein Grund für eine Meldung; es folgt der nächste Versuch.
        }
    }
}

/// Im Datensparmodus bleiben die Cover weg.
private struct CatalogCover: View {
    let address: String?
    var large = false
    @ObservedObject private var connectivity = Connectivity.shared

    var body: some View {
        let placeholder = RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        let wanted = large ? address?.replacingOccurrences(of: "100x100bb", with: "300x300bb") : address
        Group {
            if let wanted, let url = URL(string: wanted), !connectivity.state.constrained {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: { placeholder }
            } else { placeholder }
        }
    }
}

private struct ArtistCatalog: Decodable {
    let latest: [MusicSearchResult]
    let popular: [MusicSearchResult]
    let albums: [MusicSearchResult]
    /// Alle Veröffentlichungen, die neueste zuerst; ältere Server schicken sie nicht.
    let releases: [MusicSearchResult]?
    let singles: [MusicSearchResult]?
}

/// Songs und Alben heißen im Katalog fast wie in der Bibliothek; Gäste stehen mal im Titel, mal nicht.
private func catalogKey(_ title: String) -> String {
    title.lowercased()
        .replacingOccurrences(of: #"\s*[(\[](feat|ft|with)[^)\]]*[)\]]"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: " - single", with: "")
        .filter { $0.isLetter || $0.isNumber }
}

/// Eine Zeile oder ein Cover führt zur Vorschau; erst dort wird etwas auf den Server geholt.
private struct JobClock: View {
    var body: some View {
        Image(systemName: "clock").foregroundStyle(.secondary).accessibilityLabel(String(localized: "Auftrag läuft"))
    }
}

private struct ExplicitBadge: View {
    var body: some View {
        Image(systemName: "e.square.fill").font(.caption2).foregroundStyle(.secondary)
            .accessibilityLabel(String(localized: "Unzensiert"))
    }
}

private func clockText(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// Die Künstlerseite aus dem iTunes-Katalog: die neueste Veröffentlichung, die beliebtesten
/// Songs, was neu erschienen ist und die Diskografie. Was schon auf dem Server liegt, lässt
/// sich abspielen und aufs iPhone laden; der Rest führt zur Vorschau.
struct ArtistCatalogSections<Fallback: View>: View {
    private static var shortPopular: Int { 5 }
    private static var longPopular: Int { 10 }
    private static var newSongs: Int { 5 }
    private static var recentReleases: Int { 10 }
    let name: String
    @ViewBuilder let fallback: Fallback
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var jobs = MusicJobs()
    @State private var catalog: ArtistCatalog?
    @State private var showsAllPopular = false
    @State private var showsSingles = false

    private var ownedTracks: [String: Media] {
        Dictionary(model.items.filter { $0.kind == "audio" && $0.allArtists.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
            .map { (catalogKey($0.title), $0) }, uniquingKeysWith: { first, _ in first })
    }
    private var ownedAlbums: [String: Album] {
        Dictionary(model.artistAlbums(name).map { (catalogKey($0.title), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func unique(_ results: [MusicSearchResult]) -> [MusicSearchResult] {
        var seen = Set<String>()
        return results.filter { seen.insert(catalogKey($0.title)).inserted }
    }

    var body: some View {
        Group {
            if let catalog, !model.isOffline {
                let tracks = ownedTracks
                let albums = ownedAlbums
                let releases = catalog.releases ?? catalog.albums
                if let problem = jobs.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange).padding(.horizontal)
                }
                if let newest = releases.first {
                    SectionHeader(String(localized: "Neuerscheinung"))
                    newestRelease(newest, albums: albums).padding(.horizontal)
                }
                let popular = Array(unique(catalog.popular).prefix(Self.longPopular))
                if !popular.isEmpty {
                    SectionHeader(title: String(localized: "Beliebt")) {
                        if popular.count > Self.shortPopular {
                            Button(showsAllPopular ? String(localized: "Weniger") : String(localized: "Mehr anzeigen")) {
                                withAnimation { showsAllPopular.toggle() }
                            }
                            .font(.subheadline)
                        }
                    }
                    songList(showsAllPopular ? popular : Array(popular.prefix(Self.shortPopular)), tracks: tracks, numbered: true)
                }
                let fresh = Array(unique(catalog.latest.filter { $0.kind == "song" }).prefix(Self.newSongs))
                if !fresh.isEmpty {
                    SectionHeader(String(localized: "Neue Songs"))
                    songList(fresh, tracks: tracks, numbered: false)
                }
                let recent = Array(releases.dropFirst().prefix(Self.recentReleases))
                if !recent.isEmpty {
                    SectionHeader(String(localized: "Neu erschienen"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(recent) { card($0, albums: albums).frame(width: 140) }
                        }
                        .padding(.horizontal)
                    }
                }
                let singles = catalog.singles ?? []
                if !catalog.albums.isEmpty || !singles.isEmpty {
                    SectionHeader(String(localized: "Diskografie"))
                    if !catalog.albums.isEmpty && !singles.isEmpty {
                        Picker(String(localized: "Diskografie"), selection: $showsSingles) {
                            Text(String(localized: "Alben")).tag(false)
                            Text(String(localized: "Singles & EPs")).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                    }
                    let shown = (showsSingles && !singles.isEmpty) || catalog.albums.isEmpty ? singles : catalog.albums
                    LazyVGrid(columns: MediaGrid.covers, alignment: .leading, spacing: 16) {
                        ForEach(shown) { card($0, albums: albums) }
                    }
                    .padding(.horizontal)
                }
            } else {
                fallback
            }
        }
        .task(id: name) { await load() }
        .task(id: jobs.watchKey(scenePhase)) { await jobs.watch(model: model, phase: scenePhase) }
    }

    private func songList(_ results: [MusicSearchResult], tracks: [String: Media], numbered: Bool) -> some View {
        let queue = results.compactMap { tracks[catalogKey($0.title)] }
        return LazyVStack(spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.element.id) { position, result in
                HStack(spacing: 6) {
                    if numbered {
                        Text("\(position + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                    }
                    if let track = tracks[catalogKey(result.title)] {
                        MediaRow(media: track, queue: queue)
                    } else {
                        row(result)
                    }
                }
                .padding(.horizontal)
                Divider().padding(.leading, numbered ? 100 : 72)
            }
        }
    }

    /// Groß wie bei Spotify: Cover, Erscheinungstag, Titel und Art.
    @ViewBuilder private func newestRelease(_ result: MusicSearchResult, albums: [String: Album]) -> some View {
        let label = HStack(spacing: 14) {
            CatalogCover(address: result.cover, large: true)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 5, y: 3)
            VStack(alignment: .leading, spacing: 4) {
                if let date = result.releaseDate {
                    Text(date.formatted(.dateTime.day().month(.abbreviated).year()))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(result.title).font(.headline).lineLimit(2)
                Text([result.releaseLabel, result.trackCount.map { String(localized: "\($0) Titel") }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        if let album = albums[catalogKey(result.title)] {
            NavigationLink { AlbumDetailView(initial: album) } label: { label }.buttonStyle(.plain)
        } else {
            NavigationLink { MusicPreviewView(result: result) } label: { label }.buttonStyle(.plain)
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        catalog = try? await api.get("/v1/music/artist", query: [URLQueryItem(name: "name", value: name)])
    }

    private func row(_ result: MusicSearchResult) -> some View {
        NavigationLink { MusicPreviewView(result: result) } label: {
            HStack(spacing: 12) {
                CatalogCover(address: result.cover).frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .opacity(0.75)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text([result.album, result.year].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if result.explicit == true { ExplicitBadge() }
                if jobs.active(result) {
                    JobClock().font(.body).frame(width: 32, height: 44)
                } else {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .frame(width: 32, height: 44)
                }
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func card(_ result: MusicSearchResult, albums: [String: Album]) -> some View {
        if let album = albums[catalogKey(result.title)] {
            NavigationLink { AlbumDetailView(initial: album) } label: { AlbumCard(album: album) }
                .buttonStyle(.plain)
        } else {
            NavigationLink { MusicPreviewView(result: result) } label: {
                cardLabel(result).overlay(alignment: .topTrailing) {
                    if jobs.active(result) {
                        JobClock()
                            .font(.footnote.weight(.semibold))
                            .frame(width: 30, height: 30)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(4)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func cardLabel(_ result: MusicSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CatalogCover(address: result.cover, large: true)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 5, y: 3)
            Text(result.title).font(.caption.weight(.semibold)).lineLimit(1)
            Text([result.releaseLabel, result.year].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

private struct MusicPreview: Decodable {
    let item: MusicSearchResult
    let tracks: [MusicPreviewTrack]
}

/// Schon geöffnete Titellisten, damit ein zweites Antippen sofort etwas zeigt.
@MainActor
private enum MusicPreviewCache {
    private static let limit = 60
    private static var stored: [String: MusicPreview] = [:]
    private static var order: [String] = []

    static func key(_ result: MusicSearchResult) -> String { "\(result.kind)-\(result.id)" }
    static func preview(for result: MusicSearchResult) -> MusicPreview? { stored[key(result)] }
    static func keep(_ preview: MusicPreview, for result: MusicSearchResult) {
        let key = key(result)
        if stored.updateValue(preview, forKey: key) == nil { order.append(key) }
        while order.count > limit { stored[order.removeFirst()] = nil }
    }
}

private struct MusicPreviewTrack: Decodable, Identifiable {
    let id: UInt64
    let title: String
    let artist: String?
    let seconds: Int?
    let explicit: Bool
}

/// Zeigt, was geladen würde. Erst der Knopf hier schickt den Auftrag an den Server.
struct MusicPreviewView: View {
    let result: MusicSearchResult
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var jobs = MusicJobs()
    @State private var preview: MusicPreview?
    @State private var failed = false

    private var item: MusicSearchResult { preview?.item ?? result }
    private var job: MusicJob? { jobs.jobs.first { $0.itemId == item.id && $0.kind == item.kind } }

    /// Titles of this artist's songs that are already on the server, in comparable form.
    private var titlesOnServer: Set<String> {
        let artist = Self.comparable(item.artist ?? "")
        return Set(model.items.lazy.filter { media in
            media.kind == "audio" && (artist.isEmpty || media.allArtists.contains { Self.comparable($0) == artist })
        }.map { Self.comparable(Self.withoutGuests($0.title)) })
    }
    private func isOnServer(_ track: MusicPreviewTrack) -> Bool {
        titlesOnServer.contains(Self.comparable(Self.withoutGuests(track.title)))
    }
    private var missing: Int { preview?.tracks.filter { !isOnServer($0) }.count ?? 0 }

    /// "André 3000" and "Andre 3000", "Numb" and "NUMB" compare equal.
    private static func comparable(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }
    private static func withoutGuests(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*[\(\[]\s*(feat|ft)\b[^\)\]]*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    var body: some View {
        List {
            Section { header }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            if let preview {
                Section(String(localized: "Titel")) {
                    ForEach(Array(preview.tracks.enumerated()), id: \.element.id) { position, track in
                        row(track, position: position + 1)
                    }
                }
            } else if failed {
                Text(String(localized: "Die Titelliste ließ sich nicht laden.")).foregroundStyle(.orange)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .miniPlayerRoom()
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: result.id) { await load() }
        .task(id: jobs.watchKey(scenePhase)) { await jobs.watch(model: model, phase: scenePhase) }
    }

    private var header: some View {
        VStack(spacing: 10) {
            CatalogCover(address: item.cover, large: true)
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(item.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(item.details).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let job {
                if job.state == "running", job.total > 0 {
                    ProgressView(value: Double(job.done), total: Double(job.total))
                }
                Text(job.statusText).font(.caption).foregroundStyle(job.state == "failed" ? .orange : .secondary)
                    .multilineTextAlignment(.center)
            }
            if job?.isActive != true {
                let count = preview?.tracks.count ?? 0
                Button { Task { await jobs.request(item, api: model.api) } } label: {
                    Group {
                        if preview != nil && missing == 0 {
                            Label(String(localized: "Schon auf dem Server"), systemImage: "checkmark.circle")
                        } else if preview != nil && missing < count {
                            Label(String(localized: "Fehlende \(missing) laden"), systemImage: "icloud.and.arrow.down")
                        } else {
                            Label(String(localized: "Auf den Server laden"), systemImage: "icloud.and.arrow.down")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!jobs.available || preview == nil || missing == 0)
            }
            if let problem = jobs.problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            Text(String(localized: "Geladen wird die Originalaufnahme, wenn es sie gibt unzensiert, höchstens 5 Sekunden länger oder kürzer als im Katalog. Gibt es keine unzensierte, kommt die beste andere Fassung und ist in der App als „zensiert“ markiert."))
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ track: MusicPreviewTrack, position: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(position)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(2)
                if let artist = track.artist, artist != item.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if track.explicit { ExplicitBadge() }
            if isOnServer(track) {
                Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.mint)
                    .accessibilityLabel(String(localized: "Schon auf dem Server"))
            }
            if let seconds = track.seconds {
                Text(clockText(seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        failed = false
        // Ein Song ist seine eigene Titelliste; alles dafür kam schon mit der Suche.
        if result.kind == "song" {
            preview = MusicPreview(item: result, tracks: [MusicPreviewTrack(
                id: result.id, title: result.title, artist: result.artist,
                seconds: result.seconds, explicit: result.explicit ?? false)])
            return
        }
        if let kept = MusicPreviewCache.preview(for: result) { preview = kept }
        guard let api = model.api else { return }
        do {
            let loaded: MusicPreview = try await api.get("/v1/music/preview", query: [
                URLQueryItem(name: "kind", value: result.kind), URLQueryItem(name: "id", value: String(result.id))
            ])
            preview = loaded
            MusicPreviewCache.keep(loaded, for: result)
        } catch {
            if !Task.isCancelled && preview == nil { failed = true }
        }
    }
}

/// Suche und Download laufen auf dem Server. Das iPhone überträgt nur die kurzen
/// Antworten und kleine Cover, die Songs erst beim Abspielen.
struct MusicFinderView: View {
    @EnvironmentObject private var model: AppModel
    @State private var words = ""
    @AppStorage("mediaserver.musicFinderKind") private var kind = "song"
    @State private var results: [MusicSearchResult] = []
    @State private var searching = false
    @State private var searched = false
    @StateObject private var store = MusicJobs()
    @Environment(\.scenePhase) private var scenePhase

    /// Sucht erst, wenn beim Tippen kurz Ruhe ist: spart Datenvolumen und Anfragen an den Katalog.
    private static let typingPause = 0.5

    var body: some View {
        List {
            if !store.available {
                Section {
                    Text(String(localized: "Auf diesem Server ist das Laden von Musik noch nicht eingerichtet."))
                }
            } else if !store.serviceOnline {
                Section {
                    Label(String(localized: "Der Musik-Dienst auf dem Server läuft gerade nicht. Aufträge warten, bis er wieder da ist."),
                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Section {
                Picker(String(localized: "Art"), selection: $kind) {
                    Text(String(localized: "Song")).tag("song")
                    Text(String(localized: "Album")).tag("album")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(String(localized: "Der Server sucht und lädt selbst. Das braucht auf dem iPhone kaum Datenvolumen und läuft weiter, wenn du die App schließt.").forThisDevice)
            }
            if let problem = store.problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            // Die Treffer zuerst, damit sie beim Tippen über der Tastatur zu sehen sind.
            if !results.isEmpty {
                Section(String(localized: "Ergebnisse")) {
                    ForEach(results) { result in row(result) }
                }
            } else if searching {
                ProgressView()
            } else if searched {
                SearchEmptyView(query: words)
            }
            if !store.jobs.isEmpty {
                Section(String(localized: "Aufträge")) {
                    ForEach(store.jobs) { job in row(job) }
                }
            }
        }
        .miniPlayerRoom()
        .navigationTitle(String(localized: "Musik finden"))
        .searchable(text: $words, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: String(localized: "Künstler, Album oder Song"))
        .scrollDismissesKeyboard(.immediately)
        .task(id: "\(kind)|\(words)") { await searchWhileTyping() }
        .task(id: store.watchKey(scenePhase)) { await store.watch(model: model, phase: scenePhase) }
    }

    private func row(_ result: MusicSearchResult) -> some View {
        NavigationLink { MusicPreviewView(result: result) } label: {
            HStack(spacing: 12) {
                cover(result.cover)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).lineLimit(2)
                    Text(result.details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if result.explicit == true { ExplicitBadge() }
                if store.active(result) { JobClock() }
            }
        }
    }

    private func row(_ job: MusicJob) -> some View {
        HStack(spacing: 12) {
            cover(job.cover)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).lineLimit(1)
                if job.state == "running", job.total > 0 {
                    ProgressView(value: Double(job.done), total: Double(job.total))
                }
                Text(job.statusText).font(.caption).foregroundStyle(job.state == "failed" ? .orange : .secondary)
            }
        }
        .swipeActions {
            Button(job.isActive ? String(localized: "Abbrechen") : String(localized: "Entfernen"), role: .destructive) {
                Task { await store.remove(job, model: model) }
            }
        }
    }

    private func cover(_ address: String?) -> some View {
        CatalogCover(address: address)
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// SwiftUI bricht diesen Aufruf bei jedem neuen Buchstaben ab.
    private func searchWhileTyping() async {
        let wanted = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wanted.count >= 2 else {
            results = []
            searched = false
            store.problem = nil
            return
        }
        try? await Task.sleep(for: .seconds(Self.typingPause))
        guard !Task.isCancelled else { return }
        await search(wanted)
    }

    private func search(_ wanted: String) async {
        guard let api = model.api else { return }
        let requested = kind
        searching = true
        defer { searching = false }
        do {
            let response: MusicSearchResponse = try await api.get("/v1/music/search", query: [
                URLQueryItem(name: "q", value: wanted), URLQueryItem(name: "kind", value: kind)
            ])
            guard !Task.isCancelled, requested == kind else { return }
            results = response.results
            searched = true
            store.problem = nil
        } catch {
            if !Task.isCancelled { store.problem = String(localized: "Die Suche hat nicht geklappt: \(error.localizedDescription)") }
        }
    }
}
