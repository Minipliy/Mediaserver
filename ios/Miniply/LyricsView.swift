import SwiftUI

/// Lyrics for the current track. Synchronised lyrics follow the playback
/// position and a tap on a line jumps there.
struct LyricsView: View {
    let media: Media
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlayerModel
    @State private var lines: [LyricLine] = []
    @State private var plain: String?
    @State private var instrumental = false
    @State private var state: LoadState = .loading
    @State private var source: String?

    private enum LoadState { case loading, loaded, missing, failed }

    private var currentIndex: Int? {
        guard !lines.isEmpty else { return nil }
        let time = playback.seconds + 0.3
        return lines.lastIndex { $0.time <= time }
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView(String(localized: "Songtext wird gesucht …")).frame(maxWidth: .infinity, minHeight: 260)
            case .missing, .failed:
                ContentUnavailableView(state == .failed ? String(localized: "Songtext nicht erreichbar") : String(localized: "Kein Songtext gefunden"),
                                       systemImage: "quote.bubble",
                                       description: Text(String(localized: "Lege eine .lrc-Datei mit gleichem Namen neben den Song, dann erscheint der Text hier.")))
                    .frame(minHeight: 260)
            case .loaded:
                if instrumental && lines.isEmpty && plain == nil {
                    ContentUnavailableView(String(localized: "Instrumental"), systemImage: "pianokeys", description: Text(String(localized: "Dieser Titel hat keinen Gesang.")))
                        .frame(minHeight: 260)
                } else if !lines.isEmpty {
                    synced
                } else if let plain {
                    ScrollView {
                        Text(plain).font(.title3.weight(.semibold)).lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.vertical)
                        if source == "genius" {
                            Text("Songtext: Genius").font(.caption2).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(height: 360)
                }
            }
        }
        .task(id: media.id) { await load() }
    }

    private var synced: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(lines) { line in
                        let active = line.id == currentIndex
                        Button { playback.seek(line.time) } label: {
                            // No scaling of the current line: wrapped at the full width, it would
                            // grow past the right edge and lose its last letters.
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.55))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .id(line.id)
                        .animation(.easeOut(duration: 0.25), value: active)
                    }
                    if source == "lrclib" {
                        Text("Songtext: LRCLIB").font(.caption2).foregroundStyle(.tertiary).padding(.top)
                    }
                }
                .padding(.vertical, 120)
            }
            .frame(height: 360)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                         .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            // Before the first line, for example after jumping back from the end,
            // the text returns to its top at once instead of waiting for the first line.
            .onChange(of: currentIndex) { _, index in
                guard let target = index ?? lines.first?.id else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: .center) }
            }
            .onAppear {
                if let target = currentIndex ?? lines.first?.id { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    private func load() async {
        state = .loading; lines = []; plain = nil; instrumental = false
        if let known = model.availableLyrics(media) { apply(known); return }
        do {
            guard let payload = try await model.lyrics(for: media) else { state = .missing; return }
            apply(payload)
        } catch {
            if !Task.isCancelled { state = .failed }
        }
    }

    private func apply(_ payload: LyricsPayload) {
        lines = payload.synced.map(parseLRC) ?? []
        plain = payload.plain
        instrumental = payload.instrumental ?? false
        source = payload.source
        state = (lines.isEmpty && plain == nil && !instrumental) ? .missing : .loaded
    }
}

/// Picker for the subtitle of one video.
struct SubtitleMenu: View {
    let media: Media
    @EnvironmentObject private var playback: PlayerModel
    var body: some View {
        if let tracks = media.subtitles, !tracks.isEmpty {
            let selected = playback.preferredSubtitle(for: media)?.id
            Menu {
                Button { playback.chooseSubtitle(nil, for: media) } label: {
                    if selected == nil { Label(String(localized: "Aus"), systemImage: "checkmark") } else { Text(String(localized: "Aus")) }
                }
                ForEach(tracks) { track in
                    Button { playback.chooseSubtitle(track, for: media) } label: {
                        if selected == track.id { Label(track.label, systemImage: "checkmark") } else { Text(track.label) }
                    }
                }
            } label: {
                Label(String(localized: "Untertitel"), systemImage: "captions.bubble")
            }
        }
    }
}
