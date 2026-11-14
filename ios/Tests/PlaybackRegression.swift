// Standalone simulator harness, built by scripts/check-ios-playback.sh.
// AppModel is deliberately a local-only fixture. No server or user library is accessed.
import SwiftUI
import AVFoundation
import CryptoKit

/// Stands in for the server during reconnect checks; no network is used.
final class FakeServer: URLProtocol {
    nonisolated(unsafe) static var failure: Error = URLError(.notConnectedToInternet)
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        client?.urlProtocol(self, didFailWithError: Self.failure)
    }
    override func stopLoading() {}
}

extension UIImage {
    var squared: UIImage { self }
}

@MainActor
final class AppModel {
    var connection: Connection? = Connection(baseURL: URL(string: "https://playback-\(UUID().uuidString.lowercased()).invalid")!, token: UUID().uuidString)
    var api: API? = nil
    var brokenIDs: Set<String> = []
    var fixtures: [String: String] = [:]
    var streamOnly: Set<String> = []
    var mediaByID: [String: Media] = [:]
    func savedSubtitle(_ subtitle: SubtitleRef) -> String? { nil }
    var downloadScope: String { connection?.baseURL.host ?? "" }
    func localURL(_ media: Media) -> URL? {
        if streamOnly.contains(media.id) { return nil }
        let file = fixtures[media.id] ?? (brokenIDs.contains(media.id) ? "unplayable.wav" : "sample.wav")
        return Bundle.main.url(forResource: file, withExtension: nil)
    }
}

@main
struct PlaybackTestApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Playback regression checks").task { await runChecks() }
        }
    }

    @MainActor
    func runChecks() async {
        let model = AppModel()
        let player = PlayerModel()
        let address = model.connection!.baseURL.absoluteString
        let prefix = "miniply.progress." + SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined() + "."
        func media(_ name: String, suffix: String = "wav", kind: String = "audio") -> Media {
            let id = SHA256.hash(data: Data((name + "." + suffix).utf8)).map { String(format: "%02x", $0) }.joined()
            return Media(id: id, path: name + "." + suffix, name: name + "." + suffix, kind: kind, title: name, artist: nil, album: nil, duration: nil, bytes: 88244, modified: 1)
        }
        let a = media("a"), b = media("b"), broken = media("broken")
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        var results: [String] = []
        func expect(_ condition: Bool, _ name: String) { results.append((condition ? "PASS " : "FAIL ") + name) }
        func waitReady() async {
            for _ in 0..<150 {
                if !player.preparing { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        UserDefaults.standard.set(0.5, forKey: prefix + a.id)
        player.play(a, model: model)
        player.toggle()
        expect(UserDefaults.standard.double(forKey: prefix + a.id) == 0.5, "Pause while preparing preserves saved resume position")
        await waitReady()
        try? await Task.sleep(for: .milliseconds(300))
        expect(player.error == nil && !player.preparing, "Local playback preparation succeeds")
        expect(player.player.rate == 0 && !player.isPlaying, "Pause while preparing prevents delayed autoplay")
        expect(player.seconds < 0.1, "Songs start from the beginning instead of a saved position")
        player.stop()
        expect(!player.isPlaying && !player.buffering, "Stop immediately clears playing and buffering state")
        UserDefaults.standard.set(0.7, forKey: prefix + a.id)
        UserDefaults.standard.set(0.9, forKey: prefix + b.id)
        player.play(a, model: model)
        player.play(b, model: model)
        player.stop()
        try? await Task.sleep(for: .milliseconds(300))
        expect(UserDefaults.standard.double(forKey: prefix + a.id) == 0.7, "Quick selection change preserves unstarted title position")
        expect(UserDefaults.standard.double(forKey: prefix + b.id) == 0.9, "Stop while preparing preserves unstarted title position")
        expect(player.current == nil && player.player.currentItem == nil && !player.preparing, "Cancelled preparation cannot restart stopped player")
        UserDefaults.standard.set(0, forKey: prefix + a.id)
        player.play(a, model: model)
        await waitReady()
        try? await Task.sleep(for: .seconds(3))
        expect(player.error == nil, "Local sample completes without playback error")
        expect(!player.isPlaying && player.seconds < 0.1 && player.player.currentTime().seconds < 0.1, "Last queue item rewinds after completion")
        player.persistPosition()
        expect(UserDefaults.standard.double(forKey: prefix + a.id) == 0, "Completed title stays reset when progress is persisted")
        player.stop()
        model.brokenIDs.insert(broken.id)
        UserDefaults.standard.set(0.4, forKey: prefix + broken.id)
        player.play(broken, model: model)
        await waitReady()
        player.pause()
        expect(player.error != nil, "Unplayable local file reports an error")
        expect(UserDefaults.standard.double(forKey: prefix + broken.id) == 0.4, "Playback failure preserves existing resume position")
        player.stop()
        expect(player.player.currentItem == nil && player.error?.contains("kompatible Kopie") == true,
               "Unrecognized source fails preflight with conversion guidance")
        var preparedBroken = broken
        preparedBroken.playback = PlaybackVariant(fileExtension: "m4a", bytes: 1234)
        player.play(preparedBroken, model: model)
        await waitReady()
        expect(player.error?.contains("gespeicherte Originaldatei") == true && player.error?.contains("erneut herunterladen") == true && player.player.currentItem == nil,
               "Incompatible offline original suggests replacing only the local copy without online fallback")
        player.stop()
        expect(PlayerModel.nativeFileExtensions.contains("MOV"), "Runtime container list includes QuickTime movies")
        for (file, suffix, kind) in [
            ("sample.aiff", "aiff", "audio"), ("sample.caf", "caf", "audio"),
            ("aac.m4a", "m4a", "audio"), ("alac.m4a", "m4a", "audio"),
            ("sample.flac", "flac", "audio"), ("sample.mov", "mov", "video"),
            ("sample.mp4", "mp4", "video")
        ] {
            let fixture = media(file, suffix: suffix, kind: kind)
            model.fixtures[fixture.id] = file
            player.play(fixture, model: model)
            await waitReady()
            for _ in 0..<100 {
                if player.player.currentTime().seconds > 0 || player.error != nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let advanced = player.player.currentTime().seconds > 0
            player.pause()
            expect(player.error == nil && player.player.currentItem?.status == .readyToPlay && advanced,
                   "Native " + file + " passes asset and track inspection and decodes"
                   + " [error: \(player.error ?? "none"), status: \(player.player.currentItem?.status.rawValue ?? -1), time: \(player.player.currentTime().seconds), intends: \(player.intendsToPlay)]")
            expect(player.duration > 0, "Native " + file + " loads duration without server metadata")
            player.stop()
        }
        let audioOnlyVideo = media("audio-only", suffix: "mov", kind: "video")
        model.fixtures[audioOnlyVideo.id] = "aac.m4a"
        player.play(audioOnlyVideo, model: model)
        await waitReady()
        expect(player.error?.contains("kompatible Kopie") == true && player.player.currentItem == nil,
               "Video source with only playable audio is rejected before black-screen playback")
        player.stop()
        let original = media("source", suffix: "mov", kind: "video")
        var prepared = original
        prepared.playback = PlaybackVariant(fileExtension: "mp4", bytes: 1234)
        let projection = prepared.downloadMedia
        expect(projection.id == original.id && projection.path == original.path && projection.name == "source.mp4" && projection.bytes == 1234 && projection.playback == nil,
               "Prepared download projects correct filename and size while preserving identity")
        expect(prepared.formatLabel == "MOV · optimierte MP4-Kopie", "Format label identifies source container and prepared copy")
        let json = try! JSONSerialization.data(withJSONObject: [
            "id": original.id, "path": original.path, "name": original.name, "kind": original.kind,
            "title": original.title, "bytes": original.bytes, "modified": original.modified,
            "playback": ["file_extension": "mp4", "bytes": 1234]
        ])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try? decoder.decode(Media.self, from: json)
        expect(decoded?.playback?.fileExtension == "mp4" && decoded?.downloadMedia.bytes == 1234,
               "Backend snake_case playback metadata decodes into prepared download")
        let cache = try? JSONEncoder().encode(prepared)
        let restored = cache.flatMap { try? JSONDecoder().decode(Media.self, from: $0) }
        expect(restored?.playback == prepared.playback, "Prepared metadata survives local library cache round-trip")
        let legacyData = try! JSONEncoder().encode(original)
        let legacy = try? JSONDecoder().decode(Media.self, from: legacyData)
        expect(legacy?.id == original.id && legacy?.playback == nil, "Legacy media without prepared metadata remains decodable")
        let networkFailure = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue,
                                     userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet)])
        expect(PlayerModel.playbackErrorMessage(networkFailure, media: original).contains("Internetverbindung"),
               "Nested network failure is distinguished from unsupported codecs")
        expect(PlayerModel.playbackErrorMessage(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decoderNotFound.rawValue), media: original).contains("MP4 mit H.264 und AAC"),
               "Decoder failure suggests a compatible video copy")
        for (file, sourceSuffix, kind, targetSuffix) in [
            ("prepared-video.mp4", "mkv", "video", "mp4"),
            ("prepared-audio.m4a", "ogg", "audio", "m4a")
        ] where Bundle.main.url(forResource: file, withExtension: nil) != nil {
            var source = media(file, suffix: sourceSuffix, kind: kind)
            source.playback = PlaybackVariant(fileExtension: targetSuffix, bytes: 1234)
            model.fixtures[source.id] = file
            player.play(source, model: model)
            await waitReady()
            for _ in 0..<100 {
                if player.player.currentTime().seconds > 0 || player.error != nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let advanced = player.player.currentTime().seconds > 0
            player.pause()
            expect(player.error == nil && player.player.currentItem?.status == .readyToPlay && advanced,
                   "External " + file + " plays despite incompatible source extension")
            player.stop()
        }
        // Shared favourites and statistics, without a server.
        let suite = "personal-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let idA = String(repeating: "a", count: 64), idB = String(repeating: "b", count: 64)
        func item(_ id: String) -> Media {
            Media(id: id, path: id + ".mp3", name: id + ".mp3", kind: "audio", title: id, artist: nil, album: nil, duration: nil, bytes: 1, modified: 1)
        }
        do {
            let viewer = Personal(defaults: store, key: "continue")
            func episode(_ number: Int) -> Media {
                Media(id: String(format: "%064d", number), path: "Serien/Show/S01E\(number).mp4", name: "e\(number).mp4", kind: "video", title: "E\(number)",
                      artist: nil, album: nil, duration: 1000, bytes: 1, modified: 1, seriesKey: "Serien/Show", seasonFolder: "Season 1", season: 1, episode: number)
            }
            let episodes = (1...20).map(episode)
            let show = SeriesGroup(id: "Serien/Show", name: "Show", seasons: [Season(id: "s1", title: "Season 1", number: 1, episodes: episodes)], coverId: nil)
            func played(_ number: Int, at time: Double) {
                viewer.apply(PersonalSyncResponse(favorites: [], watched: [], plays: [], lastPlayed: [PersonalLastPlayed(id: episode(number).id, at: time)]), sentPlays: [:])
            }
            var positions: [String: Double] = [:]
            let resume: (Media) -> Double = { positions[$0.id] ?? 0 }
            expect(viewer.continueEpisode(in: show, resume: resume)?.1.episode == 1, "A new series starts with its first episode")
            played(1, at: 10); played(18, at: 20)
            positions[episode(1).id] = 120; positions[episode(18).id] = 300
            expect(viewer.continueEpisode(in: show, resume: resume)?.1.episode == 18, "Go on with the last episode played, not one only looked into")
            positions[episode(18).id] = 950
            expect(viewer.continueEpisode(in: show, resume: resume)?.1.episode == 19, "After a finished episode comes the next")
            viewer.setWatched(episodes, true)
            expect(viewer.continueEpisode(in: show, resume: resume) == nil, "A series seen to the end has nothing to go on with")
            let list = Dictionary(uniqueKeysWithValues: episodes.map { ($0.id, $0) })
            expect(viewer.continueWatching(in: list, series: [show], resume: resume, limit: 4).isEmpty, "Finished series stay off the start screen")
            viewer.setWatched(episodes, false)
            expect(viewer.continueWatching(in: list, series: [show], resume: resume, limit: 4).map(\.episode) == [19], "A series counts once")
        }
        expect(CollectionPlayback.load("album", from: store) == nil, "An album without settings changes nothing")
        var albumSettings = CollectionPlayback()
        albumSettings.shuffle = true; albumSettings.repeatMode = .all
        albumSettings.save("album", to: store)
        expect(CollectionPlayback.load("album", from: store) == albumSettings && CollectionPlayback.load("other", from: store) == nil,
               "Shuffle and repeat stay set for that album only")
        let older = PersonalFlag(id: idA, on: true, at: 10), newer = PersonalFlag(id: idA, on: false, at: 20)
        expect(older.merged(with: newer) == newer && newer.merged(with: older) == newer, "The latest change wins, also a removal")
        expect(PersonalFlag(id: idA, on: false, at: 5).merged(with: PersonalFlag(id: idA, on: true, at: 5)).on, "Without a time difference the mark stays")
        let oldSnapshot = #"{"favorites":["\#(idA)"],"playCounts":{"\#(idA)":4},"lastPlayed":{"\#(idA)":7},"watched":["\#(idB)"]}"#
        store.set(Data(oldSnapshot.utf8), forKey: "personal")
        let local = Personal(defaults: store, key: "personal")
        expect(local.favorites == [idA] && local.watched == [idB] && local.plays(item(idA)) == 4, "Data from before sharing stays")
        let device = local.device
        expect(Personal(defaults: store, key: "personal").device == device && !device.isEmpty, "The device keeps its identity")
        local.recordPlay(item(idA))
        local.apply(PersonalSyncResponse(favorites: [PersonalFlag(id: idA, on: false, at: 100), PersonalFlag(id: idB, on: true, at: 100)],
                                         watched: [], plays: [PersonalPlayCount(id: idA, count: 9)], lastPlayed: []),
                    sentPlays: [idA: 4])
        expect(local.favorites == [idB], "Another device's changes arrive")
        expect(local.plays(item(idA)) == 10, "A play during the request still counts")
        expect(local.watched == [idB], "Marks the server does not know stay")
        let restarted = Personal(defaults: store, key: "personal")
        expect(restarted.favorites == [idB] && restarted.plays(item(idA)) == 10, "Merged state survives a restart")
        local.toggleFavorite(item(idA))
        local.apply(PersonalSyncResponse(favorites: [PersonalFlag(id: idA, on: false, at: 100)], watched: [], plays: [], lastPlayed: []), sentPlays: [:])
        expect(local.favorites.contains(idA), "A change newer than the server's answer stays")
        expect(local.pendingChanges > 0, "Unconfirmed changes stay marked for the next sync")

        // Next song. The sample lasts two seconds, so it is always near its end.
        func waitOn(_ condition: () -> Bool) async {
            for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
        }
        let first = media("queue-a"), second = media("queue-b"), third = media("queue-c")
        let listening = [first, second, third]
        UserDefaults.standard.set(0.0, forKey: "mediaserver.fade")
        player.play(first, in: listening, model: model)
        await waitOn { player.preloadedID == second.id }
        expect(player.preloadedID == second.id, "Next song is prepared near the end of the current one")
        expect(player.player.items().count == 2, "Prepared song is queued behind the current one")
        let queuedItem = player.player.items().last
        await waitOn { player.current?.id == second.id }
        expect(player.current?.id == second.id && !player.preparing && player.player.currentItem === queuedItem,
               "Queued song takes over without rebuilding the player")
        expect(player.error == nil && player.intendsToPlay, "Takeover keeps playing")
        await waitOn { player.player.currentTime().seconds > 0.1 }
        expect(player.isPlaying && player.seconds < 1.5, "Taken over song plays from its start")
        await waitOn { player.preloadedID == third.id }
        player.removeUpcoming(at: IndexSet(integer: 0))
        expect(player.preloadedID == nil && player.player.items().count == 1, "Removing the next song drops it from the player")
        expect(player.current?.id == second.id, "Dropping a queued song keeps the current one")
        player.stop()

        player.play(first, in: listening, model: model)
        await waitOn { player.preloadedID == second.id }
        player.next()
        expect(player.current?.id == second.id && !player.preparing && player.intendsToPlay, "Skipping uses the prepared song at once")
        player.stop()
        expect(player.player.items().isEmpty && player.preloadedID == nil, "Stop clears the queued song")

        player.play(first, in: listening, model: model)
        await waitOn { player.preloadedID == second.id }
        player.setRepeat(.one)
        expect(player.preloadedID == nil && player.player.items().count == 1, "Repeat one drops the queued song")
        try? await Task.sleep(for: .seconds(2.5))
        expect(player.current?.id == first.id && player.error == nil, "Repeat one stays on the same song")
        player.setRepeat(.off)
        player.stop()

        player.play(first, in: listening, model: model)
        await waitOn { player.preloadedID == second.id }
        player.sleepAtEndOfTrack()
        expect(player.preloadedID == nil, "Sleep at end of song drops the queued song")
        await waitOn { !player.intendsToPlay }
        expect(player.current?.id == first.id && !player.isPlaying, "Sleep at end of song stops instead of advancing")
        player.stop()

        player.preloadLead = 0
        player.play(first, in: [first, second], model: model)
        try? await Task.sleep(for: .milliseconds(600))
        expect(player.preloadedID == nil, "Nothing is prepared before the lead time")
        await waitOn { player.current?.id == second.id && !player.preparing }
        expect(player.current?.id == second.id && player.error == nil, "Regular start still advances without preparation")
        player.preloadLead = 30
        player.stop()
        UserDefaults.standard.removeObject(forKey: "mediaserver.fade")

        // Sideways swipe between songs.
        UserDefaults.standard.set(0.0, forKey: "mediaserver.fade")
        player.play(second, in: listening, model: model)
        await waitOn { !player.preparing }
        expect(player.previousItem?.id == first.id && player.followingItem?.id == third.id, "Neighbours of the active song are known")
        player.skipToPrevious()
        await waitOn { player.current?.id == first.id && !player.preparing }
        expect(player.current?.id == first.id && player.error == nil, "Swiping back plays the previous song at once")
        expect(player.previousItem == nil, "The first song has no previous one")
        player.setRepeat(.all)
        expect(player.previousItem?.id == third.id, "Repeat all wraps around at the start")
        player.setRepeat(.off)
        player.play(first, in: [first], model: model)
        await waitOn { !player.preparing }
        expect(player.followingItem == nil && player.previousItem == nil, "A single song has no neighbours")
        player.setRepeat(.all)
        expect(player.followingItem == nil, "Repeating a single song offers no preview of itself")
        player.setRepeat(.off)
        player.addToQueue(second, model: model)
        expect(player.toast?.contains(second.title) == true && player.upNext.map(\.id) == [second.id], "Adding to the queue confirms it")
        player.addToQueue(second, model: model)
        expect(player.upNext.count == 1 && player.toast?.contains("schon") == true, "A song already queued is not added twice, and says so")
        player.stop()
        let (queuedOne, queuedTwo) = (media("queued-one"), media("queued-two"))
        func coming() -> [String] { player.upNext.map(\.id) }
        player.play(first, in: [first, second, third], model: model)
        await waitOn { !player.preparing }
        player.addToQueue(queuedOne, model: model)
        expect(coming() == [queuedOne.id, second.id, third.id], "The queue comes before the songs that follow anyway")
        player.addToQueue(queuedTwo, model: model)
        expect(coming() == [queuedOne.id, queuedTwo.id, second.id, third.id], "A further song goes to the end of the queue")
        player.addToQueue(third, model: model)
        expect(coming() == [queuedOne.id, queuedTwo.id, third.id, second.id], "A song that would come anyway moves up into the queue")
        player.removeUpcoming(third)
        expect(coming() == [queuedOne.id, queuedTwo.id, second.id], "A song can be taken out of the list")
        player.removeUpcoming(second)
        player.addToQueue(second, model: model)
        expect(coming() == [queuedOne.id, queuedTwo.id, second.id], "Taken out songs can come back at the end of the queue")
        player.play(third, in: [first, third], model: model)
        expect(coming() == [queuedOne.id, queuedTwo.id, second.id], "The queue stays ahead when a new list starts")
        player.jump(to: queuedTwo)
        expect(coming() == [second.id], "Songs that were passed have left the queue")
        player.addToQueue(queuedOne, model: model)
        expect(coming() == [second.id, queuedOne.id], "A played song can be queued again")
        model.mediaByID = Dictionary(uniqueKeysWithValues: [first, second, third, queuedOne, queuedTwo].map { ($0.id, $0) })
        await waitOn { !player.preparing }
        player.seek(1)
        player.persistPosition()
        let reopened = PlayerModel()
        reopened.restoreSession(model: model)
        expect(reopened.current?.id == queuedTwo.id && reopened.upNext.map(\.id) == [second.id, queuedOne.id],
               "After closing the app the last song and what follows are back")
        expect(!reopened.isPlaying && !reopened.intendsToPlay && reopened.player.currentItem == nil, "It waits for play, without starting by itself")
        reopened.addToQueue(third, model: model)
        expect(reopened.upNext.map(\.id) == [second.id, queuedOne.id, third.id], "The queue still counts after a restart")
        reopened.toggle()
        await waitOn { reopened.isPlaying }
        expect(reopened.current?.id == queuedTwo.id && reopened.player.currentItem != nil, "Play continues the restored song")
        reopened.stop()
        let afterStop = PlayerModel()
        afterStop.restoreSession(model: model)
        expect(afterStop.current == nil, "A song that was stopped stays gone")
        player.stop()
        // Starting another album, as its "Abspielen" button does it.
        let (albumOne, albumTwo) = (media("album-one"), media("album-two"))
        player.play(first, in: [first, second], model: model)
        await waitOn { !player.preparing }
        player.addToQueue(queuedOne, model: model)
        let closedInBackground = PlayerModel()
        closedInBackground.restoreSession(model: model)
        expect(closedInBackground.upNext.map(\.id) == [queuedOne.id, second.id],
               "A queued song is back after iOS closed the app, without a new song in between")
        player.setShuffle(false)
        player.play(albumOne, in: [albumOne, albumTwo], model: model)
        await waitOn { !player.preparing }
        expect(coming() == [queuedOne.id, albumTwo.id], "A queued song stays when another album starts")
        player.setShuffle(true)
        player.play(albumTwo, in: [albumOne, albumTwo], model: model)
        await waitOn { !player.preparing }
        expect(coming().first == queuedOne.id, "A queued song stays when an album starts shuffled")
        player.setShuffle(false)
        player.stop()
        UserDefaults.standard.removeObject(forKey: "mediaserver.fade")

        // Lost connections. Requests fail through FakeServer until `streamOnly`
        // is cleared, which then stands for the server being back.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeServer.self]
        model.api = API(model.connection!, configuration: configuration)
        func waitFor(_ condition: () -> Bool) async {
            for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
        }
        let song = media("reconnect")
        model.fixtures[song.id] = "sample.wav"
        player.play(song, model: model)
        await waitReady()
        player.pause()
        player.seek(1)
        try? await Task.sleep(for: .milliseconds(200))
        player.toggle()
        model.streamOnly.insert(song.id)
        let liveItem = player.player.currentItem
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: liveItem,
                                        userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: URLError(.networkConnectionLost)])
        await waitFor { player.reconnecting }
        expect(player.reconnecting && player.error == nil && player.intendsToPlay, "Lost stream reconnects instead of showing an error")
        expect(abs(player.seconds - 1) < 0.5 && player.preparing, "Reconnect keeps the song position on screen")
        await waitFor { FakeServer.requests >= 1 }
        expect(FakeServer.requests >= 1, "Reconnect asks the server for a new ticket")
        expect(player.reconnecting && player.error == nil, "Failed retry keeps waiting")
        var wifi = NetworkState(); wifi.interface = "wifi"
        model.streamOnly.remove(song.id)
        player.networkChanged(wifi)
        await waitFor { !player.reconnecting }
        expect(!player.reconnecting && player.error == nil && player.player.currentItem != nil, "Returning network restores playback at once")
        expect(abs(player.player.currentTime().seconds - 1) < 0.5, "Restored song continues at its position")
        player.pause()
        player.stop()

        model.streamOnly.insert(song.id)
        player.play(song, model: model)
        await waitFor { player.reconnecting }
        let attempts = FakeServer.requests
        player.toggle()
        expect(!player.reconnecting && !player.preparing && player.error == nil, "Pause ends reconnecting without an error")
        try? await Task.sleep(for: .seconds(2.2))
        expect(FakeServer.requests == attempts, "No more retries after pause")
        player.stop()

        player.reconnectLimit = 0
        player.play(song, model: model)
        await waitFor { player.error != nil }
        expect(player.error?.contains("Internetverbindung") == true && !player.reconnecting && !player.intendsToPlay, "Reconnect gives up after its limit")
        player.stop(); player.error = nil
        player.reconnectLimit = ReconnectPolicy.limit

        FakeServer.failure = URLError(.badServerResponse)
        player.play(song, model: model)
        await waitFor { player.error != nil }
        expect(player.error != nil && !player.reconnecting, "Permanent failure does not retry")
        player.stop(); player.error = nil
        FakeServer.failure = URLError(.notConnectedToInternet)
        expect(PlayerModel.isTransientFailure(MiniplyError.server(503)) && !PlayerModel.isTransientFailure(MiniplyError.server(404))
               && !PlayerModel.isTransientFailure(MiniplyError.unauthorized), "Only gateway errors count as temporary server failures")
        expect(!PlayerModel.isTransientFailure(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decoderNotFound.rawValue)), "Codec failures never retry")
        expect(ReconnectPolicy.delay(attempt: 0) == 1 && ReconnectPolicy.delay(attempt: 3) == 8 && ReconnectPolicy.delay(attempt: 50) == 30, "Retry delay grows up to 30 seconds")

        // Streaming preferences.
        let settings = UserDefaults(suiteName: "playback-\(UUID().uuidString)")!
        var cellular = NetworkState(); cellular.expensive = true
        expect(StreamPolicy.forwardBuffer(cellular, defaults: settings) == StreamPolicy.mobileAutoSeconds && !StreamPolicy.blocks(kind: "video", on: cellular, defaults: settings), "Defaults keep streaming on mobile data, with half a minute loaded ahead")
        settings.set("stable", forKey: StreamPolicy.cellularBufferKey)
        expect(StreamPolicy.forwardBuffer(cellular, defaults: settings) == StreamPolicy.stableSeconds && StreamPolicy.forwardBuffer(wifi, defaults: settings) == 0, "Buffer setting applies per network")
        var lowData = cellular; lowData.constrained = true
        expect(StreamPolicy.forwardBuffer(lowData, defaults: settings) == StreamPolicy.saverSeconds, "Low Data Mode always saves data")
        expect(StreamPolicy.peakBitrate(wifi, defaults: settings) == 0, "Video quality is unlimited by default")
        settings.set("low", forKey: StreamPolicy.cellularQualityKey)
        settings.set("medium", forKey: StreamPolicy.wifiQualityKey)
        expect(StreamPolicy.peakBitrate(cellular, defaults: settings) == StreamPolicy.lowBitrate && StreamPolicy.peakBitrate(wifi, defaults: settings) == StreamPolicy.mediumBitrate, "Video quality applies per network")
        var lowDataWifi = wifi; lowDataWifi.constrained = true
        expect(StreamPolicy.peakBitrate(lowDataWifi, defaults: settings) == StreamPolicy.lowBitrate, "Low Data Mode always limits video quality")
        settings.set("audio", forKey: StreamPolicy.cellularKey)
        expect(StreamPolicy.blocks(kind: "video", on: cellular, defaults: settings) && !StreamPolicy.blocks(kind: "audio", on: cellular, defaults: settings) && !StreamPolicy.blocks(kind: "video", on: wifi, defaults: settings), "Music-only setting blocks video on mobile data only")
        settings.set("off", forKey: StreamPolicy.cellularKey)
        expect(StreamPolicy.blocks(kind: "audio", on: cellular, defaults: settings), "Off setting blocks all mobile streaming")

        // Failures remembered for the status screen.
        let refused = media("refused", suffix: "mov", kind: "video")
        model.fixtures[refused.id] = "aac.m4a"
        player.play(refused, model: model)
        await waitReady()
        expect(player.unplayableIDs.contains(refused.id), "Refused file is listed for the status screen")
        player.clearUnplayable(); player.stop(); player.error = nil
        expect(player.unplayableIDs.isEmpty, "Unplayable list can be cleared")
        let report = results.joined(separator: "\n") + "\n"
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("results.txt")
        try? report.write(to: destination, atomically: true, encoding: .utf8)
    }
}
