import AVFoundation
import MediaPlayer
import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

@MainActor
final class PlayerModel: ObservableObject {
    /// A queue player so the next song can follow without a gap.
    let player = AVQueuePlayer()
    @Published var current: Media?
    @Published var isPlaying = false
    @Published var preparing = false
    /// What the player is doing while preparing, shown under the controls.
    @Published private(set) var phase: String?
    /// True when the user wants playback (also while loading/buffering), so
    /// the button can show "pause" instead of a spinner.
    @Published private(set) var intendsToPlay = false
    @Published private(set) var buffering = false
    /// The stream was lost and is being restored at the same position.
    @Published private(set) var reconnecting = false
    /// Files of this server that iOS refused to play (status screen).
    @Published private(set) var unplayableIDs: Set<String> = []
    @Published private(set) var toast: String?
    private var toastTask: Task<Void, Never>?
    @Published var seconds: Double = 0
    @Published var duration: Double = 0
    @Published var error: String?
    @Published var progressNotice: String?
    /// Shuffle and repeat apply to music queues; series episodes stay in order.
    @Published private(set) var shuffle = UserDefaults.standard.bool(forKey: "mediaserver.shuffle")
    @Published private(set) var repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "mediaserver.repeat") ?? "") ?? .off
    @Published private(set) var queue: [Media] = []
    private var originalQueue: [Media] = []
    /// Songs added by hand. They come before the songs that would follow anyway
    /// and stay ahead of them, also when a new album or playlist starts.
    private var queuedIDs: Set<String> = []
    /// Subtitle cues of the current video (shown over the full-screen player).
    @Published private(set) var subtitleCues: [SubtitleCue] = []
    @Published private(set) var activeSubtitle: SubtitleRef?
    /// Per-video choice: subtitle ID, or "" for off. Otherwise the setting.
    private var subtitleChoice: [String: String] = [:]
    private var subtitleTask: Task<Void, Never>?
    /// Sleep timer: pause at this time, or at the end of the current track.
    @Published private(set) var sleepDeadline: Date?
    @Published private(set) var sleepAtTrackEnd = false
    /// The next track starts automatically after one ended: fade it in.
    private var fadeInNext = false
    private var lastNowPlayingSeconds = 0.0
    private var lastNowPlayingDuration = 0.0
    private var lastNowPlayingUpdate = Date.distantPast
    /// Favourites, statistics and watched state (set by the root view).
    weak var personal: Personal?
    private var artwork: (id: String, image: UIImage)?
    private var index = 0
    private var generation = UUID()
    private var api: API?
    private weak var model: AppModel?
    private var timer: Any?
    private var status: NSKeyValueObservation?
    private var rate: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var lastSaved = -10.0
    private var progressPrefix = ""
    /// Positions not yet on the server: seconds and when they were saved.
    private var pending: [String: (seconds: Double, at: Double)] = [:]
    private var syncing = false
    private var resumeAfterInterruption = false
    private var wantsToPlay = false {
        didSet { if intendsToPlay != wantsToPlay { intendsToPlay = wantsToPlay } }
    }
    private var positionReady = false
    private var isStreaming = false
    private var usingAdaptive = false
    /// Videos whose adaptive copy failed; they use the normal file instead.
    private var adaptiveRefused: Set<String> = []
    private var preparation: Task<Void, Never>?
    private var network = NetworkState()
    private var reconnectTask: Task<Void, Never>?
    private var reconnectStarted: Date?
    private var reconnectAttempt = 0
    private var reconnectPosition = 0.0
    private var stallWatch: Task<Void, Never>?
    private var phantomStart: Double?
    /// The item this model treats as current. During an automatic advance
    /// `player.currentItem` is already the next one.
    private weak var activeItem: AVPlayerItem?
    private struct PreparedTrack {
        let media: Media
        let item: AVPlayerItem
        let duration: Double
        let isStream: Bool
        /// Without the fade-in, for skipping by hand.
        let plainMix: AVAudioMix?
    }
    private var prepared: PreparedTrack?
    private var preparedStatus: NSKeyValueObservation?
    private var preloadTask: Task<Void, Never>?
    private var preloadingID: String?
    private var preloadFailedID: String?
    /// Seconds before the end of a song at which the next one is prepared.
    var preloadLead = 30.0
    private static let songsAhead = 5
    private static let songsAheadOnMobile = 2
    private static let songsBehind = 5
    var preloadedID: String? { prepared?.media.id }
    /// Streaming stopped because mobile data is switched off for this kind.
    private var blockedByPolicy = false
    var reconnectLimit = ReconnectPolicy.limit
    var stallTimeout = 20.0

    /// Containers understood by this OS. Actual codec support is checked per asset.
    static var nativeFileExtensions: [String] {
        let types: [UTType]
        if #available(iOS 26.0, *) { types = AVURLAsset.audiovisualContentTypes }
        else { types = AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) } }
        return Set(types.compactMap(\.preferredFilenameExtension).map { $0.uppercased() }).sorted()
    }

    private static func incompatibleMessage(for media: Media) -> String {
        let target = media.kind == "video" ? "MP4 mit H.264 und AAC" : "M4A mit AAC oder ALAC"
        return String(localized: "Diese \(media.formatLabel)-Datei lässt sich auf diesem Gerät nicht abspielen. Container oder Codec werden nicht unterstützt, oder die Datei ist beschädigt. Erstelle am Mac eine kompatible Kopie als \(target).")
    }

    /// Failures worth retrying: the network or server, not the file itself.
    /// A rejected stream gets another try because retrying fetches a new
    /// ticket; a revoked token then fails there with `.unauthorized`.
    static func isTransientFailure(_ error: Error?) -> Bool {
        if let failure = error as? MiniplyError {
            if case .server(let status) = failure { return (502...504).contains(status) }
            return false
        }
        var nested = error as NSError?
        var depth = 0
        while let value = nested, depth < 8 {
            if value.domain == NSURLErrorDomain, [
                NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
                NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive,
                NSURLErrorSecureConnectionFailed
            ].contains(value.code) { return true }
            if value.domain == AVFoundationErrorDomain, value.code == AVError.Code.contentIsNotAuthorized.rawValue { return true }
            nested = value.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    static func playbackErrorMessage(_ error: Error?, media: Media) -> String {
        if let message = error as? MiniplyError { return message.localizedDescription }
        var errors: [NSError] = []
        var nested = error as NSError?
        while let value = nested, errors.count < 8 {
            errors.append(value)
            nested = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if errors.contains(where: { $0.domain == NSURLErrorDomain && [
            NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
            NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted
        ].contains($0.code) }) {
            return String(localized: "Die Verbindung zum Medienserver ist unterbrochen. Prüfe deine Internetverbindung und starte die Wiedergabe erneut.")
        }
        if errors.contains(where: { $0.domain == NSURLErrorDomain && $0.code == NSURLErrorFileDoesNotExist }) {
            return String(localized: "Die Datei ist nicht mehr verfügbar. Aktualisiere die Bibliothek oder lade die Offline-Kopie erneut herunter.")
        }
        let codes = errors.filter { $0.domain == AVFoundationErrorDomain }.map(\.code)
        if codes.contains(AVError.Code.referenceForbiddenByReferencePolicy.rawValue) {
            return String(localized: "Diese Datei verweist auf externe Medien. Exportiere sie am Mac als eigenständige Datei mit eingebetteten Audio- und Videodaten.")
        }
        if codes.contains(AVError.Code.contentIsProtected.rawValue) {
            return String(localized: "Diese Datei ist kopiergeschützt und kann hier nicht abgespielt werden. Verwende eine eigene, ungeschützte Mediendatei.")
        }
        if codes.contains(AVError.Code.contentIsNotAuthorized.rawValue) {
            return String(localized: "Der Zugriff auf diese Datei wurde verweigert. Starte die Wiedergabe für ein neues Streaming-Ticket erneut und prüfe bei Bedarf den Serverzugang.")
        }
        let incompatible = [AVError.Code.fileFormatNotRecognized, .fileFailedToParse, .formatUnsupported,
                            .decoderNotFound, .decodeFailed, .undecodableMediaData, .incompatibleAsset]
        if codes.contains(where: { code in incompatible.contains { $0.rawValue == code } }) {
            return incompatibleMessage(for: media)
        }
        return String(localized: "Die \(media.formatLabel)-Datei konnte nicht abgespielt werden. Prüfe die Serververbindung und starte die Wiedergabe erneut. Falls der Fehler bleibt, erstelle am Mac eine kompatible Kopie.")
    }

    private static func inspect(_ asset: AVURLAsset, media: Media, adaptive: Bool = false) async throws -> Double? {
        try await withTaskCancellationHandler {
            guard try await asset.load(.isPlayable) else {
                throw MiniplyError.message(incompatibleMessage(for: media))
            }
            // A playlist names its tracks only once playback has chosen a step.
            if adaptive {
                if let duration = media.duration, duration.isFinite, duration > 0 { return duration }
                let value = try? await asset.load(.duration).seconds
                return value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            }
            let type: AVMediaType = media.kind == "video" ? .video : .audio
            let tracks = try await asset.loadTracks(withMediaType: type)
            var playableTrack = false
            for track in tracks {
                if try await track.load(.isPlayable) { playableTrack = true; break }
            }
            guard playableTrack else { throw MiniplyError.message(incompatibleMessage(for: media)) }
            if let duration = media.duration, duration.isFinite, duration > 0 { return duration }
            let value = try? await asset.load(.duration).seconds
            return value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        } onCancel: { asset.cancelLoading() }
    }

    init() {
        player.actionAtItemEnd = .pause
        timer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        rate = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                // Read current state on the actor: a queued notification may
                // belong to the previous item or precede a user's pause.
                self.isPlaying = self.player.timeControlStatus == .playing
                self.buffering = self.wantsToPlay && self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self.watchForStall()
                self.updateNowPlaying()
            }
        }
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.activeItem else { return }
                self.finished()
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let failure = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.activeItem,
                      let media = self.current else { return }
                self.fail(failure, media: media)
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    let shouldResume = self.wantsToPlay || self.isPlaying
                    self.pause()
                    self.resumeAfterInterruption = shouldResume
                } else {
                    let shouldResume = self.resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    self.resumeAfterInterruption = false
                    if shouldResume { self.resume() }
                }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }; return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }; return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }; return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }; return .success
        }
        // Holding next or previous on the lock screen or in the Dynamic Island sends these.
        commands.seekForwardCommand.addTarget { [weak self] event in
            guard (event as? MPSeekCommandEvent)?.type == .beginSeeking else { return .success }
            Task { @MainActor in self?.jump(by: PlayerModel.holdJump) }; return .success
        }
        commands.seekBackwardCommand.addTarget { [weak self] event in
            guard (event as? MPSeekCommandEvent)?.type == .beginSeeking else { return .success }
            Task { @MainActor in self?.jump(by: -PlayerModel.holdJump) }; return .success
        }
        commands.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let enabled = event.shuffleType != .off
            Task { @MainActor in self?.setShuffle(enabled) }; return .success
        }
        commands.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode = event.repeatType == .one ? .one : event.repeatType == .all ? .all : .off
            Task { @MainActor in self?.setRepeat(mode) }; return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.seek(time) }; return .success
        }
    }

    /// Start `media`. `rearrange` is false for internal moves within the
    /// current (possibly shuffled) queue.
    func play(_ media: Media, in queue: [Media] = [], model: AppModel, rearrange: Bool = true, startAt: Double? = nil, isRetry: Bool = false) {
        recordProgress(seconds)
        reconnectTask?.cancel(); stallWatch?.cancel(); blockedByPolicy = false; isStreaming = false; phantomStart = nil
        usingAdaptive = false
        if !isRetry { reconnecting = false; reconnectStarted = nil; reconnectAttempt = 0 }
        preparation?.cancel()
        generation = UUID()
        let expected = generation
        player.pause()
        isPlaying = false
        buffering = false
        status = nil
        dropPreload()
        player.removeAllItems()
        wantsToPlay = true
        positionReady = false
        resumeAfterInterruption = false
        self.model = model
        api = model.api
        let address = model.connection?.baseURL.absoluteString ?? ""
        let nextPrefix = Self.progressPrefix(address)
        if nextPrefix != progressPrefix {
            pending = [:]
            unplayableIDs = Set(UserDefaults.standard.stringArray(forKey: nextPrefix + "unplayable") ?? [])
        }
        progressPrefix = nextPrefix
        if rearrange {
            fadeInNext = false
            let waiting = media.kind == "audio" ? upNext.filter { queuedIDs.contains($0.id) && $0.id != media.id } : []
            queuedIDs = Set(waiting.map(\.id))
            originalQueue = queue.isEmpty ? [media] : queue
            let order = shuffle && media.kind == "audio" ? Self.shuffled(originalQueue, first: media) : originalQueue
            self.queue = Self.placing(waiting, after: media, in: order)
        } else {
            self.queue = queue.isEmpty ? [media] : queue
        }
        index = self.queue.firstIndex(where: { $0.id == media.id }) ?? 0
        tidyQueued()
        saveSession(current: media)
        if artwork?.id != media.id { artwork = nil }
        if rearrange || current?.id != media.id { personal?.recordPlay(media) }
        restartedTrack = false; seeking = false
        subtitleTask?.cancel(); subtitleCues = []; activeSubtitle = nil
        current = media; seconds = startAt ?? 0; duration = media.duration ?? 0; lastSaved = -10
        preparing = true
        phase = isRetry ? String(localized: "Verbindung wird wiederhergestellt …") : model.localURL(media) != nil ? String(localized: "Datei wird geöffnet …") : String(localized: "Verbindung zum Server …")
        error = nil
        progressNotice = nil
        let selectedAPI = api
        let selectedPrefix = progressPrefix
        preparation = Task {
            do {
                try Task.checkCancellation()
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                let saved = model.localURL(media)
                let cached = saved == nil ? StreamCache.shared.file(for: media, scope: model.downloadScope) : nil
                let local = saved ?? cached
                if local == nil, StreamPolicy.blocks(kind: media.kind, on: network) {
                    throw MiniplyError.message(StreamPolicy.blockedMessage(kind: media.kind))
                }
                // Songs always start from the beginning; only videos resume. The server
                // is asked also for a downloaded file: another device may be further.
                let resumes = media.kind == "video"
                let shouldFetchResume = startAt == nil && resumes && network.online
                async let remoteResume: PlaybackProgress? = shouldFetchResume ? selectedAPI?.playbackProgress(media) : nil
                let url: URL
                let adaptive = local == nil && media.kind == "video" && media.hls == true && !adaptiveRefused.contains(media.id)
                    && !StreamPolicy.prefersOriginal(network)
                if let local { url = local }
                else if let selectedAPI { url = try await selectedAPI.ticket(media, preferAdaptive: adaptive) }
                else { throw MiniplyError.message(String(localized: "Kein Server verbunden und kein Download vorhanden.")) }
                usingAdaptive = adaptive
                try Task.checkCancellation()
                if generation == expected { phase = local != nil ? String(localized: "Datei wird geprüft …") : String(localized: "Stream wird geprüft …") }
                let asset = AVURLAsset(url: url, options: [
                    AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
                ])
                let loadedDuration: Double?
                do { loadedDuration = try await Self.inspect(asset, media: media, adaptive: adaptive) }
                catch {
                    // A damaged copy in the cache must not stop the stream.
                    if cached != nil {
                        StreamCache.shared.remove(media, scope: model.downloadScope)
                        guard generation == expected else { return }
                        play(media, in: self.queue, model: model, rearrange: false, startAt: startAt, isRetry: isRetry)
                        return
                    }
                    if let local, let playback = media.playback {
                        let stored = local.pathExtension.lowercased() == playback.fileExtension ? "Datei" : "Originaldatei"
                        throw MiniplyError.message(String(localized: "Die gespeicherte \(stored) ist auf diesem Gerät nicht abspielbar. Lokale Kopie entfernen und die vorbereitete Wiedergabekopie erneut herunterladen."))
                    }
                    throw error
                }
                try Task.checkCancellation()
                guard generation == expected else { return }
                if let loadedDuration { duration = loadedDuration }
                var resume = resumes ? UserDefaults.standard.double(forKey: selectedPrefix + media.id) : 0
                if let remote = await remoteResume {
                    resume = PlaybackProgress.resumePosition(local: resume,
                                                localAt: UserDefaults.standard.double(forKey: selectedPrefix + media.id + ".at"),
                                                localPending: UserDefaults.standard.bool(forKey: selectedPrefix + media.id + ".pending"),
                                                remote: remote)
                }
                if let startAt { resume = startAt }
                try Task.checkCancellation()
                guard generation == expected else { return }
                phase = String(localized: "Wiedergabe wird vorbereitet …")
                let item = AVPlayerItem(asset: asset)
                if local == nil {
                    item.preferredForwardBufferDuration = StreamPolicy.forwardBuffer(network)
                    item.preferredPeakBitRate = StreamPolicy.peakBitrate(network)
                }
                isStreaming = local == nil
                if media.kind == "audio" {
                    item.audioMix = await Self.audioMix(for: asset, media: media, duration: duration, fadeIn: fadeInNext)
                    try Task.checkCancellation()
                    guard generation == expected else { return }
                }
                fadeInNext = false
                status = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let failed = item.status == .failed
                    let failure = item.error
                    Task { @MainActor in
                        guard let self, self.generation == expected else { return }
                        if failed { self.fail(failure, media: media) }
                    }
                }
                activeItem = item
                player.replaceCurrentItem(with: item)
                if resume.isFinite, resume > 0, duration <= 0 || resume < duration - min(3, duration * 0.05) {
                    await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                }
                try Task.checkCancellation()
                guard generation == expected else { return }
                let position = player.currentTime().seconds
                seconds = position.isFinite ? max(0, position) : 0
                positionReady = true
                preparing = false
                phase = nil
                reconnecting = false
                if wantsToPlay { player.play() }
                updateNowPlaying()
                syncStreamCache()
                if media.kind == "video" { loadSubtitles(for: media) }
            } catch {
                guard generation == expected else { return }
                fail(error, media: media)
            }
        }
    }

    // MARK: Next song

    /// The song that follows on its own, if one may be queued right now.
    private var preloadTarget: Media? {
        guard let current, current.kind == "audio", repeatMode != .one, !sleepAtTrackEnd, !reconnecting else { return nil }
        let next = index + 1 < queue.count ? queue[index + 1] : loops ? queue.first : nil
        guard let next, next.kind == "audio", next.id != current.id else { return nil }
        return next
    }

    /// Drop a queued song that no longer follows; prepare the one that does
    /// once the current song nears its end.
    private func syncPreload() {
        syncStreamCache()
        let target = preloadTarget
        if (prepared?.media.id ?? preloadingID) != target?.id { dropPreload() }
        guard let target, let model, prepared == nil, preloadingID == nil, preloadFailedID != target.id,
              preloadLead > 0, isPlaying, positionReady, duration > 0, duration - seconds <= preloadLead else { return }
        let local = model.localURL(target) ?? StreamCache.shared.file(for: target, scope: model.downloadScope)
        if local == nil, !network.online || network.constrained || StreamPolicy.blocks(kind: target.kind, on: network) { return }
        let selectedAPI = api
        let expected = generation
        let buffer = StreamPolicy.forwardBuffer(network)
        // Within an album played in order the songs run into each other: no fade between them.
        let seamless = Self.continuesAlbum(current, target)
        preloadingID = target.id
        preloadTask = Task {
            do {
                let url: URL
                if let local { url = local }
                else if let selectedAPI { url = try await selectedAPI.ticket(target) }
                else { throw MiniplyError.message(String(localized: "Kein Server verbunden.")) }
                let asset = AVURLAsset(url: url, options: [
                    AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
                ])
                let length = try await Self.inspect(asset, media: target) ?? 0
                let item = AVPlayerItem(asset: asset)
                if local == nil { item.preferredForwardBufferDuration = buffer }
                item.audioMix = await Self.audioMix(for: asset, media: target, duration: length, fadeIn: !seamless)
                let plainMix = await Self.audioMix(for: asset, media: target, duration: length, fadeIn: false)
                try Task.checkCancellation()
                guard generation == expected, preloadTarget?.id == target.id else { return }
                preloadingID = nil
                prepared = PreparedTrack(media: target, item: item, duration: length, isStream: local == nil, plainMix: plainMix)
                preparedStatus = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor in
                        guard let self, self.prepared?.item === item else { return }
                        self.preloadFailedID = target.id
                        self.dropPreload()
                    }
                }
                if seamless, let playing = player.currentItem, let playingAsset = playing.asset as? AVURLAsset, let current = self.current {
                    playing.audioMix = await Self.audioMix(for: playingAsset, media: current, duration: duration, fadeIn: false, fadeOut: false)
                }
                player.actionAtItemEnd = .advance
                player.insert(item, after: player.currentItem)
            } catch {
                guard generation == expected, preloadingID == target.id else { return }
                preloadingID = nil
                // The regular start reports the problem if it is still there.
                preloadFailedID = target.id
            }
        }
    }

    /// Keep the next songs and the last ones as files. Mobile data loads less
    /// and not the song that is already streaming.
    private func syncStreamCache() {
        guard let model, let api, let current, current.kind == "audio", index < queue.count else { return }
        guard network.online, !network.constrained, !StreamPolicy.blocks(kind: "audio", on: network) else {
            StreamCache.shared.pause()
            return
        }
        let ahead = queue[(index + 1)...].prefix(network.expensive ? Self.songsAheadOnMobile : Self.songsAhead)
            .filter { $0.kind == "audio" && model.localURL($0) == nil }
        let behind = queue[..<index].suffix(Self.songsBehind).filter { $0.kind == "audio" }
        let wanted = (network.expensive || model.localURL(current) != nil ? [] : [current]) + ahead
        StreamCache.shared.update(wanted: wanted, keep: [current] + ahead + behind, api: api, scope: model.downloadScope)
    }

    private func dropPreload() {
        preloadTask?.cancel(); preloadTask = nil
        preloadingID = nil
        preparedStatus = nil
        player.actionAtItemEnd = .pause
        if let item = prepared?.item, item !== player.currentItem { player.remove(item) }
        prepared = nil
    }

    /// Continue with the queued song without tearing the player down.
    private func adoptPrepared(_ track: PreparedTrack) {
        generation = UUID()
        let expected = generation
        preparedStatus = nil
        prepared = nil
        preloadFailedID = nil
        player.actionAtItemEnd = .pause
        activeItem = track.item
        isStreaming = track.isStream
        if artwork?.id != track.media.id { artwork = nil }
        personal?.recordPlay(track.media)
        index = queue.firstIndex(where: { $0.id == track.media.id }) ?? index
        tidyQueued()
        saveSession(current: track.media)
        current = track.media
        seconds = 0
        duration = track.duration > 0 ? track.duration : (track.media.duration ?? 0)
        lastSaved = -10
        syncStreamCache()
        restartedTrack = false; seeking = false; fadeInNext = false; phantomStart = nil
        reconnectStarted = nil; reconnectAttempt = 0
        positionReady = true
        error = nil
        progressNotice = nil
        status = track.item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let failure = item.error
            Task { @MainActor in
                guard let self, self.generation == expected, failed else { return }
                self.fail(failure, media: track.media)
            }
        }
        if wantsToPlay { player.play() }
        updateNowPlaying()
    }

    // MARK: Lost connections

    /// Restore a lost stream at its position, or report why that is pointless.
    private func fail(_ failure: Error?, media: Media) {
        let position = reconnecting ? reconnectPosition : seconds
        let retries = wantsToPlay && !blockedByPolicy && model?.localURL(media) == nil && Self.isTransientFailure(failure)
            && Date().timeIntervalSince(reconnectStarted ?? Date()) < reconnectLimit
        if retries {
            scheduleReconnect(media, position: position)
            return
        }
        // A damaged or missing copy must not stop a playable original.
        if usingAdaptive, let model, !Self.isTransientFailure(failure) {
            adaptiveRefused.insert(media.id)
            cancelReconnect()
            if wantsToPlay {
                play(media, in: queue, model: model, rearrange: false, startAt: position > 0 ? position : nil)
            } else {
                // Paused stays paused: the next play starts with the normal file.
                generation = UUID()
                status = nil
                player.removeAllItems()
                positionReady = false
                preparing = false
                phase = nil
                usingAdaptive = false
                seconds = position
            }
            return
        }
        // A damaged copy in the cache must not stop the stream.
        if let model, wantsToPlay, StreamCache.shared.remove(media, scope: model.downloadScope) {
            cancelReconnect()
            play(media, in: queue, model: model, rearrange: false, startAt: position > 0 ? position : nil)
            return
        }
        cancelReconnect()
        dropPreload()
        pause()
        preparing = false
        phase = nil
        error = Self.playbackErrorMessage(failure, media: media)
        if Self.playbackErrorMessage(failure, media: media) == Self.incompatibleMessage(for: media) {
            markUnplayable(media, true)
        }
    }

    private func scheduleReconnect(_ media: Media, position: Double) {
        generation = UUID()
        status = nil
        stallWatch?.cancel()
        player.pause()
        dropPreload()
        player.removeAllItems()
        positionReady = false
        buffering = false
        seconds = position
        reconnectPosition = position
        reconnectStarted = reconnectStarted ?? Date()
        reconnecting = true
        preparing = true
        phase = network.online ? String(localized: "Verbindung unterbrochen, neuer Versuch …") : String(localized: "Warte auf Internetverbindung …")
        updateNowPlaying()
        let wait = ReconnectPolicy.delay(attempt: reconnectAttempt)
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            retryNow()
        }
    }

    private func retryNow() {
        guard reconnecting, let current, let model, wantsToPlay else { return }
        reconnectAttempt += 1
        play(current, in: queue, model: model, rearrange: false, startAt: reconnectPosition, isRetry: true)
    }

    private func cancelReconnect() {
        reconnectTask?.cancel(); reconnectTask = nil
        guard reconnecting else { return }
        reconnecting = false
        reconnectStarted = nil
        reconnectAttempt = 0
        preparation?.cancel()
        generation = UUID()
        preparing = false
        phase = nil
    }

    /// AVPlayer can wait forever on a dead connection without failing. Rebuild
    /// the stream only if nothing more arrived, so slow links keep their data.
    private func watchForStall() {
        stallWatch?.cancel()
        guard buffering, isStreaming, let media = current else { return }
        let expected = generation
        stallWatch = Task {
            var loaded = loadedEnd
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(stallTimeout))
                guard !Task.isCancelled, buffering, generation == expected else { return }
                if loadedEnd <= loaded {
                    scheduleReconnect(media, position: seconds)
                    return
                }
                loaded = loadedEnd
            }
        }
    }

    /// After a seek past the loaded range on a dead connection, AVPlayer can
    /// report "playing" and advance its clock with no data until a false end.
    private func detectPhantomPlayback(at time: Double) -> Bool {
        guard isStreaming, isPlaying, let current, let item = player.currentItem, item.isPlaybackBufferEmpty,
              !item.loadedTimeRanges.contains(where: { $0.timeRangeValue.containsTime(CMTime(seconds: time, preferredTimescale: 600)) }) else {
            phantomStart = nil
            return false
        }
        let start = phantomStart ?? time
        phantomStart = start
        guard time - start >= 3 else { return false }
        phantomStart = nil
        scheduleReconnect(current, position: start)
        return true
    }

    private var loadedEnd: Double {
        activeItem?.loadedTimeRanges.map { $0.timeRangeValue.end.seconds }.max() ?? 0
    }

    func networkChanged(_ next: NetworkState) {
        let previous = network
        network = next
        guard next != previous else { return }
        if next.online && !previous.online, let model { sendSavedPositions(model: model) }
        if isStreaming {
            player.currentItem?.preferredForwardBufferDuration = StreamPolicy.forwardBuffer(next)
            player.currentItem?.preferredPeakBitRate = StreamPolicy.peakBitrate(next)
        }
        guard let current else { return }
        if StreamPolicy.blocks(kind: "audio", on: next), prepared?.isStream == true { dropPreload() }
        if blockedByPolicy, !StreamPolicy.blocks(kind: current.kind, on: next) {
            blockedByPolicy = false
            progressNotice = nil
            resume()
        } else if isStreaming, wantsToPlay, StreamPolicy.blocks(kind: current.kind, on: next) {
            pause()
            blockedByPolicy = true
            progressNotice = StreamPolicy.blockedMessage(kind: current.kind)
        } else if reconnecting {
            if next.online { retryNow() } else { phase = String(localized: "Warte auf Internetverbindung …") }
        } else if buffering, isStreaming, next.online, !previous.online || next.interface != previous.interface {
            scheduleReconnect(current, position: seconds)
        }
    }

    /// Timers do not run while the app is suspended.
    func becameActive() { if reconnecting { retryNow() } }

    func clearUnplayable() {
        unplayableIDs = []
        UserDefaults.standard.removeObject(forKey: progressPrefix + "unplayable")
    }

    private func markUnplayable(_ media: Media, _ unplayable: Bool) {
        guard unplayableIDs.contains(media.id) != unplayable else { return }
        if unplayable { unplayableIDs.insert(media.id) } else { unplayableIDs.remove(media.id) }
        UserDefaults.standard.set(Array(unplayableIDs), forKey: progressPrefix + "unplayable")
    }

    func persistPosition() {
        recordProgress(seconds)
        if let current { saveSession(current: current) }
    }

    // MARK: What played last

    private struct Session: Codable {
        var current: String
        var queue: [String]
        var original: [String]
        var queued: [String]
        var seconds: Double
    }

    private static func progressPrefix(_ address: String) -> String {
        "miniply.progress." + SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined() + "."
    }

    private func saveSession(current media: Media) {
        // Until a new song is under way, `seconds` still belongs to the previous one.
        let position = media.id == current?.id ? seconds : 0
        let session = Session(current: media.id, queue: queue.map(\.id), original: originalQueue.map(\.id),
                              queued: Array(queuedIDs), seconds: position)
        if let data = try? JSONEncoder().encode(session) { UserDefaults.standard.set(data, forKey: progressPrefix + "session") }
    }

    /// Back in the bar after the app was closed, paused, until play is pressed.
    func restoreSession(model: AppModel) {
        guard current == nil, let address = model.connection?.baseURL.absoluteString else { return }
        let prefix = Self.progressPrefix(address)
        guard let data = UserDefaults.standard.data(forKey: prefix + "session"),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              let media = model.mediaByID[session.current] else { return }
        self.model = model
        api = model.api
        progressPrefix = prefix
        let known = session.queue.compactMap { model.mediaByID[$0] }
        queue = known.contains { $0.id == media.id } ? known : [media]
        let original = session.original.compactMap { model.mediaByID[$0] }
        originalQueue = original.isEmpty ? queue : original
        index = queue.firstIndex { $0.id == media.id } ?? 0
        queuedIDs = Set(session.queued)
        tidyQueued()
        current = media
        seconds = session.seconds
        duration = media.duration ?? 0
    }

    /// A restored video has no player yet when its full-screen view opens.
    func startIfRestored() {
        if player.currentItem == nil && !preparing { resume() }
    }

    func toggle() { if wantsToPlay || isPlaying { pause() } else { resume() } }
    private func resume() {
        guard let current else { return }
        if isStreaming, StreamPolicy.blocks(kind: current.kind, on: network) {
            blockedByPolicy = true
            progressNotice = StreamPolicy.blockedMessage(kind: current.kind)
            return
        }
        if !preparing && (player.currentItem == nil || player.currentItem?.status == .failed) {
            if let model { play(current, in: queue, model: model, rearrange: false, startAt: seconds > 0 ? seconds : nil) }
            return
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            wantsToPlay = true
            if !preparing { player.play() }
        } catch { self.error = error.localizedDescription }
    }
    func pause() {
        cancelReconnect()
        stallWatch?.cancel()
        blockedByPolicy = false
        wantsToPlay = false
        buffering = false
        resumeAfterInterruption = false
        player.pause()
        recordProgress(seconds)
    }
    /// Holding back or forward jumps this far, in the app and on the lock screen.
    static let holdJump = 10.0

    /// Jump within the track; forward stops just before the end instead of skipping it.
    func jump(by delta: Double) {
        let end = duration > 0 ? max(0, duration - 0.5) : seconds + delta
        seek(min(seconds + delta, end))
    }

    func seek(_ time: Double) {
        // Restored, not started yet: play begins from here.
        if current != nil, player.currentItem == nil, !preparing, time.isFinite {
            seconds = min(max(0, time), duration > 0 ? duration : max(0, time))
            return
        }
        guard positionReady, time.isFinite else { return }
        let target = min(max(0, time), duration > 0 ? duration : max(0, time))
        seeking = true
        let expected = generation
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == expected else { return }
                self.seeking = false
            }
        }
        seconds = target
        if target > 3 { restartedTrack = false }
        recordProgress(target)
        updateNowPlaying()
    }
    /// True while a seek is in flight; the periodic tick must not overwrite
    /// `seconds` with the old position meanwhile.
    private var seeking = false
    /// Set by the first "back" press; a second press within the first
    /// seconds of the track goes to the previous track.
    private var restartedTrack = false
    private var loops: Bool { repeatMode == .all && current?.kind == "audio" && !queue.isEmpty }
    var hasNext: Bool { index + 1 < queue.count || loops }
    var upNext: [Media] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }
    func next() {
        guard let model else { pause(); return }
        if let track = prepared, player.currentItem !== track.item {
            track.item.audioMix = track.plainMix
            wantsToPlay = true
            player.advanceToNextItem()
            adoptPrepared(track)
            return
        }
        if index + 1 < queue.count { play(queue[index + 1], in: queue, model: model, rearrange: false) }
        else if loops { play(queue[0], in: queue, model: model, rearrange: false) }
        else { pause() }
    }
    func previous() {
        // First press: back to the start of this track. Second press (still
        // at the start): previous track.
        if !restartedTrack || seconds > 3 {
            seek(0)
            restartedTrack = true
            return
        }
        restartedTrack = false
        guard let model else { seek(0); return }
        if index > 0 { play(queue[index - 1], in: queue, model: model, rearrange: false) }
        else if loops, let last = queue.last { play(last, in: queue, model: model, rearrange: false) }
        else { seek(0) }
    }
    /// What a sideways swipe would play; repeat all wraps around.
    var followingItem: Media? {
        let item = index + 1 < queue.count ? queue[index + 1] : (loops ? queue.first : nil)
        return item?.id == current?.id ? nil : item
    }
    var previousItem: Media? {
        let item = index > 0 ? queue[index - 1] : (loops ? queue.last : nil)
        return item?.id == current?.id ? nil : item
    }
    /// Unlike `previous()`, which first goes back to the start of this song.
    func skipToPrevious() {
        guard let model, let item = previousItem else { return }
        restartedTrack = false
        play(item, in: queue, model: model, rearrange: false)
    }
    /// Next entry after the current one, if any (for "Nächste Folge").
    var nextItem: Media? { index + 1 < queue.count ? queue[index + 1] : nil }

    /// After the last episode of a season: the first episode of the next season
    /// of the same series, with that season as the queue.
    var nextSeason: (first: Media, episodes: [Media])? {
        guard nextItem == nil, let current, current.kind == "video", let model else { return nil }
        for group in model.seriesGroups {
            guard let index = group.seasons.firstIndex(where: { $0.episodes.contains { $0.id == current.id } }) else { continue }
            guard index + 1 < group.seasons.count, let first = group.seasons[index + 1].episodes.first else { return nil }
            return (first, group.seasons[index + 1].episodes)
        }
        return nil
    }

    func startNextSeason() {
        guard let season = nextSeason, let model else { return }
        play(season.first, in: season.episodes, model: model)
    }

    /// First in the queue, or start it if nothing plays.
    func playNext(_ media: Media, model: AppModel) {
        guard current != nil, !queue.isEmpty else { play(media, in: [media], model: model); return }
        guard media.id != current?.id else { confirm(String(localized: "„\(media.title)“ läuft gerade")); return }
        enqueue(media, at: nil)
        confirm(String(localized: "„\(media.title)“ kommt als Nächstes"))
    }
    /// Last in the queue, before the songs that would follow anyway, or start it if nothing plays.
    func addToQueue(_ media: Media, model: AppModel) {
        guard current != nil, !queue.isEmpty else { play(media, in: [media], model: model); return }
        guard media.id != current?.id else { confirm(String(localized: "„\(media.title)“ läuft gerade")); return }
        guard !queuedIDs.contains(media.id) else {
            confirm(String(localized: "„\(media.title)“ ist schon in der Warteschlange"))
            return
        }
        let lastQueued = upNext.lastIndex { queuedIDs.contains($0.id) }.map { upNext[$0] }
        enqueue(media, at: lastQueued)
        confirm(String(localized: "„\(media.title)“ in der Warteschlange"))
    }

    /// A song plays once: one that was going to come anyway moves up.
    private func enqueue(_ media: Media, at previous: Media?) {
        queue.removeAll { $0.id == media.id }
        index = queue.firstIndex(where: { $0.id == current?.id }) ?? index
        let before = previous.flatMap { entry in queue.firstIndex { $0.id == entry.id } } ?? index
        queue.insert(media, at: min(before + 1, queue.count))
        queuedIDs.insert(media.id)
        if !originalQueue.contains(where: { $0.id == media.id }) { originalQueue.append(media) }
        syncPreload()
        saveQueue()
    }

    /// The queue survives iOS closing the app in the background, not only a new song.
    private func saveQueue() {
        if let current { saveSession(current: current) }
    }

    private func tidyQueued() {
        guard !queuedIDs.isEmpty else { return }
        queuedIDs.formIntersection(upNext.map(\.id))
    }

    private static func placing(_ waiting: [Media], after media: Media, in order: [Media]) -> [Media] {
        guard !waiting.isEmpty else { return order }
        let ids = Set(waiting.map(\.id))
        var list = order.filter { !ids.contains($0.id) }
        let position = list.firstIndex { $0.id == media.id }.map { $0 + 1 } ?? 0
        list.insert(contentsOf: waiting, at: position)
        return list
    }

    /// These files no longer exist on the server.
    func forget(_ ids: Set<String>) {
        if let current, ids.contains(current.id) { stop(); return }
        guard !queue.isEmpty else { return }
        queue.removeAll { ids.contains($0.id) }
        originalQueue.removeAll { ids.contains($0.id) }
        if let current { index = queue.firstIndex { $0.id == current.id } ?? 0 }
        tidyQueued()
        syncPreload()
    }

    /// Short confirmation above the mini player.
    func confirm(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
    /// Offsets are relative to `upNext`.
    func removeUpcoming(at offsets: IndexSet) {
        let absolute = IndexSet(offsets.map { $0 + index + 1 }.filter { $0 < queue.count })
        queue.remove(atOffsets: absolute)
        originalQueue = queue
        tidyQueued()
        syncPreload()
        saveQueue()
    }
    func removeUpcoming(_ media: Media) {
        guard let offset = upNext.firstIndex(where: { $0.id == media.id }) else { return }
        removeUpcoming(at: IndexSet(integer: offset))
    }
    func moveUpcoming(from source: IndexSet, to destination: Int) {
        var upcoming = upNext
        upcoming.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue.prefix(index + 1)) + upcoming
        originalQueue = queue
        syncPreload()
        saveQueue()
    }
    func clearUpcoming() {
        queue = Array(queue.prefix(index + 1))
        originalQueue = queue
        queuedIDs = []
        syncPreload()
        saveQueue()
    }

    /// Jump to an entry of the current queue ("Als Nächstes").
    func jump(to media: Media) {
        guard let model, queue.contains(where: { $0.id == media.id }) else { return }
        play(media, in: queue, model: model, rearrange: false)
    }
    func setShuffle(_ enabled: Bool) {
        shuffle = enabled
        UserDefaults.standard.set(enabled, forKey: "mediaserver.shuffle")
        if let current, current.kind == "audio", !originalQueue.isEmpty {
            let waiting = upNext.filter { queuedIDs.contains($0.id) }
            queue = Self.placing(waiting, after: current, in: enabled ? Self.shuffled(originalQueue, first: current) : originalQueue)
            index = queue.firstIndex(where: { $0.id == current.id }) ?? 0
        }
        syncPreload()
        saveQueue()
        updateNowPlaying()
    }
    func toggleShuffle() { setShuffle(!shuffle) }
    func setRepeat(_ mode: RepeatMode) {
        repeatMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "mediaserver.repeat")
        syncPreload()
        updateNowPlaying()
    }
    func cycleRepeat() { setRepeat(repeatMode.next) }
    /// What was set for this album or playlist, if anything, applies whenever it starts.
    func applySettings(ofCollection id: String) {
        guard let settings = CollectionPlayback.load(id) else { return }
        setShuffle(settings.shuffle)
        setRepeat(settings.repeatMode)
    }
    /// Play a list in random order, e.g. "Zufallswiedergabe" on an album.
    func playShuffled(_ tracks: [Media], model: AppModel) {
        guard let first = tracks.randomElement() else { return }
        setShuffle(true)
        play(first, in: tracks, model: model)
    }
    /// Lock screen and Control Center artwork; set by the views once loaded.
    func setArtwork(_ image: UIImage?, id: String?) {
        if let image, let id { artwork = (id, current?.kind == "audio" ? image.squared : image) } else { artwork = nil }
        updateNowPlaying()
    }
    /// Subtitle the user picked for this video, or the one matching the
    /// preferred language from the settings ("off", "auto" or a code).
    func preferredSubtitle(for media: Media) -> SubtitleRef? {
        let tracks = media.subtitles ?? []
        if let choice = subtitleChoice[media.id] { return tracks.first { $0.id == choice } }
        let setting = UserDefaults.standard.string(forKey: "mediaserver.subtitles") ?? "off"
        switch setting {
        case "off": return nil
        case "auto": return tracks.first { !$0.forced } ?? tracks.first
        default: return tracks.first { $0.language == setting && !$0.forced } ?? tracks.first { $0.language == setting }
        }
    }

    /// Choose a subtitle (nil = off) for a video; reloads if it is playing.
    func chooseSubtitle(_ subtitle: SubtitleRef?, for media: Media) {
        subtitleChoice[media.id] = subtitle?.id ?? ""
        if current?.id == media.id { loadSubtitles(for: media) }
    }

    func subtitleText(at time: Double) -> String? {
        guard !subtitleCues.isEmpty else { return nil }
        var low = 0, high = subtitleCues.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if subtitleCues[mid].start <= time { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        guard let index = found else { return nil }
        // Overlapping cues: show every cue that is active right now.
        var lines: [String] = []
        var i = index
        while i >= 0 && index - i < 4 {
            let cue = subtitleCues[i]
            if cue.start <= time && time < cue.end { lines.insert(cue.text, at: 0) }
            i -= 1
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func loadSubtitles(for media: Media) {
        subtitleTask?.cancel()
        subtitleCues = []
        activeSubtitle = nil
        guard let subtitle = preferredSubtitle(for: media) else { return }
        activeSubtitle = subtitle
        let expected = generation
        let saved = model?.savedSubtitle(subtitle)
        let api = api
        subtitleTask = Task {
            let loaded: String?
            if let saved { loaded = saved } else { loaded = try? await api?.subtitles(subtitle) }
            guard let text = loaded else {
                if generation == expected { progressNotice = String(localized: "Untertitel konnten nicht geladen werden.") }
                return
            }
            let cues = await Task.detached(priority: .userInitiated) { parseWebVTT(text) }.value
            guard !Task.isCancelled, generation == expected, current?.id == media.id else { return }
            subtitleCues = cues
        }
    }

    // MARK: Sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepAtTrackEnd = false
        syncPreload()
        sleepDeadline = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
    }
    func sleepAtEndOfTrack() {
        sleepDeadline = nil
        sleepAtTrackEnd = true
        syncPreload()
    }
    var sleepActive: Bool { sleepDeadline != nil || sleepAtTrackEnd }

    // MARK: Transitions and volume levelling

    /// The next song is the following track of the same album, so the two belong together
    /// (as on "Views", where songs run into each other).
    static func continuesAlbum(_ first: Media?, _ second: Media?) -> Bool {
        guard let first, let second, first.kind == "audio", second.kind == "audio",
              let album = first.albumKey, album == second.albumKey,
              let one = first.trackNumber, let two = second.trackNumber else { return false }
        let discOne = first.discNumber ?? 1, discTwo = second.discNumber ?? 1
        return (discOne == discTwo && two == one + 1) || (discTwo == discOne + 1 && two == 1)
    }

    /// Fade-in/out (seconds from the settings, default off) and ReplayGain
    /// levelling as one audio mix. Nil when neither applies.
    private static func audioMix(for asset: AVURLAsset, media: Media, duration: Double, fadeIn: Bool, fadeOut: Bool = true) async -> AVAudioMix? {
        let defaults = UserDefaults.standard
        let fade = defaults.object(forKey: "mediaserver.fade") as? Double ?? 0
        let normalize = defaults.object(forKey: "mediaserver.normalize") as? Bool ?? true
        var level: Float = 1
        if normalize, let gain = media.gainDb, gain.isFinite {
            // Typical ReplayGain values are around -6 dB for modern masters;
            // quieter tracks are never amplified above full volume.
            level = Float(min(1, max(0.1, pow(10, (gain + 6) / 20))))
        }
        let fades = fade > 0 && duration > fade * 3
        guard fades || level < 1 else { return nil }
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(level, at: .zero)
        if fades {
            let length = CMTime(seconds: fade, preferredTimescale: 600)
            if fadeIn {
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: level, timeRange: CMTimeRange(start: .zero, duration: length))
            }
            if fadeOut {
                let start = CMTime(seconds: duration - fade, preferredTimescale: 600)
                parameters.setVolumeRamp(fromStartVolume: level, toEndVolume: 0, timeRange: CMTimeRange(start: start, duration: length))
            }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    private static func shuffled(_ list: [Media], first: Media) -> [Media] {
        [first] + list.filter { $0.id != first.id }.shuffled()
    }
    func stop() {
        pause(); preparation?.cancel(); preparation = nil
        generation = UUID(); status = nil; isStreaming = false
        dropPreload(); preloadFailedID = nil
        activeItem = nil
        player.removeAllItems()
        subtitleTask?.cancel(); subtitleCues = []; activeSubtitle = nil
        sleepDeadline = nil; sleepAtTrackEnd = false; fadeInNext = false
        UserDefaults.standard.removeObject(forKey: progressPrefix + "session")
        current = nil; queue = []; originalQueue = []; queuedIDs = []; artwork = nil; seconds = 0; duration = 0; preparing = false; phase = nil; positionReady = false
        isPlaying = false; buffering = false
        api = nil; progressNotice = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func finished() {
        guard positionReady else { return }
        // A stream that lost its connection can report an end it never loaded.
        // Taking that at face value would rewind it and mark it as watched.
        if isStreaming, let current, duration > 0, loadedEnd < duration - max(3, duration * 0.02) {
            fail(URLError(.networkConnectionLost), media: current)
            return
        }
        if let track = prepared, !sleepAtTrackEnd, repeatMode != .one, preloadTarget?.id == track.media.id {
            adoptPrepared(track)
            return
        }
        dropPreload()
        if let current, current.kind == "video" { personal?.setWatched(current, true) }
        if sleepAtTrackEnd {
            sleepAtTrackEnd = false
            wantsToPlay = false
            player.pause()
            recordProgress(0)
            updateNowPlaying()
            return
        }
        fadeInNext = current?.kind == "audio"
        seconds = 0
        recordProgress(0)
        if repeatMode == .one, current?.kind == "audio" {
            fadeInNext = false
            let expected = generation
            Task {
                await player.seek(to: .zero)
                guard generation == expected else { return }
                if wantsToPlay { player.play() }
                updateNowPlaying()
            }
        } else if index + 1 < queue.count, let model {
            play(queue[index + 1], in: queue, model: model, rearrange: false)
        } else if loops, let model {
            play(queue[0], in: queue, model: model, rearrange: false)
        } else {
            wantsToPlay = false
            player.pause()
            positionReady = false
            let expected = generation
            Task {
                await player.seek(to: .zero)
                guard generation == expected else { return }
                seconds = 0
                positionReady = true
                updateNowPlaying()
            }
        }
    }
    private func tick() {
        let time = player.currentTime().seconds
        guard current != nil, player.currentItem != nil, positionReady, !seeking, time.isFinite else { return }
        if detectPhantomPlayback(at: time) { return }
        seconds = max(0, time)
        if seconds > 5 { restartedTrack = false }
        if isPlaying, phantomStart == nil {
            reconnectStarted = nil; reconnectAttempt = 0
            if let current, !unplayableIDs.isEmpty { markUnplayable(current, false) }
        }
        if let deadline = sleepDeadline, Date() >= deadline {
            sleepDeadline = nil
            pause()
        }
        if let value = player.currentItem?.duration.seconds, value.isFinite { duration = value }
        if isPlaying && abs(seconds - lastSaved) >= 5 { recordProgress(seconds); lastSaved = seconds }
        if let current, current.kind == "video", duration > 0, seconds / duration >= 0.93 {
            personal?.setWatched(current, true)
        }
        syncPreload()
        // The lock screen advances the time by itself. Rebuilding the entry every second costs battery.
        let now = Date()
        let expected = lastNowPlayingSeconds + (isPlaying ? now.timeIntervalSince(lastNowPlayingUpdate) : 0)
        if abs(seconds - expected) > 1.5 || duration != lastNowPlayingDuration
            || now.timeIntervalSince(lastNowPlayingUpdate) >= 30 {
            updateNowPlaying()
        }
    }
    private func recordProgress(_ time: Double) {
        guard positionReady, player.currentItem?.status == .readyToPlay,
              let current, current.kind == "video", time.isFinite, time >= 0 else { return }
        let key = progressPrefix + current.id
        let at = Date().timeIntervalSince1970
        UserDefaults.standard.set(time, forKey: key)
        UserDefaults.standard.set(at, forKey: key + ".at")
        UserDefaults.standard.set(true, forKey: key + ".pending")
        pending[current.id] = (time, at)
        syncProgress()
    }

    /// Positions saved without a connection, also before the app was closed,
    /// go to the server as soon as it answers again.
    func sendSavedPositions(model: AppModel) {
        guard let address = model.connection?.baseURL.absoluteString, let api = model.api else { return }
        let prefix = Self.progressPrefix(address)
        if api !== self.api && current == nil { self.api = api }
        if prefix != progressPrefix && current == nil { progressPrefix = prefix; pending = [:] }
        guard prefix == progressPrefix else { return }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) && key.hasSuffix(".pending") {
            guard defaults.bool(forKey: key) else { continue }
            let id = String(key.dropFirst(prefix.count).dropLast(".pending".count))
            guard !id.isEmpty, pending[id] == nil else { continue }
            let at = defaults.double(forKey: prefix + id + ".at")
            pending[id] = (defaults.double(forKey: prefix + id), at > 0 ? at : Date().timeIntervalSince1970)
        }
        syncProgress()
    }

    private func syncProgress() {
        guard !syncing, let api, let (id, entry) = pending.first else { return }
        let prefix = progressPrefix
        syncing = true
        Task {
            do {
                try await api.send("/v1/progress/\(id)", method: "PUT",
                                   value: PlaybackProgress(seconds: entry.seconds, updatedAt: UInt64(entry.at)))
                if prefix == progressPrefix && pending[id]?.seconds == entry.seconds && pending[id]?.at == entry.at {
                    pending.removeValue(forKey: id)
                    UserDefaults.standard.set(false, forKey: prefix + id + ".pending")
                }
                if prefix == progressPrefix { progressNotice = nil }
                syncing = false
                syncProgress()
            } catch {
                if prefix == progressPrefix && current != nil {
                    progressNotice = String(localized: "Fortschritt lokal gesichert; Serversynchronisierung derzeit nicht möglich.")
                }
                syncing = false
            }
        }
    }
    private func updateNowPlaying() {
        guard let current else { return }
        lastNowPlayingSeconds = seconds; lastNowPlayingDuration = duration; lastNowPlayingUpdate = Date()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.series == nil ? current.title : current.episodeTitle,
            MPMediaItemPropertyArtist: current.artistCredit ?? current.artist ?? current.series ?? "Mediaserver",
            MPMediaItemPropertyAlbumTitle: current.album ?? current.seasonGroup.map(displayName) ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: seconds,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let image = artwork?.image {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let commands = MPRemoteCommandCenter.shared()
        commands.changeShuffleModeCommand.currentShuffleType = shuffle ? .items : .off
        commands.changeRepeatModeCommand.currentRepeatType = repeatMode == .one ? .one : repeatMode == .all ? .all : .off
    }
}
