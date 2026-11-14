import SwiftUI

struct MusicView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var personal: Personal
    @AppStorage("mediaserver.musicCategory") private var category = 1
    @State private var search = ""
    @State private var creatingPlaylist = false

    private var tracks: [Media] {
        model.items.filter { $0.kind == "audio" && (search.isEmpty || "\($0.title) \($0.subtitle)".localizedCaseInsensitiveContains(search)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    /// Lieblingsalben zuerst, sonst das zuletzt hinzugefügte oben.
    private var albums: [Album] {
        let found = search.isEmpty ? model.albums : model.albums.filter { album in
            "\(album.title) \(album.artist ?? "")".localizedCaseInsensitiveContains(search)
                || album.tracks.contains { $0.title.localizedCaseInsensitiveContains(search) }
        }
        return found.map { (album: $0, favorite: personal.isFavorite($0), added: $0.addedAt) }
            .sorted { $0.favorite != $1.favorite ? $0.favorite : $0.added > $1.added }
            .map(\.album)
    }
    private var artists: [String] {
        model.artists.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
    }
    private var isEmpty: Bool {
        switch category {
        case 1: albums.isEmpty
        case 2: artists.isEmpty
        case 3: false
        default: tracks.isEmpty
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ConnectionBanner().padding(.horizontal)
                Picker(String(localized: "Ansicht"), selection: $category) {
                    Text(String(localized: "Titel")).tag(0); Text(String(localized: "Alben")).tag(1); Text(String(localized: "Interpreten")).tag(2); Text(String(localized: "Playlists")).tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                if isEmpty {
                    Group {
                        if !search.isEmpty { SearchEmptyView(query: search) }
                        else if model.isOffline { NothingDownloadedView() }
                        else if model.loading { ProgressView(String(localized: "Musik wird geladen …")) }
                        else {
                            ContentUnavailableView(String(localized: "Noch keine Musik"), systemImage: "music.note",
                                                   description: Text(String(localized: "Kopiere einen Ordner pro Album in „Musik“. Ein Bild im Ordner (z. B. cover.jpg) wird zum Albumcover.")))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    switch category {
                    case 1:
                        let sorted = albums
                        let favorites = sorted.filter { personal.isFavorite($0) }
                        if search.isEmpty && !favorites.isEmpty {
                            SectionHeader(String(localized: "Lieblingsalben"))
                            AlbumGrid(albums: favorites).padding(.horizontal)
                            SectionHeader(String(localized: "Weitere Alben"))
                            AlbumGrid(albums: Array(sorted.dropFirst(favorites.count))).padding(.horizontal)
                        } else {
                            AlbumGrid(albums: sorted).padding(.horizontal)
                        }
                    case 2: ArtistGrid(artists: artists).padding(.horizontal)
                    case 3: PlaylistRows(search: search).padding(.horizontal)
                    default:
                        // A song found by search plays on with similar songs, not with the other hits.
                        TrackList(tracks: tracks, queueOnPlay: search.isEmpty ? nil : { [$0] + model.items.similarSongs(to: $0) })
                    }
                }
                if let notice = model.notice, !model.isOffline {
                    Text(notice).font(.caption).foregroundStyle(.orange).padding(.horizontal)
                }
            }
            .padding(.vertical, 8)
        }
        .miniPlayerRoom()
        .navigationTitle("Musik")
        // Fest oben: Unten läge das Feld hinter dem Mini-Player und der Tastatur.
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Titel, Album, Interpret")
        .scrollDismissesKeyboard(.immediately)
        .refreshableWhenOnline()
        .toolbar {
            if model.loading { ProgressView() }
            if category == 3 && !model.isOffline {
                Button { creatingPlaylist = true } label: { Image(systemName: "plus").accessibilityLabel(String(localized: "Playlist erstellen")) }
            }
            if !model.isOffline {
                NavigationLink { MusicFinderView() } label: {
                    Image(systemName: "plus.magnifyingglass").accessibilityLabel(String(localized: "Musik finden"))
                }
            }
        }
        .sheet(isPresented: $creatingPlaylist) { PlaylistEditor(playlist: nil).environmentObject(model) }
    }
}

struct TrackList: View {
    let tracks: [Media]
    var numbered = false
    /// An album or playlist with its own shuffle and repeat settings.
    var collection: String? = nil
    var onPlay: (() -> Void)? = nil
    /// What plays after a tapped song, if not the rest of this list.
    var queueOnPlay: ((Media) -> [Media])? = nil
    @EnvironmentObject private var playback: PlayerModel

    private func rowStarted() {
        if let collection { playback.applySettings(ofCollection: collection) }
        onPlay?()
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            Group {
                if let collection {
                    CollectionPlayButtons(tracks: tracks, collection: collection, onPlay: onPlay)
                } else {
                    PlayButtons(tracks: tracks, onPlay: onPlay)
                }
            }
            .padding(.horizontal).padding(.bottom, 10)
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                MediaRow(media: track, queue: tracks, number: numbered ? (track.trackNumber ?? index + 1) : nil, showsArtwork: !numbered, onPlay: rowStarted, queueOnPlay: queueOnPlay)
                    .padding(.horizontal)
                Divider().padding(.leading, numbered ? 56 : 72)
            }
        }
    }
}

struct AlbumGrid: View {
    let albums: [Album]
    @EnvironmentObject private var personal: Personal
    var body: some View {
        LazyVGrid(columns: MediaGrid.covers, alignment: .leading, spacing: 16) {
            ForEach(albums) { album in
                NavigationLink { AlbumDetailView(initial: album) } label: { AlbumCard(album: album) }
                    .buttonStyle(.plain)
                    .contextMenu { AlbumFavoriteButton(album: album) }
            }
        }
    }
}

/// Markiert ein Album als Lieblingsalbum; es steht dann unter Musik → Alben ganz oben.
struct AlbumFavoriteButton: View {
    let album: Album
    @EnvironmentObject private var personal: Personal
    var body: some View {
        let favorite = personal.isFavorite(album)
        Button { personal.toggleFavorite(album) } label: {
            Label(favorite ? String(localized: "Kein Lieblingsalbum mehr") : String(localized: "Lieblingsalbum"),
                  systemImage: favorite ? "heart.slash" : "heart")
        }
    }
}

struct AlbumCard: View {
    let album: Album
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkView(id: album.coverId, symbol: "square.stack", cornerRadius: 8, title: album.title)
                .shadow(color: .black.opacity(0.3), radius: 5, y: 3)
            Text(album.title).font(.caption.weight(.semibold)).lineLimit(1)
            Text(album.artist ?? String(localized: "\(album.tracks.count) Titel")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

struct ArtistGrid: View {
    let artists: [String]
    @EnvironmentObject private var model: AppModel
    var body: some View {
        LazyVGrid(columns: MediaGrid.artists, spacing: 14) {
            ForEach(artists, id: \.self) { name in
                NavigationLink { ArtistDetailView(name: name) } label: {
                    VStack(spacing: 6) {
                        ArtworkView(id: model.artistInfo(name)?.image ?? model.artistAlbums(name).first?.coverId,
                                    symbol: "person.fill", cornerRadius: 0, title: nil)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                        Text(name).font(.caption2.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AlbumDetailView: View {
    let initial: Album
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var personal: Personal
    @Environment(\.dismiss) private var dismiss
    @State private var creatingPlaylist = false
    @State private var confirmingDelete = false
    private var album: Album { model.albums.first { $0.id == initial.id } ?? initial }
    private var info: AlbumInfo? { model.albumInfo(album) }
    private var meta: String {
        let total = album.tracks.compactMap(\.duration).reduce(0, +)
        return [info?.genre, info?.year, String(localized: "\(album.tracks.count) Titel"), total > 0 ? String(localized: "\(Int(total / 60)) Min.") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ArtworkView(id: album.coverId, symbol: "square.stack", cornerRadius: 14, title: album.title)
                    .frame(maxWidth: 190)
                    .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                    .padding(.top, 8)
                VStack(spacing: 6) {
                    Text(album.title).font(.title2.bold()).multilineTextAlignment(.center)
                    if let artist = album.artist {
                        NavigationLink { ArtistDetailView(name: artist) } label: {
                            HStack(spacing: 8) {
                                ArtworkView(id: model.artistInfo(artist)?.image, symbol: "person.fill", cornerRadius: 0)
                                    .frame(width: 30, height: 30)
                                    .clipShape(Circle())
                                Text(artist).font(.title3).foregroundStyle(.mint)
                            }
                        }
                    }
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                if let description = info?.description {
                    ExpandableText(text: description, url: info?.wikipediaUrl, lines: 3).padding(.horizontal)
                }
                TrackList(tracks: album.tracks, numbered: true, collection: album.id) { personal.recordAlbumPlay(album.id) }
                if let copyright = info?.copyright {
                    Text(copyright).font(.caption2).foregroundStyle(.tertiary).padding(.horizontal)
                }
            }
            .padding(.bottom, 24)
        }
        .background { ArtworkBackdrop(id: album.coverId) }
        .miniPlayerRoom()
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let favorite = personal.isFavorite(album)
                Button { personal.toggleFavorite(album) } label: {
                    Image(systemName: favorite ? "heart.fill" : "heart")
                        .accessibilityLabel(favorite ? String(localized: "Kein Lieblingsalbum mehr") : String(localized: "Lieblingsalbum"))
                }
            }
            ToolbarItem(placement: .topBarTrailing) { DownloadAllButton(tracks: album.tracks) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    AlbumFavoriteButton(album: album)
                    AddToPlaylistMenu(tracks: album.tracks, showCreate: $creatingPlaylist)
                    if model.canDeleteFromServer {
                        Divider()
                        DeleteFromServerButton(isConfirming: $confirmingDelete)
                    }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(String(localized: "Albumaktionen")) }
            }
        }
        .newPlaylistAlert(isPresented: $creatingPlaylist, tracks: album.tracks)
        .deleteFromServer(isPresented: $confirmingDelete, items: album.tracks, name: album.title) { dismiss() }
    }
}

struct ArtistDetailView: View {
    let name: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var personal: Personal
    @State private var creatingPlaylist = false
    @State private var showingImage = false
    private var info: ArtistInfo? { model.artistInfo(name) }
    private var albums: [Album] { model.artistAlbums(name) }
    private var tracks: [Media] { model.artistTracks(name) }
    private var imageID: String? { info?.image ?? albums.first?.coverId ?? model.featuredTracks(name).first.flatMap { model.artworkID(for: $0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 8) {
                    Button { showingImage = true } label: {
                        ArtworkView(id: imageID, symbol: "person.fill", cornerRadius: 0)
                            .frame(width: 120, height: 120)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(imageID == nil)
                    .accessibilityLabel(String(localized: "Bild von \(name) groß anzeigen"))
                    Text(name).font(.title.bold()).multilineTextAlignment(.center)
                    if let subtitle = [info?.genre, info?.shortDescription].compactMap({ $0 }).first {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.top, 8)
                if let description = info?.description {
                    ExpandableText(text: description, url: info?.wikipediaUrl).padding(.horizontal)
                }
                let liked = personal.favoriteTracks(in: model.mediaByID).filter { $0.allArtists.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
                if !liked.isEmpty {
                    SectionHeader(String(localized: "Deine Lieblingssongs"))
                    TrackList(tracks: liked)
                }
                ArtistCatalogSections(name: name) { ArtistLibrarySections(name: name) }
                if !tracks.isEmpty {
                    SectionHeader(String(localized: "Deine Titel"))
                    TrackList(tracks: tracks)
                }
                let guest = model.featuredTracks(name)
                if !guest.isEmpty {
                    SectionHeader(String(localized: "Auch dabei bei"))
                    LazyVStack(spacing: 0) {
                        ForEach(guest) { track in
                            MediaRow(media: track, queue: guest).padding(.horizontal)
                            Divider().padding(.leading, 72)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background { ArtworkBackdrop(id: imageID) }
        .miniPlayerRoom()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { DownloadAllButton(tracks: tracks) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    AddToPlaylistMenu(tracks: tracks, showCreate: $creatingPlaylist)
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(String(localized: "Interpretenaktionen")) }
            }
        }
        .newPlaylistAlert(isPresented: $creatingPlaylist, tracks: tracks)
        .fullScreenCover(isPresented: $showingImage) {
            if let imageID { LargeArtworkView(id: imageID, title: name).environmentObject(model) }
        }
    }
}

/// Ein Bild bildschirmfüllend, zum Vergrößern mit zwei Fingern; Tippen oder Wischen schließt es.
struct LargeArtworkView: View {
    let id: String
    let title: String
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var drag: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(abs(drag.height) / 400, 0.6)).ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(max(1, zoom * pinch))
                    .offset(drag)
                    .gesture(MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in withAnimation { zoom = min(4, max(1, zoom * value.magnification)) } })
                    .simultaneousGesture(DragGesture()
                        .onChanged { value in if zoom <= 1 { drag = value.translation } }
                        .onEnded { value in
                            if zoom <= 1 && abs(value.translation.height) > 120 { dismiss() }
                            else { withAnimation { drag = .zero } }
                        })
                    .onTapGesture(count: 2) { withAnimation { zoom = zoom > 1 ? 1 : 2 } }
                    .accessibilityLabel(title)
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
            .accessibilityLabel(String(localized: "Schließen"))
        }
        .task(id: id) {
            image = ArtworkCache.shared.cached(id, scope: model.downloadScope)
            if image == nil { image = await ArtworkCache.shared.image(id, model: model) }
        }
    }
}

/// An artist's page from what is in the library: what is new, what is heard most, the albums.
struct ArtistLibrarySections: View {
    private static let shownPopular = 10
    let name: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var personal: Personal

    var body: some View {
        let albums = model.artistAlbums(name)
        let popular = model.artistTracks(name).sorted { personal.plays($0) == personal.plays($1) ? $0.modified > $1.modified : personal.plays($0) > personal.plays($1) }
            .prefix(Self.shownPopular).map { $0 }
        if !popular.isEmpty {
            SectionHeader(String(localized: "Songs"))
            LazyVStack(spacing: 0) {
                ForEach(popular) { track in
                    MediaRow(media: track, queue: popular).padding(.horizontal)
                    Divider().padding(.leading, 72)
                }
            }
        }
        if !albums.isEmpty {
            SectionHeader(String(localized: "Alben"))
            LazyVGrid(columns: MediaGrid.covers, alignment: .leading, spacing: 16) {
                ForEach(albums) { album in link(album) }
            }
            .padding(.horizontal)
        }
    }

    private func link(_ album: Album) -> some View {
        NavigationLink { AlbumDetailView(initial: album) } label: { AlbumCard(album: album) }
            .buttonStyle(.plain)
            .contextMenu {
                Button(String(localized: "Alle herunterladen"), systemImage: "arrow.down.circle") {
                    Task { await model.downloadAll(album.tracks) }
                }
            }
    }
}
