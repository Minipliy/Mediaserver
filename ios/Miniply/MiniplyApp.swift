import SwiftUI
import UserNotifications
import AVKit

@main
struct MediaserverApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var playback = PlayerModel()
    @StateObject private var personal = Personal()
    @StateObject private var uploads = UploadManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(playback)
                .environmentObject(personal)
                .environmentObject(uploads)
                .tint(.mint)
                .preferredColorScheme(.dark)
                .task(id: scenePhase) { if scenePhase == .active { await model.retryWhileOffline() } }
                .onReceive(NotificationCenter.default.publisher(for: OutageAlerts.tokenChanged)) { _ in
                    Task { await model.registerPushDevice() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { playback.persistPosition() }
                    else {
                        playback.becameActive()
                        Task {
                            if model.refreshIsDue { await model.refresh() }
                            // Folgen, die auf dem iPad oder im Browser geschaut wurden, gleich
                            // berücksichtigen: Gesehenes entfernen, die nächsten Folgen laden.
                            await personal.sync()
                            playback.sendSavedPositions(model: model)
                            model.removeWatchedDownloads(watched: personal.watched, playing: playback.current?.id)
                            await model.runAutoDownloads()
                        }
                    }
                }
                .onAppear(perform: MacWindow.limitSize)
        }
        .commands { PlaybackCommands(playback: playback) }
    }
}

/// Die Wiedergabe in der Menüleiste des Macs, mit den Tasten der Musik-App.
/// Auf dem iPad erscheinen dieselben Kürzel mit einer Tastatur.
struct PlaybackCommands: Commands {
    @ObservedObject var playback: PlayerModel

    var body: some Commands {
        CommandMenu(String(localized: "Wiedergabe")) {
            Button(playback.intendsToPlay ? String(localized: "Pause") : String(localized: "Abspielen")) { playback.toggle() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(playback.current == nil)
            Divider()
            Button(String(localized: "Nächster Titel")) { playback.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(playback.current == nil)
            Button(String(localized: "Vorheriger Titel")) { playback.skipToPrevious() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(playback.previousItem == nil)
            Divider()
            Button(String(localized: "10 Sekunden vor")) { playback.jump(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(playback.current == nil)
            Button(String(localized: "10 Sekunden zurück")) { playback.jump(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(playback.current == nil)
            Divider()
            Toggle(String(localized: "Zufallswiedergabe"), isOn: Binding(get: { playback.shuffle }, set: { playback.setShuffle($0) }))
        }
    }
}

/// Auf dem Mac soll das Fenster nicht so klein werden, dass die Ansichten zusammenfallen.
enum MacWindow {
    static func limitSize() {
        #if targetEnvironment(macCatalyst)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.sizeRestrictions?.minimumSize = CGSize(width: 720, height: 560)
        }
        #endif
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DiagnosticsCollector.shared.start()
        UNUserNotificationCenter.current().delegate = self
        // The push address can change (new install, restore); iOS hands out the current one.
        if OutageAlerts.isEnabled { application.registerForRemoteNotifications() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        OutageAlerts.received(deviceToken)
    }

    /// Warnings also show while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == UploadManager.sessionID {
            UploadManager.shared.backgroundCompletion = completionHandler
            Task { await UploadManager.shared.restore() }
            return
        }
        guard identifier == DownloadManager.sessionID else { completionHandler(); return }
        DownloadManager.shared.backgroundCompletion = completionHandler
        DownloadManager.shared.restore()
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlayerModel
    @EnvironmentObject private var personal: Personal
    @EnvironmentObject private var uploads: UploadManager
    @State private var showPlayer = false

    var body: some View {
        Group {
            if model.connection == nil { ConnectView() }
            else {
                TabView {
                    NavigationStack { HomeView() }
                        .overlay(alignment: .bottom) { MiniPlayerBar(showPlayer: $showPlayer) }
                        .tabItem { Label(String(localized: "Start"), systemImage: "house.fill") }
                    NavigationStack { MusicView() }
                        .overlay(alignment: .bottom) { MiniPlayerBar(showPlayer: $showPlayer) }
                        .tabItem { Label("Musik", systemImage: "music.note") }
                    NavigationStack { VideoLibraryView() }
                        .overlay(alignment: .bottom) { MiniPlayerBar(showPlayer: $showPlayer) }
                        .tabItem { Label(String(localized: "Videos"), systemImage: "play.rectangle") }
                    NavigationStack { SettingsView() }
                        .overlay(alignment: .bottom) { MiniPlayerBar(showPlayer: $showPlayer) }
                        .tabItem { Label(String(localized: "Einstellungen"), systemImage: "gearshape") }
                }
            }
        }
        .environment(\.miniPlayerVisible, playback.current != nil)
        .fullScreenCover(isPresented: $showPlayer) {
            NowPlayingView().presentationBackground(.clear).appObjects(model, playback, personal)
        }
        .onChange(of: playback.error) { _, error in
            // Alerts cannot appear above the full-screen player.
            if error != nil { VideoPresenter.dismiss() }
        }
        .task {
            uploads.onFinished = { await model.refresh() }
            await uploads.restore()
            personal.api = model.api
            await model.refresh()
            // Without a saved library it was not known before the first answer.
            playback.restoreSession(model: model)
            await personal.sync()
            playback.sendSavedPositions(model: model)
        }
        .onChange(of: model.connection) { _, connection in
            if connection == nil { uploads.connectionRemoved() }
            personal.api = model.api
            Task { await personal.sync() }
        }
        .onAppear {
            playback.personal = personal
            playback.restoreSession(model: model)
            model.watchedIDs = { [weak personal] in personal?.watched ?? [] }
        }
        .onChange(of: personal.watched) { _, watched in
            model.removeWatchedDownloads(watched: watched, playing: playback.current?.id)
            Task { await model.runAutoDownloads() }
        }
        .onChange(of: playback.current?.id) { _, playing in
            model.removeWatchedDownloads(watched: personal.watched, playing: playing)
        }
        .onReceive(Connectivity.shared.$state) { state in
            playback.networkChanged(state)
            model.networkChanged(state)
        }
        .alert("Mediaserver", isPresented: Binding(get: { model.error != nil || playback.error != nil }, set: { if !$0 { model.error = nil; playback.error = nil } })) {
            Button("OK") { model.error = nil; playback.error = nil }
        } message: { Text(model.error ?? playback.error ?? "") }
    }
}

/// Part of the scrolled content: pinned under the large title, the title slid below it.
struct ConnectionBanner: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if model.isOffline {
            HStack {
                NavigationLink { ConnectionStatusView() } label: {
                    Label("\(model.serverStatus.title) · nur Heruntergeladenes", systemImage: model.serverStatus.symbol)
                        .font(.caption).lineLimit(2)
                }
                Spacer()
                Button(String(localized: "Erneut verbinden")) { Task { await model.refresh() } }
                    .font(.caption.bold()).disabled(model.loading)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct SearchEmptyView: View {
    let query: String
    var body: some View {
        ContentUnavailableView(String(localized: "Keine Treffer"), systemImage: "magnifyingglass",
                               description: Text("Für „\(query)“ wurden keine passenden Medien gefunden."))
    }
}

struct ConnectView: View {
    @EnvironmentObject private var model: AppModel
    @State private var address = ""
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "waveform.circle.fill").font(.system(size: 64)).foregroundStyle(.mint)
                        Text(String(localized: "Deine Medien.\nÜberall dabei.")).font(.largeTitle.bold())
                        Text(String(localized: "Verbinde Mediaserver mit deiner persönlichen Mediathek.")).foregroundStyle(.secondary)
                    }.padding(.vertical, 24).listRowBackground(Color.clear)
                }
                Section {
                    TextField("https://media.deine-domain.de", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("HTTPS-Serveradresse")
                    SecureField("API-Token", text: $token)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text(String(localized: "Dein Server")) }
                footer: { Text(String(localized: "Das Token wird im Schlüsselbund dieses iPhones gespeichert. Die Serveradresse muss zuvor eingerichtet sein.").forThisDevice) }
                Section {
                    Button {
                        Task { await model.connect(address: address, token: token); if model.connection != nil { token = "" } }
                    } label: {
                        HStack { Spacer(); if model.loading { ProgressView() } else { Text(String(localized: "Verbinden")).bold() }; Spacer() }
                    }.disabled(model.loading || address.isEmpty || token.isEmpty)
                }
                AppHelpSection()
            }.navigationTitle("Mediaserver")
        }
    }
}

struct AppHelpSection: View {
    var body: some View {
        Section(String(localized: "Hilfe & Rechtliches")) {
            Link("Einrichtung & Voraussetzungen", destination: URL(string: "https://mediaserver.minipliy.net/einrichtung")!)
            Link("Support", destination: URL(string: "https://mediaserver.minipliy.net/support")!)
            Link("Datenschutzerklärung", destination: URL(string: "https://mediaserver.minipliy.net/datenschutz")!)
            Link("Nutzungsbedingungen", destination: URL(string: "https://mediaserver.minipliy.net/agb")!)
            Link("Impressum", destination: URL(string: "https://mediaserver.minipliy.net/impressum")!)
        }
    }
}

extension View {
    /// Als iPad-App auf dem Mac kommen die Objekte der App in einem Vollbild oder Sheet
    /// nicht immer an, und die App stürzt beim Öffnen ab. Darum ausdrücklich mitgeben.
    func appObjects(_ model: AppModel, _ playback: PlayerModel, _ personal: Personal) -> some View {
        environmentObject(model).environmentObject(playback).environmentObject(personal)
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var playback: PlayerModel
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var personal: Personal
    @Environment(\.dismiss) private var dismiss
    @State private var creatingPlaylist = false
    @State private var showingQueue = false
    @State private var scrubPosition: Double?
    @State private var pullDown: CGFloat = 0
    @AppStorage("mediaserver.showLyrics") private var showLyrics = false
    private static let closeDistance: CGFloat = 130
    private static let closeSpeed: CGFloat = 900
    private static let pagePadding: CGFloat = 24

    var body: some View {
        NavigationStack {
            let current = playback.current
            let isVideo = current?.kind == "video"
            let artwork = current.flatMap { model.artworkID(for: $0) }
            GeometryReader { page in
            ScrollView {
                VStack(spacing: Self.pagePadding) {
                // The player fills the screen: the list starts below it, away from
                // the home indicator, where a swipe to leave the app could hit a song.
                VStack(spacing: Self.pagePadding) {
                    if showLyrics, let current, current.kind == "audio" {
                        LyricsView(media: current)
                        titleBlock(current)
                    } else if let current {
                        TrackCarousel(previous: playback.previousItem, current: current, next: playback.followingItem,
                                      onPrevious: { playback.skipToPrevious() }, onNext: { playback.next() }) { media in
                            VStack(spacing: 24) {
                                ArtworkView(id: model.artworkID(for: media), symbol: media.symbol, cornerRadius: 18,
                                            aspect: isVideo ? 2.0 / 3.0 : 1, title: nil)
                                    .frame(maxWidth: isVideo ? 200 : 340)
                                    .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
                                    .scaleEffect(playback.isPlaying || isVideo || media.id != current.id ? 1 : 0.9)
                                    .animation(.spring(duration: 0.45), value: playback.isPlaying)
                                    .padding(.top, 8)
                                titleBlock(media)
                            }
                            .padding(.horizontal, 24)
                        }
                        .padding(.horizontal, -24)
                    } else {
                        titleBlock(nil)
                    }
                    if isVideo {
                        Button { VideoPresenter.present(playback) } label: {
                            Label(String(localized: "Im Vollbild ansehen"), systemImage: "arrow.up.left.and.arrow.down.right").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    if let current {
                        HStack(spacing: 22) {
                            Spacer(minLength: 0)
                            if current.kind == "audio" {
                                Button { personal.toggleFavorite(current) } label: {
                                    Image(systemName: personal.isFavorite(current) ? "heart.fill" : "heart")
                                        .font(.title2)
                                        .foregroundStyle(personal.isFavorite(current) ? Color.pink : Color.primary)
                                        .contentTransition(.symbolEffect(.replace))
                                }
                                .sensoryFeedback(.selection, trigger: personal.isFavorite(current))
                                .accessibilityLabel(personal.isFavorite(current) ? String(localized: "Aus Lieblingssongs entfernen") : String(localized: "Zu Lieblingssongs"))
                                Menu {
                                    AddToPlaylistMenu(tracks: [current], showCreate: $creatingPlaylist)
                                } label: {
                                    Image(systemName: "text.badge.plus").font(.title2).accessibilityLabel(String(localized: "Zu Playlist hinzufügen"))
                                }
                            }
                            MediaActionsMenu(media: current)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 4) {
                        // While dragging only the local value changes; the player
                        // seeks once when the finger is lifted (no stutter).
                        Slider(value: Binding(get: { scrubPosition ?? min(playback.seconds, max(1, playback.duration)) },
                                              set: { scrubPosition = $0 }),
                               in: 0...max(1, playback.duration)) { editing in
                            if !editing, let target = scrubPosition {
                                playback.seek(target)
                                scrubPosition = nil
                            }
                        }
                        .disabled(playback.duration <= 0).accessibilityLabel(String(localized: "Wiedergabeposition"))
                        let shown = scrubPosition ?? playback.seconds
                        HStack { Text(time(shown)); Spacer(); Text("-" + time(max(0, playback.duration - shown))) }
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    controls(isVideo: isVideo)
                    Group {
                        if playback.preparing {
                            Text(playback.phase ?? String(localized: "Wiedergabe wird vorbereitet …"))
                        } else if playback.buffering {
                            Text(String(localized: "Stream wird gepuffert …"))
                        } else {
                            Text(" ")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: playback.phase)
                    if let notice = playback.progressNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    if let deadline = playback.sleepDeadline {
                        Label { Text(String(localized: "Pausiert in ")) + Text(deadline, style: .relative) } icon: { Image(systemName: "moon.zzz.fill") }
                            .font(.caption).foregroundStyle(.mint)
                    } else if playback.sleepAtTrackEnd {
                        Label(String(localized: "Pausiert am Ende"), systemImage: "moon.zzz.fill").font(.caption).foregroundStyle(.mint)
                    }
                }
                .frame(minHeight: page.size.height - Self.pagePadding)
                    if !isVideo && !playback.upNext.isEmpty { upNext }
                }
                .padding(Self.pagePadding)
                .background { PullDownPan(changed: { pullDown = $0 }, ended: finishPull) }
            }
            }
            .background { ArtworkBackdrop(id: artwork, fillsPage: true) }
            .navigationTitle(String(localized: "Jetzt läuft")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").fontWeight(.semibold).accessibilityLabel(String(localized: "Schließen"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if playback.current?.kind == "audio" {
                        Button { withAnimation { showLyrics.toggle() } } label: {
                            Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble").accessibilityLabel(String(localized: "Songtext"))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingQueue = true } label: { Image(systemName: "list.bullet").accessibilityLabel(String(localized: "Warteschlange")) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Menu {
                            if playback.sleepActive {
                                Button(String(localized: "Schlaf-Timer aus"), systemImage: "xmark", role: .destructive) { playback.setSleepTimer(minutes: nil) }
                            }
                            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                                Button("\(minutes) Minuten") { playback.setSleepTimer(minutes: minutes) }
                            }
                            Button(playback.current?.kind == "video" ? String(localized: "Ende der Folge") : String(localized: "Ende des Titels")) { playback.sleepAtEndOfTrack() }
                        } label: {
                            Label(String(localized: "Schlaf-Timer"), systemImage: playback.sleepActive ? "moon.zzz.fill" : "moon.zzz")
                        }
                        Button(String(localized: "Stoppen"), systemImage: "stop.circle", role: .destructive) { playback.stop(); dismiss() }
                    } label: {
                        Image(systemName: playback.sleepActive ? "moon.zzz.fill" : "ellipsis.circle")
                            .foregroundStyle(playback.sleepActive ? Color.mint : Color.primary)
                            .accessibilityLabel(String(localized: "Mehr"))
                    }
                }
            }
            .newPlaylistAlert(isPresented: $creatingPlaylist, tracks: current.map { [$0] } ?? [])
            .sheet(isPresented: $showingQueue) { QueueView().appObjects(model, playback, personal) }
        }
        .overlay(alignment: .bottom) {
            // The bar with its own message lies behind this full-screen view.
            if let toast = playback.toast {
                PlayerToast(text: toast).padding(.bottom, 40).allowsHitTesting(false)
            }
        }
        .animation(.spring(duration: 0.3), value: playback.toast)
        .background(Color(.systemBackground).ignoresSafeArea())
        .offset(y: pullDown)
    }

    private func finishPull(_ distance: CGFloat, _ speed: CGFloat) {
        if distance >= Self.closeDistance || speed >= Self.closeSpeed {
            dismiss()
        } else {
            withAnimation(.spring(duration: 0.3)) { pullDown = 0 }
        }
    }

    /// For a song, title and artist lead to its album (or the artist, if it has none).
    @ViewBuilder private func titleBlock(_ media: Media?) -> some View {
        let names = VStack(alignment: .leading, spacing: 4) {
            Text(media.map { $0.series == nil ? $0.title : (model.episodeInfo($0)?.name ?? $0.episodeTitle) } ?? String(localized: "Keine Wiedergabe"))
                .font(.title2.bold()).lineLimit(2)
            Text(media.map { $0.series ?? $0.subtitle } ?? "").foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        if let media, media.kind == "audio", let album = model.album(for: media) {
            NavigationLink { AlbumDetailView(initial: album) } label: { names }
                .buttonStyle(.plain)
                .accessibilityHint(String(localized: "Öffnet das Album"))
        } else if let media, media.kind == "audio", let artist = media.artist {
            NavigationLink { ArtistDetailView(name: artist) } label: { names }
                .buttonStyle(.plain)
        } else {
            names
        }
    }

    @ViewBuilder private func controls(isVideo: Bool) -> some View {
        HStack {
            if isVideo {
                Spacer()
                Button { playback.seek(playback.seconds - 15) } label: { Image(systemName: "gobackward.15").font(.title) }
            } else {
                Button { playback.toggleShuffle() } label: {
                    Image(systemName: "shuffle").font(.title3)
                        .foregroundStyle(playback.shuffle ? Color.mint : Color.secondary)
                        .padding(8)
                        .background(playback.shuffle ? Color.mint.opacity(0.18) : Color.clear, in: Circle())
                }
                .accessibilityLabel(playback.shuffle ? String(localized: "Zufallswiedergabe aus") : String(localized: "Zufallswiedergabe ein"))
                Spacer()
                HoldSkipButton(symbol: "backward.fill", label: String(localized: "Vorheriger Titel"),
                               holdLabel: String(localized: "10 Sekunden zurück"), font: .title,
                               tap: { playback.previous() }, hold: { playback.jump(by: -PlayerModel.holdJump) })
            }
            Spacer()
            Button { playback.toggle() } label: {
                // Always the button: "pause" while the user wants playback,
                // also during loading; the status text shows the progress.
                Image(systemName: playback.isPlaying || playback.intendsToPlay ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
                    .contentTransition(.symbolEffect(.replace))
            }
            .sensoryFeedback(.impact(weight: .light), trigger: playback.intendsToPlay)
            .accessibilityLabel(playback.isPlaying || playback.intendsToPlay ? String(localized: "Pausieren") : String(localized: "Abspielen"))
            Spacer()
            if isVideo {
                Button { playback.seek(playback.seconds + 15) } label: { Image(systemName: "goforward.15").font(.title) }
                Spacer()
            } else {
                HoldSkipButton(symbol: "forward.fill", label: String(localized: "Nächster Titel"),
                               holdLabel: String(localized: "10 Sekunden vor"), font: .title, canTap: playback.hasNext,
                               tap: { playback.next() }, hold: { playback.jump(by: PlayerModel.holdJump) })
                Spacer()
                Button { playback.cycleRepeat() } label: {
                    Image(systemName: playback.repeatMode.symbol).font(.title3)
                        .foregroundStyle(playback.repeatMode == .off ? Color.secondary : Color.mint)
                        .padding(8)
                        .background(playback.repeatMode == .off ? Color.clear : Color.mint.opacity(0.18), in: Circle())
                }
                .accessibilityLabel(playback.repeatMode.label)
            }
        }
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "Als Nächstes")).font(.headline)
                Button(String(localized: "Bearbeiten")) { showingQueue = true }.font(.caption)
                Spacer()
                if playback.shuffle { Label(String(localized: "Zufällig"), systemImage: "shuffle").font(.caption).foregroundStyle(.mint) }
                if playback.repeatMode != .off { Label(playback.repeatMode.label, systemImage: playback.repeatMode.symbol).font(.caption).foregroundStyle(.mint) }
            }
            ForEach(playback.upNext.prefix(25)) { media in
                UpNextRow(media: media)
            }
        }
        .padding(.top, 8)
    }

    private func time(_ value: Double) -> String {
        let s = Int(max(0, value.isFinite ? value : 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s/3600, (s/60)%60, s%60) : String(format: "%d:%02d", s/60, s%60)
    }
}

/// Tap to jump there, swipe right to add it to the queue, left to take it out.
private struct UpNextRow: View {
    let media: Media
    @EnvironmentObject private var playback: PlayerModel
    @EnvironmentObject private var model: AppModel
    @State private var isSwiping = false

    var body: some View {
        Button { if !isSwiping { playback.jump(to: media) } } label: {
            HStack(spacing: 12) {
                ArtworkView(id: model.artworkID(for: media), symbol: media.symbol, cornerRadius: 5).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    Text(media.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let duration = durationLabel(media.duration) { Text(duration).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSwiping)
        .modifier(QueueSwipe(enabled: true, perform: { playback.addToQueue(media, model: model) },
                             remove: { playback.removeUpcoming(media) }, isSwiping: $isSwiping))
        .accessibilityAction(named: String(localized: "Ans Ende der Warteschlange")) { playback.addToQueue(media, model: model) }
        .accessibilityAction(named: String(localized: "Aus der Liste entfernen")) { playback.removeUpcoming(media) }
    }
}

/// The category "Playlists" under Musik.
struct PlaylistRows: View {
    let search: String
    @EnvironmentObject private var model: AppModel

    private var playlists: [Playlist] {
        model.availablePlaylists.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if search.isEmpty {
                autoRow(.favorites, String(localized: "Lieblingssongs"))
                autoRow(.mostPlayed, String(localized: "Meistgehört"))
                autoRow(.recent, String(localized: "Zuletzt gespielt"))
                autoRow(.newlyAdded, String(localized: "Neu hinzugefügt"))
                autoRow(.rediscover, String(localized: "Lange nicht gehört"))
            }
            if playlists.isEmpty && !search.isEmpty {
                SearchEmptyView(query: search)
            } else if playlists.isEmpty && !model.isOffline {
                ContentUnavailableView(String(localized: "Deine Zusammenstellungen"), systemImage: "music.note.list",
                                       description: Text(String(localized: "Erstelle eine Playlist über das Plus oder direkt beim Song über das …-Menü → „Zu Playlist hinzufügen“.")))
            }
            ForEach(playlists) { playlist in
                let tracks = playlist.mediaIds.compactMap { model.mediaByID[$0] }
                NavigationLink { PlaylistDetail(id: playlist.id) } label: {
                    HStack(spacing: 14) {
                        PlaylistMosaic(tracks: tracks).frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(playlist.name).font(.subheadline.weight(.semibold))
                            Text("\(model.isOffline ? tracks.count : playlist.mediaIds.count) Titel").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if !model.isOffline {
                        Button(String(localized: "Löschen"), systemImage: "trash", role: .destructive) { Task { await model.deletePlaylist(playlist) } }
                    }
                }
            }
        }
    }

    private func autoRow(_ kind: AutoPlaylistView.Kind, _ title: String) -> some View {
        NavigationLink { AutoPlaylistView(kind: kind) } label: {
            HStack(spacing: 14) {
                AutoPlaylistCover(kind: kind).frame(width: 48, height: 48)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PlaylistMosaic: View {
    let tracks: [Media]
    /// Image from the asset catalog for a playlist without covers.
    var placeholder: String? = nil
    @EnvironmentObject private var model: AppModel
    private var covers: [String] {
        var seen = Set<String>()
        return tracks.compactMap { model.artworkID(for: $0) }.filter { seen.insert($0).inserted }.prefix(4).map { $0 }
    }
    var body: some View {
        let ids = covers
        Group {
            if ids.count >= 2 {
                // Two or three different covers repeat crosswise, so that the square stays full.
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { ArtworkView(id: ids[0], cornerRadius: 0); ArtworkView(id: ids[1], cornerRadius: 0) }
                    GridRow {
                        ArtworkView(id: ids.count == 2 ? ids[1] : ids[2], cornerRadius: 0)
                        ArtworkView(id: ids.count == 4 ? ids[3] : ids[0], cornerRadius: 0)
                    }
                }
            } else if ids.isEmpty, let placeholder {
                Image(placeholder).resizable().scaledToFill().accessibilityHidden(true)
            } else {
                ArtworkView(id: ids.first, symbol: "music.note.list", cornerRadius: 0)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct PlaylistDetail: View {
    let id: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var personal: Personal
    @EnvironmentObject private var playback: PlayerModel
    @State private var editing = false
    private var playlist: Playlist? { model.playlists.first { $0.id == id } }
    /// (position in the playlist, track) for tracks that still exist.
    private var entries: [(Int, Media)] {
        (playlist?.mediaIds ?? []).enumerated().compactMap { index, id in model.mediaByID[id].map { (index, $0) } }
    }
    private var tracks: [Media] { entries.map { $0.1 } }

    var body: some View {
        let rows = entries
        let list = rows.map { $0.1 }
        List {
            Section {
                VStack(spacing: 12) {
                    PlaylistMosaic(tracks: list).frame(width: 150, height: 150)
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                    Text(playlist?.name ?? String(localized: "Playlist")).font(.title2.bold()).multilineTextAlignment(.center)
                    let minutes = Int(list.compactMap(\.duration).reduce(0, +) / 60)
                    Text(minutes > 0 ? "\(list.count) Titel · \(minutes) Min." : "\(list.count) Titel").font(.caption).foregroundStyle(.secondary)
                    CollectionPlayButtons(tracks: list, collection: id) { personal.recordPlaylistPlay(id) }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(rows.indices, id: \.self) { index in
                    MediaRow(media: rows[index].1, queue: list, inList: true) {
                        playback.applySettings(ofCollection: id)
                        personal.recordPlaylistPlay(id)
                    }
                }
                .onDelete { offsets in remove(offsets, rows: rows) }
                .onMove { from, to in move(from, to, rows: rows) }
                if list.isEmpty {
                    Text(String(localized: "Füge Titel über das …-Menü eines Songs hinzu („Zu Playlist hinzufügen“) oder über „Bearbeiten“."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerRoom()
        .navigationTitle(playlist?.name ?? String(localized: "Playlist"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(String(localized: "Titel hinzufügen oder umbenennen"), systemImage: "pencil") { editing = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(playlist == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let playlist {
                    DownloadAllButton(tracks: tracks, automatic: Binding(get: { model.isAutoDownloading(playlist: playlist) },
                                                                         set: { model.setAutoDownload(playlist: playlist, $0) }),
                                      automaticLabel: String(localized: "Automatisch offline halten"))
                }
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .sheet(isPresented: $editing) { PlaylistEditor(playlist: playlist).environmentObject(model) }
    }

    private func remove(_ offsets: IndexSet, rows: [(Int, Media)]) {
        guard let playlist else { return }
        let positions = Set(offsets.map { rows[$0].0 })
        let ids = playlist.mediaIds.enumerated().filter { !positions.contains($0.offset) }.map { $0.element }
        Task { await model.savePlaylist(name: playlist.name, ids: ids, id: playlist.id) }
    }

    private func move(_ from: IndexSet, _ to: Int, rows: [(Int, Media)]) {
        guard let playlist else { return }
        var visible = rows.map { $0.1.id }
        visible.move(fromOffsets: from, toOffset: to)
        let positions = Set(rows.map { $0.0 })
        let unavailable = playlist.mediaIds.enumerated().filter { !positions.contains($0.offset) }.map { $0.element }
        Task { await model.savePlaylist(name: playlist.name, ids: visible + unavailable, id: playlist.id) }
    }
}

struct PlaylistEditor: View {
    let playlist: Playlist?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var ids: [String] = []
    @State private var saving = false
    @State private var search = ""
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var candidates: [Media] {
        let selected = Set(ids)
        return model.items.filter {
            $0.kind == "audio" && !selected.contains($0.id) &&
            (search.isEmpty || "\($0.title) \($0.subtitle)".localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(String(localized: "Meine Playlist"), text: $name)
                    if trimmedName.utf8.count > 200 { Text(String(localized: "Der Name darf höchstens 200 UTF-8-Bytes enthalten.")).font(.caption).foregroundStyle(.orange) }
                } header: { Text(String(localized: "Name")) }
                Section(String(localized: "Reihenfolge")) {
                    ForEach(Array(ids.enumerated()), id: \.offset) { _, id in
                        Text(model.mediaByID[id]?.title ?? String(localized: "Nicht mehr verfügbar"))
                    }
                    .onMove { from, to in ids.move(fromOffsets: from, toOffset: to) }
                    .onDelete { ids.remove(atOffsets: $0) }
                }
                Section {
                    ForEach(candidates) { media in
                        Button { ids.append(media.id) } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(media.title)
                                    if !media.subtitle.isEmpty { Text(media.subtitle).font(.caption).foregroundStyle(.secondary) }
                                }
                            } icon: { Image(systemName: "plus.circle") }
                        }.disabled(ids.count >= 500)
                    }
                    if !search.isEmpty && candidates.isEmpty { Text(String(localized: "Keine passenden Titel gefunden.")).foregroundStyle(.secondary) }
                } header: { Text("Titel hinzufügen · \(ids.count)/500") }
            }
            .searchable(text: $search, prompt: String(localized: "Titel hinzufügen: suchen"))
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            .navigationTitle(playlist == nil ? String(localized: "Neue Playlist") : String(localized: "Playlist bearbeiten"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(String(localized: "Abbrechen")) { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Speichern")) {
                        saving = true
                        Task {
                            model.error = nil
                            let saved = await model.savePlaylist(name: trimmedName, ids: ids, id: playlist?.id)
                            saving = false
                            if saved { dismiss() }
                        }
                    }.disabled(saving || trimmedName.isEmpty || trimmedName.utf8.count > 200 || ids.count > 500)
                }
                ToolbarItem(placement: .bottomBar) { EditButton() }
            }
            .onAppear { name = playlist?.name ?? ""; ids = playlist?.mediaIds ?? [] }
        }
    }
}

struct FilesView: View {
    let path: String
    @EnvironmentObject private var model: AppModel
    @State private var directories: [String] = []
    @State private var files: [Media] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var requestID = UUID()
    var body: some View {
        List {
            ForEach(directories, id: \.self) { directory in
                NavigationLink { FilesView(path: directory) } label: { Label(displayName((directory as NSString).lastPathComponent), systemImage: "folder.fill") }
            }
            ForEach(files) { media in MediaRow(media: media, queue: files.filter { $0.kind == "audio" }, inList: true) }
            if loading { ProgressView() }
            if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
            if !loading && files.isEmpty && directories.isEmpty && failure == nil { ContentUnavailableView(String(localized: "Leerer Ordner"), systemImage: "folder") }
        }
        .miniPlayerRoom()
        .navigationTitle(path.isEmpty ? String(localized: "Dateien") : displayName((path as NSString).lastPathComponent))
        .task(id: path) { await load() }
        .refreshable { await load() }
    }
    private func load() async {
        guard let api = model.api else { return }
        let expected = model.revision
        let request = UUID()
        requestID = request
        loading = true; failure = nil
        defer { if requestID == request { loading = false } }
        do {
            var all: [Media] = []
            var folders: [String] = []
            while true {
                let page: DirectoryPage = try await api.get("/v1/files", query: [URLQueryItem(name: "path", value: path), URLQueryItem(name: "offset", value: "\(all.count)"), URLQueryItem(name: "limit", value: "500")])
                guard expected == model.revision, requestID == request, !Task.isCancelled else { return }
                folders = page.directories
                all += page.files
                if all.count >= page.total || page.files.isEmpty { break }
            }
            files = all; directories = folders
        } catch {
            guard expected == model.revision, requestID == request, !Task.isCancelled else { return }
            failure = error is URLError ? String(localized: "Server nicht erreichbar. Zuletzt bekannte Dateien werden angezeigt.") : error.localizedDescription
            files = model.items.filter { ($0.path as NSString).deletingLastPathComponent == path }
            let prefix = path.isEmpty ? "" : path + "/"
            directories = Array(Set(model.items.compactMap { media -> String? in
                guard media.path.hasPrefix(prefix) else { return nil }
                let remainder = String(media.path.dropFirst(prefix.count))
                guard let slash = remainder.firstIndex(of: "/") else { return nil }
                return prefix + remainder[..<slash]
            })).sorted()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlayerModel
    @AppStorage("miniply.cellularDownloads") private var cellularDownloads = false
    @AppStorage(AutoDownloadSettings.wifiOnlyKey) private var autoDownloadWifiOnly = true
    @AppStorage(AutoDownloadSettings.removeWatchedKey) private var removeWatched = false
    @AppStorage("mediaserver.subtitles") private var subtitles = "off"
    @AppStorage("mediaserver.fade") private var fade = 0.0
    @AppStorage("mediaserver.normalize") private var normalize = true
    @AppStorage(OutageAlerts.enabledKey) private var outageAlerts = false
    @State private var alertsDenied = false
    var body: some View {
        List {
            if model.isOffline {
                ConnectionBanner().listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            Section(String(localized: "Verbindung")) {
                LabeledContent(String(localized: "Server"), value: model.connection?.baseURL.host ?? "—")
                NavigationLink { ConnectionStatusView() } label: {
                    LabeledContent(String(localized: "Status"), value: model.serverStatus.title)
                }
                Text(String(localized: "Dateien bleiben auf deiner SSD. Der Zugriff erfolgt über deinen HTTPS-Zugangspunkt.")).font(.caption).foregroundStyle(.secondary)
                Button(String(localized: "Bibliothek neu einlesen"), systemImage: "arrow.clockwise") { Task { await model.rescan() } }.disabled(model.loading)
                if model.loading { ProgressView() }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
                if let updated = model.lastRefresh {
                    LabeledContent(String(localized: "Bibliothek aktualisiert")) { Text(updated, style: .relative).foregroundStyle(.secondary) }
                }
            }
            Section {
                Toggle(String(localized: "Bei Ausfall benachrichtigen"), isOn: $outageAlerts)
                    .onChange(of: outageAlerts) { _, enabled in Task { await changeOutageAlerts(enabled) } }
                if alertsDenied {
                    Text(String(localized: "Mitteilungen sind für Mediaserver ausgeschaltet. Erlaube sie in den iOS-Einstellungen."))
                        .font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Text(String(localized: "Pi und VPS prüfen sich alle 5 Minuten gegenseitig. Antwortet einer etwa 10 Minuten nicht, kommt eine Mitteilung, und noch eine, sobald er wieder da ist."))
            }
            if let storage = model.storage {
                Section("SSD am Server") {
                    ProgressView(value: Double(storage.totalBytes - min(storage.availableBytes, storage.totalBytes)), total: Double(max(1, storage.totalBytes)))
                    LabeledContent(String(localized: "Verfügbar"), value: byteLabel(storage.availableBytes))
                    LabeledContent(String(localized: "Gesamt"), value: byteLabel(storage.totalBytes))
                    LabeledContent("Indexiert", value: String(localized: "\(storage.fileCount) Dateien · \(byteLabel(storage.indexedBytes))"))
                }
            }
            Section(String(localized: "Bibliothek und Downloads")) {
                NavigationLink { DownloadsView() } label: { Label(String(localized: "Downloads"), systemImage: "arrow.down.circle") }
                NavigationLink { FilesView(path: "") } label: { Label("SSD durchsuchen", systemImage: "folder") }
                NavigationLink { UploadView() } label: { Label(String(localized: "Vom iPhone hochladen").forThisDevice, systemImage: "square.and.arrow.up") }
                NavigationLink { MusicFinderView() } label: { Label(String(localized: "Musik finden"), systemImage: "magnifyingglass") }
                if model.followsSupported {
                    NavigationLink { FollowedArtistsView() } label: { Label(String(localized: "Künstler, denen du folgst"), systemImage: "bell") }
                }
                Toggle(String(localized: "Downloads über Mobilfunk"), isOn: $cellularDownloads)
                Toggle(String(localized: "Automatische Downloads nur im WLAN"), isOn: $autoDownloadWifiOnly)
                Toggle(String(localized: "Gesehene Folgen und Filme entfernen"), isOn: $removeWatched)
                Picker(String(localized: "Untertitel"), selection: $subtitles) {
                    Text(String(localized: "Aus")).tag("off")
                    Text(String(localized: "Deutsch")).tag("de")
                    Text(String(localized: "Englisch")).tag("en")
                    Text(String(localized: "Erste verfügbare")).tag("auto")
                }
                Text(String(localized: "Untertitel gibt es, sobald neben dem Video eine .srt-Datei liegt oder der Server sie aus der Tonspur erstellt hat, dann in der Sprache des Videos. Wähle dafür „Erste verfügbare“.")).font(.caption).foregroundStyle(.secondary)
                LabeledContent(String(localized: "Auf diesem iPhone").forThisDevice, value: String(localized: "\(model.offline.count) Dateien · \(byteLabel(model.offlineBytes))"))
                Text(String(localized: "Neue Downloads verwenden standardmäßig WLAN. Bricht die Verbindung ab oder antwortet der Server kurz nicht, setzt die App den Download selbst fort, auch Stunden später. Playlists und Serien lassen sich über das Download-Symbol automatisch offline halten: neue Titel und die \(AutoDownloadSettings.upcomingEpisodes) Folgen nach der zuletzt gesehenen. Ohne WLAN holt die App sie nach, sobald du wieder im WLAN bist. „Gesehene Folgen und Filme entfernen“ löscht eine heruntergeladene Folge vom iPhone, sobald du sie fertig geschaut hast. Im Datensparmodus lädt die App nichts automatisch.").forThisDevice).font(.caption).foregroundStyle(.secondary)
            }
            StreamingSettingsSection()
            Section {
                Stepper(value: $fade, in: 0...12, step: 1) {
                    LabeledContent("Ein- und Ausblenden", value: fade == 0 ? String(localized: "Aus") : "\(Int(fade)) s")
                }
                Toggle(String(localized: "Lautstärke angleichen"), isOn: $normalize)
            } header: { Text(String(localized: "Musikwiedergabe")) } footer: {
                Text(String(localized: "Songs werden am Ende ausgeblendet und der nächste eingeblendet. Aufeinanderfolgende Songs eines Albums laufen ohne Pause und ohne Blende ineinander. „Lautstärke angleichen“ nutzt ReplayGain-Werte aus den Dateien, sonst die vom Server gemessene Lautheit. Gilt ab dem nächsten Song."))
            }
            AppHelpSection()
            Section {
                Button(String(localized: "Verbindung entfernen"), role: .destructive) { playback.stop(); model.disconnect() }
            } footer: { Text(String(localized: "Lokale Downloads bleiben erhalten und erscheinen nach erneuter Verbindung mit derselben Serveradresse.")) }
        }
        .miniPlayerRoom()
        .navigationTitle(String(localized: "Einstellungen"))
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var category = 0
    private var records: [OfflineRecord] {
        model.offline.filter { record in
            switch category {
            case 1: record.media.kind == "audio"
            case 2: record.media.kind == "video" && record.media.series == nil
            case 3: record.media.series != nil
            default: true
            }
        }
    }
    var body: some View {
        List {
            Section {
                Picker(String(localized: "Downloadart"), selection: $category) {
                    Text(String(localized: "Alle")).tag(0); Text("Musik").tag(1); Text("Filme").tag(2); Text("Serien").tag(3)
                }.pickerStyle(.segmented).listRowBackground(Color.clear)
                Text(String(localized: "Fertige Downloads sind ohne Internet verfügbar.")).font(.caption).foregroundStyle(.secondary)
            }
            if !model.waitingDownloads.isEmpty {
                Section {
                    ForEach(model.waitingDownloads) { media in
                        HStack {
                            Image(systemName: "wifi").foregroundStyle(.secondary)
                            Text(media.title).lineLimit(1)
                            Spacer()
                            Text(byteLabel(media.downloadMedia.bytes)).font(.caption).foregroundStyle(.secondary)
                            Button(String(localized: "Entfernen"), role: .destructive) { model.stopWaiting(media) }
                                .font(.caption).buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text(String(localized: "Wartet auf WLAN"))
                } footer: {
                    Text(String(localized: "Startet von selbst, sobald dein iPhone im WLAN ist und der Server antwortet.").forThisDevice)
                }
            }
            if !model.queuedDownloads.isEmpty {
                Section(String(localized: "Wird heruntergeladen")) {
                    ForEach(model.queuedDownloads) { media in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(media.title).lineLimit(1)
                                Spacer()
                                DownloadPauseButton(media: media)
                                Button(String(localized: "Abbrechen"), role: .destructive) { Task { await model.cancelDownload(media) } }
                                    .font(.caption).buttonStyle(.borderless)
                            }
                            LiveDownloadProgress { progress in
                                ProgressView(value: progress[media.id] ?? 0)
                                Text(model.pausedDownloads.contains(media.id) ? "Pausiert · \(Int((progress[media.id] ?? 0) * 100)) % · \(byteLabel(media.bytes))" : "\(Int((progress[media.id] ?? 0) * 100)) % · \(byteLabel(media.bytes))").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
            if records.isEmpty { ContentUnavailableView(String(localized: "Keine fertigen Downloads"), systemImage: "arrow.down.circle", description: Text(String(localized: "Speichere Musik, Filme oder einzelne Serienfolgen über ihr Aktionsmenü auf diesem iPhone.").forThisDevice)) }
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 4) {
                    if let series = record.media.series { Text(series + " · " + displayName(((record.media.path as NSString).deletingLastPathComponent as NSString).lastPathComponent)).font(.caption).foregroundStyle(.secondary) }
                    MediaRow(media: record.media, queue: records.map(\.media).filter { $0.kind == "audio" }, inList: true)
                }
                    .swipeActions { Button(String(localized: "Entfernen"), role: .destructive) { model.removeDownload(record) } }
            }
        }
        .miniPlayerRoom()
        .navigationTitle(String(localized: "Downloads"))
    }
}

private struct MiniPlayerVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var miniPlayerVisible: Bool {
        get { self[MiniPlayerVisibleKey.self] }
        set { self[MiniPlayerVisibleKey.self] = newValue }
    }
}

/// The bar floats over the screens, so that each one must leave room for it
/// itself: an inset around the NavigationStack does not reach its scroll views.
private struct MiniPlayerRoom: ViewModifier {
    private static let height: CGFloat = 64
    @Environment(\.miniPlayerVisible) private var isVisible

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if isVisible { Color.clear.frame(height: Self.height) }
        }
    }
}

extension View {
    func miniPlayerRoom() -> some View { modifier(MiniPlayerRoom()) }
}

/// Back or forward: a tap changes the track, holding jumps 10 seconds within it.
/// Holding forward still works on the last track, where a tap has nothing to do.
struct HoldSkipButton: View {
    let symbol: String
    let label: String
    let holdLabel: String
    var font: Font = .title
    var color: Color? = nil
    var canTap = true
    let tap: () -> Void
    let hold: () -> Void
    @State private var holds = 0

    var body: some View {
        Image(systemName: symbol)
            .font(font)
            .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
            .opacity(canTap ? 1 : 0.4)
            .contentShape(Rectangle())
            .onTapGesture { if canTap { tap() } }
            .onLongPressGesture(minimumDuration: 0.4) { holds += 1; hold() }
            .sensoryFeedback(.impact(weight: .light), trigger: holds)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if canTap { tap() } }
            .accessibilityAction(named: holdLabel) { hold() }
    }
}

struct MiniPlayerBar: View {
    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    @EnvironmentObject private var playback: PlayerModel
    @EnvironmentObject private var model: AppModel
    @Binding var showPlayer: Bool
    private func status(for media: Media, current: Media) -> String {
        guard media.id == current.id else { return media.series ?? media.subtitle }
        if playback.preparing { return playback.phase ?? String(localized: "Wird geladen …") }
        if playback.buffering { return String(localized: "Puffert …") }
        return media.series ?? media.subtitle
    }
    private var isActive: Bool { playback.isPlaying || playback.intendsToPlay }

    var body: some View {
        Group {
            if let current = playback.current {
                HStack(spacing: 6) {
                    TrackCarousel(previous: playback.previousItem, current: current, next: playback.followingItem,
                                  onPrevious: { playback.skipToPrevious() }, onNext: { playback.next() }) { media in
                        HStack(spacing: 10) {
                            cover(media)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(media.series == nil ? media.title : (model.episodeInfo(media)?.name ?? media.episodeTitle))
                                    .font(.footnote.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                // A fixed color: the system's secondary styles vanish
                                // on the material of this bar once it is clipped.
                                let line = status(for: media, current: current)
                                if !line.isEmpty {
                                    Text(line).font(.caption2).foregroundStyle(Color.white.opacity(0.7)).lineLimit(1)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .onTapGesture {
                        if current.kind == "video" {
                            playback.startIfRestored()
                            VideoPresenter.present(playback)
                        } else { showPlayer = true }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    if current.kind == "video" {
                        Button { playback.seek(playback.seconds - 15) } label: {
                            Image(systemName: "gobackward.15").font(.callout).foregroundStyle(.white).frame(width: 34, height: 34)
                        }
                        .accessibilityLabel(String(localized: "15 Sekunden zurück"))
                    } else {
                        HoldSkipButton(symbol: "backward.fill", label: String(localized: "Vorheriger Titel"),
                                       holdLabel: String(localized: "10 Sekunden zurück"), font: .callout, color: .white,
                                       tap: { playback.previous() }, hold: { playback.jump(by: -PlayerModel.holdJump) })
                            .frame(width: 34, height: 34)
                    }
                    Button { playback.toggle() } label: {
                        Image(systemName: isActive ? "pause.fill" : "play.fill")
                            .font(.callout)
                            .foregroundStyle(.black)
                            .frame(width: 34, height: 34)
                            .background(.white, in: Circle())
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(isActive ? String(localized: "Pausieren") : String(localized: "Abspielen"))
                    if current.kind == "video" {
                        Button { playback.seek(playback.seconds + 15) } label: {
                            Image(systemName: "goforward.15").font(.callout).foregroundStyle(.white).frame(width: 34, height: 34)
                        }
                        .accessibilityLabel(String(localized: "15 Sekunden vor"))
                    } else {
                        HoldSkipButton(symbol: "forward.fill", label: String(localized: "Nächster Titel"),
                                       holdLabel: String(localized: "10 Sekunden vor"), font: .callout, color: .white,
                                       canTap: playback.hasNext,
                                       tap: { playback.next() }, hold: { playback.jump(by: PlayerModel.holdJump) })
                            .frame(width: 34, height: 34)
                    }
                }
                .padding(.leading, 7)
                .padding(.trailing, 8)
                .padding(.vertical, 7)
                .background { background(current) }
                .overlay(alignment: .bottom) { progressLine }
                .clipShape(Self.shape)
                .overlay(Self.shape.strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if let toast = playback.toast {
                PlayerToast(text: toast)
                    .offset(y: -46)
                    .allowsHitTesting(false)
            }
        }
        .sensoryFeedback(.success, trigger: playback.toast) { _, new in new != nil }
        .animation(.spring(duration: 0.3), value: playback.toast)
        .animation(.spring(duration: 0.35), value: playback.current == nil)
        .task(id: playback.current?.id) {
            await model.preloadLyrics([playback.current, playback.followingItem].compactMap { $0 })
        }
        .task(id: playback.current?.id) {
            // Cover for lock screen and Control Center.
            guard let current = playback.current, let id = model.artworkID(for: current) else { return }
            let image = await ArtworkCache.shared.image(id, model: model)
            if playback.current?.id == current.id { playback.setArtwork(image, id: current.id) }
        }
    }

    /// Videos as a small picture of the film, songs with their square cover.
    private func cover(_ media: Media) -> some View {
        let isVideo = media.kind == "video"
        return ArtworkView(id: isVideo ? model.thumbnailID(for: media) ?? model.artworkID(for: media) : model.artworkID(for: media),
                           symbol: media.symbol, cornerRadius: 8, aspect: isVideo ? 16.0 / 9.0 : 1)
            .frame(width: isVideo ? 64 : 38, height: isVideo ? 36 : 38)
    }

    /// The cover's colors shine through, so the bar belongs to what is playing.
    private func background(_ current: Media) -> some View {
        ZStack {
            Color(white: 0.13)
            BlurredArtwork(id: model.artworkID(for: current), softness: 0.08)
                .opacity(0.55)
            Color.black.opacity(0.25)
        }
        .allowsHitTesting(false)
    }

    private var progressLine: some View {
        GeometryReader { geometry in
            let fraction = playback.duration > 0 ? min(1, max(0, playback.seconds / playback.duration)) : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.18))
                Rectangle().fill(.white).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

extension SettingsView {
    @MainActor
    func changeOutageAlerts(_ enabled: Bool) async {
        guard enabled else {
            UIApplication.shared.unregisterForRemoteNotifications()
            UserDefaults.standard.removeObject(forKey: OutageAlerts.sentKey)
            return
        }
        alertsDenied = false
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { outageAlerts = false; alertsDenied = true; return }
        UIApplication.shared.registerForRemoteNotifications()
        await model.registerPushDevice()
    }
}
