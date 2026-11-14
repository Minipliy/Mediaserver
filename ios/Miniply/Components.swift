import SwiftUI

/// Without a connection there is nothing to pull down for: the banner offers to reconnect.
private struct OnlineRefresh: ViewModifier {
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        if model.isOffline {
            content.scrollBounceBehavior(.basedOnSize)
        } else {
            content.refreshable { await model.refresh() }
        }
    }
}

extension View {
    func refreshableWhenOnline() -> some View { modifier(OnlineRefresh()) }
}

/// Sizes of covers and posters, so that much fits on one screen.
enum MediaGrid {
    static let covers = [GridItem(.adaptive(minimum: 104), spacing: 12)]
    static let artists = [GridItem(.adaptive(minimum: 78), spacing: 12, alignment: .top)]
    static let cardWidth: CGFloat = 112
}

// MARK: Rows and actions shared by music, videos, playlists and downloads

struct MediaRow: View {
    let media: Media
    var queue: [Media] = []
    /// Track number instead of artwork (album pages).
    var number: Int? = nil
    var showsArtwork = true
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlayerModel
    @EnvironmentObject private var personal: Personal
    /// In a `List` the system's swipe actions work and take the same gesture.
    var inList = false
    var onPlay: (() -> Void)? = nil
    /// Builds the queue only on tap, for lists where it costs a look through the library.
    var queueOnPlay: ((Media) -> [Media])? = nil
    @State private var isSwiping = false
    private var isCurrent: Bool { playback.current?.id == media.id }
    private var subtitle: String {
        if media.kind == "file" { return byteLabel(media.bytes) }
        if let series = media.series { return [series, media.seasonGroup.map(displayName)].compactMap { $0 }.joined(separator: " · ") }
        return media.subtitle.isEmpty ? media.formatLabel : media.subtitle
    }

    /// Without a connection only what is on this iPhone plays.
    private var unavailable: Bool {
        model.isOffline && media.kind != "file" && model.localURL(media) == nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: activate) {
                HStack(spacing: 12) {
                    leading
                    VStack(alignment: .leading, spacing: 3) {
                        Text(media.series == nil ? media.title : (model.episodeInfo(media)?.name ?? media.episodeTitle))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isCurrent ? Color.mint : Color.primary)
                            .lineLimit(1)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if media.censored == true {
                        Text(String(localized: "zensiert"))
                            .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().stroke(Color.orange.opacity(0.6)))
                            .accessibilityLabel(String(localized: "Nur in zensierter Fassung gefunden"))
                    }
                    if personal.isFavorite(media) {
                        Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink)
                            .accessibilityLabel(String(localized: "Favorit"))
                    }
                    if model.localURL(media) != nil {
                        Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.mint)
                            .accessibilityLabel(String(localized: "Offline verfügbar"))
                    } else if model.isWaiting(media) {
                        Image(systemName: "wifi").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel(String(localized: "Wird im WLAN heruntergeladen"))
                    }
                    if media.kind == "audio", let duration = durationLabel(media.duration) {
                        Text(duration).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .opacity(unavailable ? 0.45 : 1)
            }
            .buttonStyle(PressableRowStyle())
            // Lifting the finger after a swipe must not also tap the row.
            .disabled(isSwiping)
            if model.downloading.contains(media.id) {
                LiveDownloadProgress { progress in
                    ProgressView(value: progress[media.id] ?? 0)
                        .progressViewStyle(.circular).frame(width: 22)
                        .accessibilityLabel("Download \(Int((progress[media.id] ?? 0) * 100)) Prozent")
                }
            }
            MediaActionsMenu(media: media)
        }
        .padding(.vertical, 1)
        .background(Color(.systemBackground).opacity(isSwiping ? 1 : 0))
        .modifier(QueueSwipe(enabled: media.kind == "audio" && !inList,
                             perform: { playback.addToQueue(media, model: model) }, isSwiping: $isSwiping))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if media.kind == "audio" && inList {
                Button { playback.addToQueue(media, model: model) } label: {
                    Label(String(localized: "Ans Ende der Warteschlange"), systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                .tint(.mint)
                Button { playback.playNext(media, model: model) } label: {
                    Label(String(localized: "Als Nächstes spielen"), systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(.indigo)
            }
        }
        .accessibilityAction(named: String(localized: "Ans Ende der Warteschlange")) {
            if media.kind == "audio" { playback.addToQueue(media, model: model) }
        }
    }

    @ViewBuilder private var leading: some View {
        if showsArtwork {
            ArtworkView(id: model.artworkID(for: media), symbol: media.symbol, cornerRadius: 6)
                .frame(width: 44, height: 44)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                        Image(systemName: playback.isPlaying ? "waveform" : "pause.fill")
                            .foregroundStyle(.mint).symbolEffect(.variableColor.iterative, isActive: playback.isPlaying)
                    }
                }
        } else {
            Group {
                if isCurrent {
                    Image(systemName: "waveform").foregroundStyle(.mint)
                } else {
                    Text(number.map { String($0) } ?? "–").foregroundStyle(.secondary)
                }
            }
            .font(.callout.monospacedDigit())
            .frame(width: 28)
        }
    }

    private func activate() {
        guard !isSwiping else { return }
        if unavailable {
            model.error = model.isWaiting(media)
                ? String(localized: "„\(media.title)“ wird heruntergeladen, sobald du im WLAN bist.")
                : String(localized: "Ohne Verbindung spielt nur, was auf diesem iPhone ist. Über „…“ → „Im WLAN herunterladen“ merkt sich die App den Titel.").forThisDevice
            return
        }
        if media.kind == "audio" || media.kind == "video" { onPlay?() }
        // Without a connection the queue holds only what can play.
        let list = queueOnPlay?(media) ?? queue
        let playable = model.isOffline ? list.filter { model.localURL($0) != nil } : list
        switch media.kind {
        case "audio": playback.play(media, in: playable, model: model)
        case "video": playFullscreen(media, queue: media.series != nil ? playable : [], playback: playback, model: model)
        default: break
        }
    }
}

/// "…" menu: infos, playlists, download, share, remove local copy.
struct MediaActionsMenu: View {
    let media: Media
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlayerModel
    @EnvironmentObject private var personal: Personal
    @State private var creatingPlaylist = false
    @State private var showingInfo = false
    @State private var confirmingDelete = false

    var body: some View {
        Menu {
            Button { showingInfo = true } label: { Label(String(localized: "Infos"), systemImage: "info.circle") }
            if media.kind == "audio" {
                Button { personal.toggleFavorite(media) } label: {
                    personal.isFavorite(media)
                        ? Label(String(localized: "Aus Lieblingssongs entfernen"), systemImage: "heart.slash")
                        : Label(String(localized: "Zu Lieblingssongs"), systemImage: "heart")
                }
                Button { playback.playNext(media, model: model) } label: { Label(String(localized: "Als Nächstes spielen"), systemImage: "text.line.first.and.arrowtriangle.forward") }
                Button { playback.addToQueue(media, model: model) } label: { Label(String(localized: "Ans Ende der Warteschlange"), systemImage: "text.line.last.and.arrowtriangle.forward") }
                AddToPlaylistMenu(tracks: [media], showCreate: $creatingPlaylist)
            }
            if media.kind == "video" {
                SubtitleMenu(media: media)
                Button { personal.setWatched(media, !personal.isWatched(media)) } label: {
                    personal.isWatched(media)
                        ? Label(String(localized: "Als nicht gesehen markieren"), systemImage: "eye.slash")
                        : Label(String(localized: "Als gesehen markieren"), systemImage: "checkmark.circle")
                }
            }
            Divider()
            if model.pausedDownloads.contains(media.id) {
                Button(String(localized: "Download fortsetzen"), systemImage: "play.circle") { Task { await model.resumeDownload(media) } }
                Button(String(localized: "Download abbrechen"), systemImage: "xmark.circle", role: .destructive) { Task { await model.cancelDownload(media) } }
            } else if model.downloading.contains(media.id) {
                Button(String(localized: "Download pausieren"), systemImage: "pause.circle") { Task { await model.pauseDownload(media) } }
                Button(String(localized: "Download abbrechen"), systemImage: "xmark.circle", role: .destructive) { Task { await model.cancelDownload(media) } }
            } else if model.isWaiting(media) {
                Button(String(localized: "Nicht mehr vormerken"), systemImage: "xmark.circle", role: .destructive) { model.stopWaiting(media) }
            } else if model.localURL(media) == nil {
                Button { Task { await model.download(media) } } label: {
                    model.mustWaitForWiFi
                        ? Label(String(localized: "Im WLAN herunterladen · \(byteLabel(media.downloadMedia.bytes))"), systemImage: "wifi")
                        : Label("Herunterladen · \(byteLabel(media.downloadMedia.bytes))", systemImage: "arrow.down.circle")
                }
            }
            if let url = model.localURL(media) {
                ShareLink(item: url) { Label(String(localized: "Datei teilen"), systemImage: "square.and.arrow.up") }
            }
            if let record = model.offline.first(where: { $0.id == media.id }) {
                Button(String(localized: "Lokale Kopie entfernen"), systemImage: "trash", role: .destructive) { model.removeDownload(record) }
            }
            if model.canDeleteFromServer {
                DeleteFromServerButton(isConfirming: $confirmingDelete)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Aktionen für \(media.title)")
        }
        .newPlaylistAlert(isPresented: $creatingPlaylist, tracks: [media])
        .deleteFromServer(isPresented: $confirmingDelete, items: [media], name: media.title)
        .sheet(isPresented: $showingInfo) { MediaInfoSheet(media: media).appObjects(model, playback, personal) }
    }
}

struct DeleteFromServerButton: View {
    @Binding var isConfirming: Bool

    var body: some View {
        Button(String(localized: "Vom Server löschen"), systemImage: "trash.fill", role: .destructive) { isConfirming = true }
    }
}

private struct DeleteFromServerDialog: ViewModifier {
    @Binding var isPresented: Bool
    let items: [Media]
    let name: String
    let onDeleted: (() -> Void)?
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlayerModel

    func body(content: Content) -> some View {
        content.confirmationDialog(String(localized: "„\(name)“ vom Server löschen?"), isPresented: $isPresented, titleVisibility: .visible) {
            Button(items.count == 1 ? String(localized: "Löschen") : String(localized: "\(items.count) Dateien löschen"), role: .destructive) {
                Task {
                    let succeeded = await model.deleteFromServer(items)
                    playback.forget(Set(items.filter { model.mediaByID[$0.id] == nil }.map(\.id)))
                    if succeeded { onDeleted?() }
                }
            }
        } message: {
            Text(String(localized: "Die Dateien verschwinden vom Server und von diesem iPhone. 14 Tage lang liegen sie noch im Papierkorb auf dem Server, danach sind sie endgültig weg.").forThisDevice)
        }
    }
}

extension View {
    func deleteFromServer(isPresented: Binding<Bool>, items: [Media], name: String, onDeleted: (() -> Void)? = nil) -> some View {
        modifier(DeleteFromServerDialog(isPresented: isPresented, items: items, name: name, onDeleted: onDeleted))
    }
}

/// Submenu: new playlist or add to an existing one.
struct AddToPlaylistMenu: View {
    let tracks: [Media]
    @Binding var showCreate: Bool
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            Button { showCreate = true } label: { Label(String(localized: "Neue Playlist …"), systemImage: "plus") }
            if !model.playlists.isEmpty { Divider() }
            ForEach(model.playlists) { playlist in
                let contained = !tracks.isEmpty && tracks.allSatisfy { playlist.mediaIds.contains($0.id) }
                Button {
                    Task { await model.add(tracks, to: playlist) }
                } label: {
                    Label(playlist.name, systemImage: contained ? "checkmark" : "music.note.list")
                }
                .disabled(contained || playlist.mediaIds.count >= 500)
            }
        } label: {
            Label(String(localized: "Zu Playlist hinzufügen"), systemImage: "text.badge.plus")
        }
        .disabled(tracks.isEmpty)
    }
}

private struct NewPlaylistAlert: ViewModifier {
    @Binding var isPresented: Bool
    let tracks: [Media]
    @EnvironmentObject private var model: AppModel
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert(String(localized: "Neue Playlist"), isPresented: $isPresented) {
            TextField(String(localized: "Name der Playlist"), text: $name)
            Button(String(localized: "Erstellen")) {
                let value = name
                name = ""
                Task { await model.createPlaylist(named: value, with: tracks) }
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(String(localized: "Abbrechen"), role: .cancel) { name = "" }
        } message: {
            if tracks.count == 1, let track = tracks.first {
                Text("„\(track.title)“ wird hinzugefügt.")
            } else if !tracks.isEmpty {
                Text("\(tracks.count) Titel werden hinzugefügt.")
            }
        }
    }
}

extension View {
    func newPlaylistAlert(isPresented: Binding<Bool>, tracks: [Media]) -> some View {
        modifier(NewPlaylistAlert(isPresented: isPresented, tracks: tracks))
    }
}

/// "Abspielen" and "Zufällig" buttons for an album, artist or playlist.
struct PlayButtons: View {
    let tracks: [Media]
    var onPlay: (() -> Void)? = nil
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlayerModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                guard let first = tracks.first else { return }
                onPlay?()
                playback.setShuffle(false)
                playback.play(first, in: tracks, model: model)
            } label: {
                Label(String(localized: "Abspielen"), systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button {
                onPlay?()
                playback.playShuffled(tracks, model: model)
            } label: {
                Label(String(localized: "Zufällig"), systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .fontWeight(.semibold)
        .disabled(tracks.isEmpty)
    }
}

/// For an album or playlist: shuffle and repeat stay set for it, and the round
/// button plays it that way.
struct CollectionPlayButtons: View {
    let tracks: [Media]
    let collection: String
    var onPlay: (() -> Void)? = nil
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlayerModel
    @State private var settings: CollectionPlayback?

    private var shown: CollectionPlayback { settings ?? CollectionPlayback() }

    var body: some View {
        HStack(spacing: 10) {
            option(symbol: shown.repeatMode.symbol, isOn: shown.repeatMode != .off, label: shown.repeatMode.label) {
                change { $0.repeatMode = $0.repeatMode.next }
            }
            option(symbol: "shuffle", isOn: shown.shuffle,
                   label: shown.shuffle ? String(localized: "Zufallswiedergabe aus") : String(localized: "Zufallswiedergabe ein")) {
                change { $0.shuffle.toggle() }
            }
            Spacer()
            Button(action: play) {
                Image(systemName: "play.fill")
                    .font(.title3)
                    .foregroundStyle(.black)
                    .frame(width: 52, height: 52)
                    .background(Color.mint, in: Circle())
            }
            .accessibilityLabel(String(localized: "Abspielen"))
            .disabled(tracks.isEmpty)
        }
        .onAppear { settings = CollectionPlayback.load(collection) }
    }

    private func option(symbol: String, isOn: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(isOn ? Color.mint : Color.secondary)
                .frame(width: 44, height: 44)
                .background(isOn ? Color.mint.opacity(0.18) : Color.clear, in: Circle())
        }
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(label)
    }

    private func change(_ update: (inout CollectionPlayback) -> Void) {
        var next = shown
        update(&next)
        settings = next
        next.save(collection)
        // Already playing: applies at once.
        if tracks.contains(where: { $0.id == playback.current?.id }) { playback.applySettings(ofCollection: collection) }
    }

    private func play() {
        onPlay?()
        if settings == nil { playback.setShuffle(false) }
        playback.applySettings(ofCollection: collection)
        if shown.shuffle {
            playback.playShuffled(tracks, model: model)
        } else if let first = tracks.first {
            playback.play(first, in: tracks, model: model)
        }
    }
}

/// Download state for detail pages (films, episodes).
struct DownloadButton: View {
    let media: Media
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.downloading.contains(media.id) {
            HStack {
                LiveDownloadProgress { progress in ProgressView(value: progress[media.id] ?? 0) }
                DownloadPauseButton(media: media)
                Button(String(localized: "Abbrechen"), role: .destructive) { Task { await model.cancelDownload(media) } }.font(.caption)
            }
        } else if let record = model.offline.first(where: { $0.id == media.id }) {
            Button(role: .destructive) { model.removeDownload(record) } label: {
                Label(String(localized: "Offline verfügbar · Entfernen"), systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } else {
            Button { Task { await model.download(media) } } label: {
                Label("Herunterladen · \(byteLabel(media.downloadMedia.bytes))", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

/// Everything known about one file, including online information.
struct MediaInfoSheet: View {
    let media: Media
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var album: Album? { media.kind == "audio" ? model.album(for: media) : nil }
    private var albumInfo: AlbumInfo? { album.flatMap { model.albumInfo($0) } }
    private var track: TrackInfo? { model.trackInfo(media) }
    private var episode: EpisodeInfo? { model.episodeInfo(media) }
    private var movie: MovieInfo? { media.kind == "video" && media.series == nil ? model.movieInfo(media) : nil }
    private var description: String? {
        episode?.summary ?? movie?.description ?? (media.kind == "audio" ? albumInfo?.description : nil)
    }
    private struct DetailRow {
        let label: String
        let value: String
    }

    private var details: [DetailRow] {
        var rows: [DetailRow] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { rows.append(DetailRow(label: label, value: value)) }
        }
        switch media.kind {
        case "audio":
            add(String(localized: "Interpret"), media.artist)
            if let guests = media.featured, !guests.isEmpty { add(String(localized: "Gäste"), guests.joined(separator: ", ")) }
            add(String(localized: "Album"), media.album)
            if media.albumArtist != media.artist { add(String(localized: "Albuminterpret"), media.albumArtist) }
            if let number = media.trackNumber ?? track?.trackNumber {
                if let count = track?.trackCount ?? albumInfo?.trackCount {
                    add("Titelnummer", String(localized: "\(number) von \(count)"))
                } else {
                    add(String(localized: "Titelnummer"), String(number))
                }
            }
            if let disc = media.discNumber { add("CD", String(disc)) }
            add(String(localized: "Genre"), track?.genre ?? albumInfo?.genre)
            add(String(localized: "Erschienen"), germanDate(track?.releaseDate ?? albumInfo?.releaseDate))
            add(String(localized: "Dauer"), durationLabel(media.duration))
        case "video":
            if let series = media.series {
                add(String(localized: "Serie"), series)
                if let season = media.season { add(String(localized: "Staffel"), String(season)) } else { add(String(localized: "Staffel"), media.seasonGroup.map(displayName)) }
                if let number = media.episode { add(String(localized: "Folge"), String(number)) }
                add(String(localized: "Ausgestrahlt"), germanDate(episode?.airdate))
                if let runtime = episode?.runtime { add("Laufzeit", String(localized: "\(runtime) Min.")) }
            } else {
                if let year = movie?.year { add(String(localized: "Jahr"), String(year)) }
                add(String(localized: "Dauer"), durationLabel(media.duration))
            }
        default: break
        }
        return rows
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        ArtworkView(id: model.artworkID(for: media), symbol: media.symbol, cornerRadius: 10,
                                    aspect: media.kind == "video" ? 2.0 / 3.0 : 1)
                            .frame(width: 96)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(media.series == nil ? media.title : (episode?.name ?? media.episodeTitle)).font(.headline)
                            if !media.subtitle.isEmpty { Text(media.subtitle).font(.subheadline).foregroundStyle(.secondary) }
                            if let series = media.series { Text(series).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                if let description {
                    Section(String(localized: "Beschreibung")) {
                        ExpandableText(text: description, url: movie?.wikipediaUrl ?? (media.kind == "audio" ? albumInfo?.wikipediaUrl : nil), lines: 6)
                    }
                }
                if !details.isEmpty {
                    Section(String(localized: "Details")) {
                        let rows = details
                        ForEach(rows.indices, id: \.self) { index in LabeledContent(rows[index].label, value: rows[index].value) }
                    }
                }
                Section(String(localized: "Datei")) {
                    LabeledContent(String(localized: "Format"), value: media.formatLabel)
                    LabeledContent(String(localized: "Größe"), value: byteLabel(media.bytes))
                    LabeledContent(String(localized: "Geändert"), value: Date(timeIntervalSince1970: TimeInterval(media.modified)).formatted(date: .abbreviated, time: .omitted))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Pfad")).font(.caption).foregroundStyle(.secondary)
                        Text(media.path).font(.footnote.monospaced()).textSelection(.enabled)
                    }
                    if model.localURL(media) != nil { Label(String(localized: "Auf diesem iPhone gespeichert").forThisDevice, systemImage: "arrow.down.circle.fill").foregroundStyle(.mint) }
                }
                if model.metadata.enabled == true, let pending = model.metadata.pending, pending > 0 {
                    Text("Der Server sucht noch Informationen zu \(pending) Einträgen. Ziehe die Bibliothek später zum Aktualisieren nach unten.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "Infos"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(String(localized: "Fertig")) { dismiss() } } }
        }
    }
}

/// Section title with optional trailing content.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            Text(title).font(.title3.bold())
            Spacer()
            trailing
        }
        .padding(.horizontal)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// Download a whole album, playlist or season, with its state as icon:
/// arrow (nothing local), progress ring (loading), check (all on the iPhone).
struct DownloadPauseButton: View {
    let media: Media
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let paused = model.pausedDownloads.contains(media.id)
        Button {
            Task { if paused { await model.resumeDownload(media) } else { await model.pauseDownload(media) } }
        } label: {
            Image(systemName: paused ? "play.circle" : "pause.circle")
                .accessibilityLabel(paused ? String(localized: "Download fortsetzen") : String(localized: "Download pausieren"))
        }
        .buttonStyle(.borderless)
    }
}

struct DownloadAllButton: View {
    let tracks: [Media]
    /// "Keep available" for a playlist or series; nil where that does not apply.
    var automatic: Binding<Bool>? = nil
    var automaticLabel = ""
    @EnvironmentObject private var model: AppModel
    @State private var confirmRemove = false

    private var local: Int { tracks.filter { model.localURL($0) != nil }.count }
    private var loading: [Media] { tracks.filter { model.downloading.contains($0.id) } }
    private var missingBytes: UInt64 {
        tracks.filter { model.localURL($0) == nil }.reduce(0) { $0 + $1.downloadMedia.bytes }
    }
    private func fraction(_ progress: [String: Double]) -> Double {
        guard !tracks.isEmpty else { return 0 }
        let partial = loading.reduce(0.0) { $0 + (progress[$1.id] ?? 0) }
        return (Double(local) + partial) / Double(tracks.count)
    }

    var body: some View {
        Menu {
            if let automatic { Toggle(automaticLabel, systemImage: "arrow.triangle.2.circlepath", isOn: automatic) }
            if loading.contains(where: { model.pausedDownloads.contains($0.id) }) {
                Button(String(localized: "Downloads fortsetzen"), systemImage: "play.circle") { Task { await model.resumeDownloads(tracks) } }
            }
            if loading.contains(where: { !model.pausedDownloads.contains($0.id) }) {
                Button(String(localized: "Downloads pausieren"), systemImage: "pause.circle") { Task { await model.pauseDownloads(tracks) } }
            }
            if !loading.isEmpty {
                Button(String(localized: "Downloads abbrechen"), systemImage: "xmark.circle", role: .destructive) {
                    Task { await model.cancelDownloads(tracks) }
                }
            } else if local < tracks.count {
                Button {
                    Task { await model.downloadAll(tracks) }
                } label: {
                    Label(local == 0 ? "Alle herunterladen · \(byteLabel(missingBytes))"
                                     : "Restliche \(tracks.count - local) herunterladen · \(byteLabel(missingBytes))",
                          systemImage: "arrow.down.circle")
                }
            }
            if local > 0 {
                Button("Vom iPhone entfernen (\(local))", systemImage: "trash", role: .destructive) { confirmRemove = true }
            }
        } label: {
            Group {
                if !loading.isEmpty {
                    LiveDownloadProgress { progress in
                        ProgressView(value: fraction(progress)).progressViewStyle(.circular)
                    }
                } else if local == tracks.count && !tracks.isEmpty {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint)
                } else {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .accessibilityLabel(String(localized: "Herunterladen"))
        }
        .disabled(tracks.isEmpty && automatic == nil)
        .confirmationDialog(String(localized: "Lokale Kopien entfernen?"), isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("\(local) Dateien entfernen", role: .destructive) { model.removeDownloads(tracks) }
        } message: {
            Text(String(localized: "Die Dateien bleiben auf deinem Server."))
        }
    }
}

/// Redraws only its content when a download advances.
struct LiveDownloadProgress<Content: View>: View {
    @ObservedObject private var progress = DownloadProgress.shared
    @ViewBuilder let content: ([String: Double]) -> Content

    var body: some View { content(progress.values) }
}

/// Without a connection the app only shows what lies on this iPhone.
struct NothingDownloadedView: View {
    var body: some View {
        ContentUnavailableView(String(localized: "Nichts heruntergeladen"), systemImage: "arrow.down.circle",
                               description: Text(String(localized: "Ohne Verbindung siehst du hier nur, was auf diesem iPhone gespeichert ist.").forThisDevice))
    }
}
