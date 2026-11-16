import SwiftUI

/// Start tab: what can be carried on with and the music heard lately or most.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var personal: Personal

    private static let shelfLimit = 4

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: String(localized: "Guten Morgen")
        case 11..<17: String(localized: "Hallo")
        case 17..<22: String(localized: "Guten Abend")
        default: String(localized: "Gute Nacht")
        }
    }
    private var isEmpty: Bool { model.items.filter { $0.kind != "file" }.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ConnectionBanner().padding(.horizontal)
                if model.isOffline { downloadedShelves } else {
                if isEmpty {
                    Group {
                        if model.loading { ProgressView(String(localized: "Bibliothek wird geladen …")) }
                        else {
                            ContentUnavailableView(String(localized: "Willkommen"), systemImage: "sparkles.tv",
                                                   description: Text(String(localized: "Kopiere Musik, Filme und Serien auf deinen Server. Sie erscheinen hier automatisch.")))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                }
                let videos = personal.continueWatching(in: model.mediaByID, series: model.seriesGroups, resume: model.resumeSeconds, limit: Self.shelfLimit)
                let music = personal.collectionsToHear(playlists: model.playlists, albums: model.albums, limit: Self.shelfLimit)
                let fresh = Array(model.newAlbumsFromFollowed.prefix(Self.shelfLimit))
                if !isEmpty && videos.isEmpty && music.isEmpty && fresh.isEmpty {
                    ContentUnavailableView(String(localized: "Noch nichts gespielt"), systemImage: "play.circle",
                                           description: Text(String(localized: "Hier erscheinen deine zuletzt geschauten Videos und deine meistgehörte Musik.")))
                        .frame(maxWidth: .infinity, minHeight: 360)
                }
                if !videos.isEmpty {
                    field(String(localized: "Weiterschauen")) {
                        ForEach(videos) { ContinueCard(media: $0) }
                    }
                }
                if !fresh.isEmpty {
                    field(String(localized: "Neu von deinen Künstlern")) {
                        ForEach(fresh) { tile(.album($0)) }
                    }
                }
                if !music.isEmpty {
                    field(String(localized: "Oft und zuletzt gehört")) {
                        ForEach(music) { tile($0) }
                    }
                }
                }
                if let notice = model.notice, !model.isOffline {
                    Text(notice).font(.caption).foregroundStyle(.orange).padding(.horizontal)
                }
            }
            .padding(.vertical, 8)
        }
        .miniPlayerRoom()
        .navigationTitle(greeting)
        .refreshableWhenOnline()
        .toolbar {
            if !model.isOffline {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { UploadView() } label: { Image(systemName: "plus").accessibilityLabel(String(localized: "Hochladen")) }
                }
            }
            if model.loading { ToolbarItem(placement: .topBarLeading) { ProgressView() } }
        }
    }

    /// Without a connection: everything on this iPhone instead of what was played lately.
    @ViewBuilder private var downloadedShelves: some View {
        // Only what lies on this iPhone counts here, also for the episode to go on with;
        // the rest of the library stays visible elsewhere to be marked for Wi-Fi.
        let local = Dictionary(model.offline.map { ($0.id, model.mediaByID[$0.id] ?? $0.media) }, uniquingKeysWith: { first, _ in first })
        let albums = model.albums.filter { $0.tracks.contains { local[$0.id] != nil } }
        let shows = model.seriesGroups.filter { $0.seasons.contains { $0.episodes.contains { local[$0.id] != nil } } }
        let movies = local.values.filter { $0.kind == "video" && $0.series == nil }.sorted { $0.title < $1.title }
        if albums.isEmpty && shows.isEmpty && movies.isEmpty {
            NothingDownloadedView().frame(maxWidth: .infinity, minHeight: 360)
        }
        let videos = personal.continueWatching(in: local, series: shows, resume: model.resumeSeconds, limit: Self.shelfLimit)
        if !videos.isEmpty {
            field(String(localized: "Weiterschauen")) {
                ForEach(videos) { ContinueCard(media: $0) }
            }
        }
        if !albums.isEmpty {
            shelf(String(localized: "Heruntergeladene Musik")) {
                ForEach(albums) { album in
                    NavigationLink { AlbumDetailView(initial: album) } label: { AlbumCard(album: album).frame(width: MediaGrid.cardWidth) }
                        .buttonStyle(.plain)
                }
            }
        }
        if !shows.isEmpty {
            shelf(String(localized: "Heruntergeladene Serien")) {
                ForEach(shows) { show in
                    NavigationLink { SeriesDetailView(initial: show) } label: {
                        PosterCard(id: show.coverId, title: show.name, subtitle: String(localized: "\(show.episodeCount) Folgen"),
                                   symbol: "tv", offline: false).frame(width: MediaGrid.cardWidth)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !movies.isEmpty {
            shelf(String(localized: "Heruntergeladene Filme")) {
                ForEach(movies) { movie in
                    NavigationLink { MovieDetailView(media: movie) } label: {
                        PosterCard(id: model.artworkID(for: movie), title: movie.title, subtitle: durationLabel(movie.duration) ?? "",
                                   symbol: "film", offline: true).frame(width: MediaGrid.cardWidth)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        let playlists = model.availablePlaylists
        if !playlists.isEmpty {
            shelf(String(localized: "Playlists")) {
                ForEach(playlists) { playlist in
                    NavigationLink { PlaylistDetail(id: playlist.id) } label: { card(playlist) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func shelf<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .padding(.horizontal)
            }
        }
    }

    private func card(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PlaylistMosaic(tracks: playlist.mediaIds.compactMap { model.mediaByID[$0] })
            Text(playlist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(model.isOffline ? playlist.mediaIds.compactMap { model.mediaByID[$0] }.count : playlist.mediaIds.count) Titel").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: MediaGrid.cardWidth)
        .contentShape(Rectangle())
    }

    /// At most two rows of two, so that both fields fit on one screen.
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder private func tile(_ collection: MusicCollection) -> some View {
        switch collection {
        case .playlist(let playlist):
            NavigationLink { PlaylistDetail(id: playlist.id) } label: {
                tileLabel(playlist.name, String(localized: "Playlist")) {
                    PlaylistMosaic(tracks: playlist.mediaIds.compactMap { model.mediaByID[$0] })
                }
            }
            .buttonStyle(.plain)
        case .album(let album):
            NavigationLink { AlbumDetailView(initial: album) } label: {
                tileLabel(album.title, album.artist ?? String(localized: "Album")) {
                    ArtworkView(id: album.coverId, symbol: "square.stack", cornerRadius: 8)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func tileLabel<Cover: View>(_ title: String, _ subtitle: String, @ViewBuilder cover: () -> Cover) -> some View {
        HStack(spacing: 10) {
            cover().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).lineLimit(2)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Automatic playlists built from local statistics.
struct AutoPlaylistView: View {
    enum Kind {
        case favorites, mostPlayed, recent, newlyAdded, rediscover

        var placeholder: String {
            switch self {
            case .favorites: "PlaylistFavorites"
            case .mostPlayed, .rediscover: "PlaylistMostPlayed"
            case .recent, .newlyAdded: "PlaylistRecent"
            }
        }
        /// Key for shuffle and repeat of this list.
        var collection: String {
            switch self {
            case .newlyAdded: "AutoNewlyAdded"
            case .rediscover: "AutoRediscover"
            default: placeholder
            }
        }
    }
    let kind: Kind
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var personal: Personal
    private var title: String {
        switch kind {
        case .favorites: String(localized: "Lieblingssongs")
        case .mostPlayed: String(localized: "Meistgehört")
        case .recent: String(localized: "Zuletzt gespielt")
        case .newlyAdded: String(localized: "Neu hinzugefügt")
        case .rediscover: String(localized: "Lange nicht gehört")
        }
    }
    private var tracks: [Media] { kind.tracks(model: model, personal: personal) }
    var body: some View {
        let list = tracks
        ScrollView {
            VStack(spacing: 16) {
                AutoPlaylistCover(kind: kind).frame(width: 150, height: 150)
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                Text(title).font(.title2.bold())
                Text("\(list.count) Titel · automatisch erstellt").font(.caption).foregroundStyle(.secondary)
                if list.isEmpty {
                    Text(kind.emptyText)
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                } else {
                    TrackList(tracks: list, collection: kind.collection)
                }
            }
            .padding(.vertical)
        }
        .miniPlayerRoom()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DownloadAllButton(tracks: tracks) }
    }
}

/// The covers of the latest four songs; a picture of its own while there are none.
struct AutoPlaylistCover: View {
    private static let shownSongs = 4
    let kind: AutoPlaylistView.Kind
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var personal: Personal

    private var tracks: [Media] {
        switch kind {
        case .favorites: personal.latestFavorites(in: model.mediaByID, limit: Self.shownSongs)
        default: Array(kind.tracks(model: model, personal: personal).prefix(Self.shownSongs))
        }
    }

    var body: some View {
        PlaylistMosaic(tracks: tracks, placeholder: kind.placeholder)
    }
}

/// Editable "Als Nächstes" list.
struct QueueView: View {
    @EnvironmentObject private var playback: PlayerModel
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let current = playback.current {
                    Section(String(localized: "Läuft gerade")) {
                        HStack(spacing: 12) {
                            ArtworkView(id: model.artworkID(for: current), symbol: current.symbol, cornerRadius: 6).frame(width: 44, height: 44)
                            VStack(alignment: .leading) {
                                Text(current.title).font(.body.weight(.semibold))
                                Text(current.artist ?? current.series ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    ForEach(playback.upNext) { media in
                        HStack(spacing: 12) {
                            ArtworkView(id: model.artworkID(for: media), symbol: media.symbol, cornerRadius: 6).frame(width: 40, height: 40)
                            VStack(alignment: .leading) {
                                Text(media.title).lineLimit(1)
                                Text(media.artist ?? media.series ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .onMove { playback.moveUpcoming(from: $0, to: $1) }
                    .onDelete { playback.removeUpcoming(at: $0) }
                    if playback.upNext.isEmpty {
                        Text(String(localized: "Nichts in der Warteschlange. Füge Songs über ihr …-Menü mit „Als Nächstes spielen“ hinzu."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text(String(localized: "Als Nächstes"))
                        Spacer()
                        if !playback.upNext.isEmpty {
                            Button(String(localized: "Leeren"), role: .destructive) { playback.clearUpcoming() }.font(.caption)
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(String(localized: "Warteschlange"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(String(localized: "Fertig")) { dismiss() } } }
        }
    }
}

extension AutoPlaylistView.Kind {
    private static let listLimit = 50
    /// Played this often, the song is a favourite; untouched this long, it is worth hearing again.
    private static let rediscoverPlays = 3
    private static let rediscoverDays = 30.0

    @MainActor func tracks(model: AppModel, personal: Personal) -> [Media] {
        switch self {
        case .favorites: return personal.favoriteTracks(in: model.mediaByID)
        case .mostPlayed: return personal.mostPlayed(in: model.mediaByID)
        case .recent: return personal.recentlyPlayed(in: model.mediaByID)
        case .newlyAdded:
            return Array(model.items.filter { $0.kind == "audio" }
                .sorted { $0.addedAt != $1.addedAt ? $0.addedAt > $1.addedAt : $0.path < $1.path }
                .prefix(Self.listLimit))
        case .rediscover:
            let limit = Date().timeIntervalSince1970 - Self.rediscoverDays * 86_400
            return Array(model.items.filter { media in
                media.kind == "audio" && personal.plays(media) >= Self.rediscoverPlays
                    && (personal.lastPlayed[media.id] ?? 0) < limit
            }
            .sorted { personal.plays($0) > personal.plays($1) }
            .prefix(Self.listLimit))
        }
    }

    var emptyText: String {
        switch self {
        case .favorites: String(localized: "Tippe beim Song auf das Herz, um ihn hier zu sammeln.")
        case .newlyAdded: String(localized: "Neue Musik auf dem Server erscheint hier.")
        case .rediscover: String(localized: "Songs, die du oft gehört hast, erscheinen hier, wenn du sie einen Monat nicht mehr gespielt hast.")
        default: String(localized: "Höre Musik, dann erscheint sie hier.")
        }
    }
}
