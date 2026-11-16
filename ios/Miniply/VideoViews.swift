import SwiftUI

struct VideoLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var personal: Personal
    @AppStorage("mediaserver.videoCategory") private var category = 0
    @State private var search = ""

    private var movies: [Media] {
        model.items.filter { $0.kind == "video" && $0.series == nil && (search.isEmpty || $0.path.localizedCaseInsensitiveContains(search)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var series: [SeriesGroup] {
        model.seriesGroups.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    private static let shownToContinue = 12
    private var toContinue: [Media] {
        personal.continueWatching(in: model.mediaByID, series: model.seriesGroups, resume: model.resumeSeconds, limit: Self.shownToContinue)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ConnectionBanner().padding(.horizontal)
                Picker(String(localized: "Videoart"), selection: $category) { Text(String(localized: "Filme & Videos")).tag(0); Text("Serien").tag(1) }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                let continuing = search.isEmpty ? toContinue : []
                if !continuing.isEmpty {
                    SectionHeader(String(localized: "Weiterschauen"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(continuing) { media in
                                ContinueCard(media: media, width: 170)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                if category == 0 {
                    if movies.isEmpty {
                        empty(symbol: "film", title: String(localized: "Noch keine Videos"), text: String(localized: "Filme und Videos erscheinen nach dem Kopieren auf deine SSD. Ein Bild mit gleichem Namen (z. B. Film.jpg) wird zum Poster."))
                    } else {
                        LazyVGrid(columns: MediaGrid.covers, alignment: .leading, spacing: 16) {
                            ForEach(movies) { movie in
                                NavigationLink { MovieDetailView(media: movie) } label: {
                                    PosterCard(id: model.artworkID(for: movie), title: movie.title,
                                               subtitle: movieSubtitle(movie),
                                               symbol: "film", offline: model.localURL(movie) != nil)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                } else {
                    if series.isEmpty {
                        empty(symbol: "tv", title: String(localized: "Noch keine Serien"), text: String(localized: "Lege Folgen unter Serien/Serienname/Season 1/ ab. Staffeln werden automatisch sortiert."))
                    } else {
                        LazyVGrid(columns: MediaGrid.covers, alignment: .leading, spacing: 16) {
                            ForEach(series) { show in
                                NavigationLink { SeriesDetailView(initial: show) } label: {
                                    PosterCard(id: show.coverId, title: show.name,
                                               subtitle: show.seasons.count == 1 ? String(localized: "1 Staffel · \(show.episodeCount) Folgen") : String(localized: "\(show.seasons.count) Staffeln · \(show.episodeCount) Folgen"),
                                               symbol: "tv", offline: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .miniPlayerRoom()
        .navigationTitle(String(localized: "Videos"))
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: String(localized: "Suchen"))
        .scrollDismissesKeyboard(.immediately)
        .refreshableWhenOnline()
        .toolbar { if model.loading { ProgressView() } }
    }

    private func movieSubtitle(_ movie: Media) -> String {
        var parts: [String] = []
        if let year = model.movieInfo(movie)?.year { parts.append(String(year)) }
        if let duration = durationLabel(movie.duration) { parts.append(duration) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func empty(symbol: String, title: String, text: String) -> some View {
        Group {
            if !search.isEmpty { SearchEmptyView(query: search) }
            else if model.isOffline { NothingDownloadedView() }
            else if model.loading { ProgressView(String(localized: "Videos werden geladen …")) }
            else { ContentUnavailableView(title, systemImage: symbol, description: Text(text)) }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

/// Wide card with progress bar; tapping resumes in full screen.
struct ContinueCard: View {
    let media: Media
    /// Nil: as wide as the grid column.
    var width: CGFloat? = nil
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlayerModel
    private var queue: [Media] {
        guard let series = media.seriesPath,
              let season = model.seriesGroups.first(where: { $0.id == series })?.seasons.first(where: { $0.episodes.contains(media) })
        else { return [media] }
        return season.episodes
    }
    private var episodeLine: String {
        var parts: [String] = []
        if let season = media.season { parts.append("S\(season)") }
        if let episode = media.episode { parts.append(String(localized: "F\(episode)")) }
        parts.append(model.episodeInfo(media)?.name ?? media.episodeTitle)
        return parts.joined(separator: " · ")
    }
    private var fraction: Double {
        guard let duration = media.duration, duration > 0 else { return 0.3 }
        return min(1, model.resumeSeconds(media) / duration)
    }
    var body: some View {
        Button { playFullscreen(media, queue: queue, playback: playback, model: model) } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .bottomLeading) {
                    ArtworkView(id: model.thumbnailID(for: media) ?? model.artworkID(for: media), symbol: "play.rectangle",
                                cornerRadius: 10, aspect: 16.0 / 9.0, title: media.series ?? media.title)
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    HStack {
                        Image(systemName: "play.fill").font(.caption.bold())
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .padding(.bottom, 4)
                    Capsule().fill(.white.opacity(0.25)).frame(height: 3)
                        .overlay(alignment: .leading) {
                            GeometryReader { geometry in Capsule().fill(Color.mint).frame(width: geometry.size.width * fraction) }
                        }
                        .padding(.horizontal, 10).padding(.bottom, 6)
                }
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                Text(media.series ?? media.title).font(.caption.weight(.semibold)).lineLimit(1)
                // Always a second line: cards of different height would sit crooked side by side.
                Text(media.series == nil ? " " : episodeLine)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PosterCard: View {
    let id: String?
    let title: String
    let subtitle: String
    var symbol = "film"
    var offline = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkView(id: id, symbol: symbol, cornerRadius: 8, aspect: 2.0 / 3.0, title: title)
                .overlay(alignment: .topTrailing) {
                    if offline {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.white, .mint)
                            .font(.footnote).padding(4)
                    }
                }
                .shadow(color: .black.opacity(0.3), radius: 5, y: 3)
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            if !subtitle.isEmpty { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        .contentShape(Rectangle())
    }
}

/// Poster, title and facts side by side; shared by films and series.
private struct DetailHeader: View {
    let artwork: String?
    let title: String
    let facts: [String]
    let symbol: String
    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            ArtworkView(id: artwork, symbol: symbol, cornerRadius: 12, aspect: 2.0 / 3.0, title: title)
                .frame(width: 100)
                .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.bold()).lineLimit(4)
                ForEach(facts, id: \.self) { fact in
                    Text(fact).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct MovieDetailView: View {
    let media: Media
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlayerModel
    @EnvironmentObject private var personal: Personal
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    private var info: MovieInfo? { model.movieInfo(media) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DetailHeader(artwork: model.artworkID(for: media), title: media.title,
                             facts: [info?.year.map { String($0) }, durationLabel(media.duration), media.formatLabel].compactMap { $0 },
                             symbol: "film")
                Button { playFullscreen(media, playback: playback, model: model) } label: {
                    Label(String(localized: "Abspielen"), systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).fontWeight(.semibold)
                HStack {
                    DownloadButton(media: media)
                    Button { personal.setWatched(media, !personal.isWatched(media)) } label: {
                        Image(systemName: personal.isWatched(media) ? "checkmark.circle.fill" : "checkmark.circle")
                            .foregroundStyle(personal.isWatched(media) ? Color.mint : Color.primary)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(personal.isWatched(media) ? String(localized: "Als nicht gesehen markieren") : String(localized: "Als gesehen markieren"))
                }
                .controlSize(.large)
                if media.subtitles?.isEmpty == false {
                    SubtitleMenu(media: media).buttonStyle(.bordered)
                }
                if let description = info?.description {
                    ExpandableText(text: description, url: info?.wikipediaUrl, lines: 6)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Datei")).font(.headline)
                    Text(media.path).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(byteLabel(media.bytes)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background { ArtworkBackdrop(id: model.artworkID(for: media)) }
        .miniPlayerRoom()
        .navigationTitle(media.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.canDeleteFromServer {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        DeleteFromServerButton(isConfirming: $confirmingDelete)
                    } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(String(localized: "Filmaktionen")) }
                }
            }
        }
        .deleteFromServer(isPresented: $confirmingDelete, items: [media], name: media.title) { dismiss() }
    }
}

struct SeriesDetailView: View {
    let initial: SeriesGroup
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlayerModel
    @EnvironmentObject private var personal: Personal
    /// Highest season on top unless switched (remembered).
    @AppStorage("mediaserver.seasonsDescending") private var descending = true
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    private var series: SeriesGroup { model.seriesGroups.first { $0.id == initial.id } ?? initial }
    private var info: SeriesInfo? { model.seriesInfo(series) }
    private var seasons: [Season] { descending ? Array(series.seasons.reversed()) : series.seasons }
    private func nextLabel(season: Season, episode: Media) -> String {
        var parts: [String] = [season.number.map { String(localized: "Staffel \($0)") } ?? season.title]
        if let number = episode.episode { parts.append(String(localized: "Folge \(number)")) }
        return parts.joined(separator: " · ")
    }
    private var facts: [String] {
        let years: String? = info?.premiered.map { start in
            let first = String(start.prefix(4))
            if let end = info?.ended { return first + "–" + String(end.prefix(4)) }
            return info?.status == "Running" ? first + "–heute" : first
        }
        let rating = info?.rating.map { String(format: "★ %.1f", $0) }
        return [years, info?.network, rating, series.seasons.count == 1 ? String(localized: "1 Staffel · \(series.episodeCount) Folgen") : String(localized: "\(series.seasons.count) Staffeln · \(series.episodeCount) Folgen")]
            .compactMap { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DetailHeader(artwork: series.coverId, title: series.name, facts: facts, symbol: "tv")
                if let genres = info?.genres, !genres.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(genres, id: \.self) { genre in
                                Text(genre).font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(.mint.opacity(0.18), in: Capsule())
                            }
                        }
                    }
                }
                if let next = personal.continueEpisode(in: series, resume: model.resumeSeconds) {
                    let season = next.0
                    let episode = next.1
                    let started = series.seasons.flatMap(\.episodes).contains { personal.isWatched($0) } || model.resumeSeconds(episode) > 30
                    Button { playFullscreen(episode, queue: season.episodes, playback: playback, model: model) } label: {
                        VStack(spacing: 2) {
                            Label(started ? String(localized: "Weiterschauen") : String(localized: "Ansehen"), systemImage: "play.fill")
                            Text(nextLabel(season: season, episode: episode))
                                .font(.caption).opacity(0.85)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).fontWeight(.semibold)
                } else if !series.seasons.isEmpty {
                    Label(String(localized: "Alle Folgen gesehen"), systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.mint)
                        .frame(maxWidth: .infinity)
                }
                if let description = info?.description ?? info?.summary {
                    ExpandableText(text: description, url: info?.wikipediaUrl)
                }
                HStack {
                    Text(String(localized: "Staffeln")).font(.title3.bold())
                    Spacer()
                    Button {
                        withAnimation { descending.toggle() }
                    } label: {
                        Label(descending ? String(localized: "Höchste zuerst") : String(localized: "Erste zuerst"), systemImage: "arrow.up.arrow.down")
                            .font(.subheadline)
                    }
                }
                .padding(.top, 4)
                LazyVStack(spacing: 10) {
                    ForEach(seasons) { season in
                        NavigationLink { SeasonView(seriesID: series.id, initial: season) } label: {
                            SeasonCard(season: season, cover: model.seasonCover(season, in: series),
                                       offline: season.episodes.filter { model.localURL($0) != nil }.count,
                                       watched: season.episodes.filter { personal.isWatched($0) }.count)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(String(localized: "Staffel als gesehen markieren"), systemImage: "checkmark.circle") { personal.setWatched(season.episodes, true) }
                            Button(String(localized: "Staffel als nicht gesehen markieren"), systemImage: "eye.slash") { personal.setWatched(season.episodes, false) }
                        }
                    }
                }
            }
            .padding()
        }
        .background { ArtworkBackdrop(id: series.coverId) }
        .miniPlayerRoom()
        .navigationTitle(series.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                DownloadAllButton(tracks: series.seasons.flatMap(\.episodes),
                                  automatic: Binding(get: { model.isAutoDownloading(series: series) },
                                                     set: { model.setAutoDownload(series: series, $0) }),
                                  automaticLabel: String(localized: "Nächste Folgen automatisch laden"))
            }
            if model.canDeleteFromServer {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        DeleteFromServerButton(isConfirming: $confirmingDelete)
                    } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(String(localized: "Serienaktionen")) }
                }
            }
        }
        .deleteFromServer(isPresented: $confirmingDelete, items: series.seasons.flatMap(\.episodes), name: series.name) { dismiss() }
    }
}

private struct SeasonCard: View {
    let season: Season
    let cover: String?
    let offline: Int
    var watched = 0
    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(id: cover, symbol: "tv", cornerRadius: 8, aspect: 2.0 / 3.0, title: nil)
                .frame(width: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(season.title).font(.subheadline.weight(.semibold))
                Text(offline > 0 ? "\(season.episodes.count) Folgen · \(offline) offline" : "\(season.episodes.count) Folgen")
                    .font(.caption).foregroundStyle(.secondary)
                if watched > 0 {
                    HStack(spacing: 6) {
                        ProgressView(value: Double(watched), total: Double(max(1, season.episodes.count))).tint(.mint).frame(maxWidth: 110)
                        Text(watched == season.episodes.count ? "Gesehen" : "\(watched)/\(season.episodes.count)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct SeasonView: View {
    let seriesID: String
    let initial: Season
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlayerModel
    @EnvironmentObject private var personal: Personal
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    private var season: Season {
        model.seriesGroups.first { $0.id == seriesID }?.seasons.first { $0.id == initial.id } ?? initial
    }

    var body: some View {
        List {
            if let first = season.episodes.first {
                Button { playFullscreen(first, queue: season.episodes, playback: playback, model: model) } label: {
                    Label(String(localized: "Staffel abspielen"), systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).fontWeight(.semibold)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            ForEach(season.episodes) { episode in
                EpisodeRow(media: episode, queue: season.episodes)
            }
        }
        .listStyle(.plain)
        .miniPlayerRoom()
        .navigationTitle(season.title)
        .refreshableWhenOnline()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { DownloadAllButton(tracks: season.episodes) }
            ToolbarItem(placement: .topBarTrailing) { seasonMenu }
        }
        .deleteFromServer(isPresented: $confirmingDelete, items: season.episodes, name: season.title) { dismiss() }
    }

    private var seasonMenu: some View {
        Menu {
            Button(String(localized: "Alle als gesehen markieren"), systemImage: "checkmark.circle") { personal.setWatched(season.episodes, true) }
            Button(String(localized: "Alle als nicht gesehen markieren"), systemImage: "eye.slash") { personal.setWatched(season.episodes, false) }
            if model.canDeleteFromServer {
                Divider()
                DeleteFromServerButton(isConfirming: $confirmingDelete)
            }
        } label: { Image(systemName: "ellipsis.circle") }
    }
}

struct EpisodeRow: View {
    let media: Media
    let queue: [Media]
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlayerModel
    @EnvironmentObject private var personal: Personal
    private var info: EpisodeInfo? { model.episodeInfo(media) }
    private var isCurrent: Bool { playback.current?.id == media.id }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { playFullscreen(media, queue: queue, playback: playback, model: model) } label: {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        if let still = model.thumbnailID(for: media) {
                            ArtworkView(id: still, symbol: "tv", cornerRadius: 10, aspect: 16.0 / 9.0)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.25)))
                        } else {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(LinearGradient(colors: [.mint.opacity(0.35), .teal.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                        VStack(spacing: 2) {
                            Image(systemName: isCurrent ? "waveform" : personal.isWatched(media) ? "checkmark" : "play.fill").font(.callout)
                            if let number = media.episode { Text("\(number)").font(.caption.weight(.bold).monospacedDigit()) }
                        }
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                    }
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        if !personal.isWatched(media), let duration = media.duration, duration > 0, model.resumeSeconds(media) > 30 {
                            ProgressView(value: min(1, model.resumeSeconds(media) / duration)).tint(.mint).frame(maxWidth: 120)
                        }
                        Text(info?.name ?? media.episodeTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isCurrent ? Color.mint : personal.isWatched(media) ? Color.secondary : Color.primary)
                            .lineLimit(2)
                        let facts = [media.episode.map { String(localized: "Folge \($0)") }, durationLabel(media.duration) ?? info?.runtime.map { String(localized: "\($0) Min.") }, germanDate(info?.airdate)]
                            .compactMap { $0 }
                        if !facts.isEmpty {
                            Text(facts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        if let summary = info?.summary {
                            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if model.localURL(media) != nil {
                        Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.mint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.downloading.contains(media.id) {
                LiveDownloadProgress { progress in
                    ProgressView(value: progress[media.id] ?? 0).progressViewStyle(.circular).frame(width: 22)
                }
            }
            MediaActionsMenu(media: media)
        }
        .padding(.vertical, 4)
    }
}
