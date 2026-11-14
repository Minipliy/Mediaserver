import SwiftUI

/// Shows whether the internet, the server or the SSD is the problem, and which
/// files this iPhone cannot play.
struct ConnectionStatusView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlayerModel
    @EnvironmentObject private var personal: Personal
    @ObservedObject private var connectivity = Connectivity.shared

    /// `preferredFilenameExtension` names one extension per type, so common
    /// alternatives of playable containers are added here.
    private static let playable = Set(PlayerModel.nativeFileExtensions.map { $0.lowercased() })
        .union(["aac", "aif", "aiff", "caf", "flac", "m4a", "m4v", "mov", "mp3", "mp4", "wav"])

    private var network: String {
        let state = connectivity.state
        guard state.online else { return String(localized: "Keine Verbindung") }
        let name = state.interface == "wifi" ? "WLAN" : state.interface == "cellular" ? String(localized: "Mobilfunk") : String(localized: "Verbunden")
        return state.constrained ? name + " · Datensparmodus" : name
    }

    private var syncLabel: String {
        switch personal.syncState {
        case .unknown: String(localized: "Noch nicht abgeglichen")
        case .synced: String(localized: "Abgeglichen")
        case .unsupported: String(localized: "Server zu alt")
        case .failed: String(localized: "Zuletzt fehlgeschlagen")
        }
    }

    private var failed: [Media] {
        playback.unplayableIDs.compactMap { model.mediaByID[$0] }.sorted { $0.title < $1.title }
    }

    private var unusualFormats: [Media] {
        model.items.filter { media in
            guard media.kind == "audio" || media.kind == "video", media.playback == nil,
                  !playback.unplayableIDs.contains(media.id) else { return false }
            return !Self.playable.contains((media.name as NSString).pathExtension.lowercased())
        }
    }

    var body: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.serverStatus.title).font(.headline)
                        Text(model.serverStatus.detail).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: model.serverStatus.symbol)
                        .foregroundStyle(model.serverStatus == .ok ? .mint : model.serverStatus == .unknown ? .secondary : .orange)
                }
                Button(String(localized: "Jetzt prüfen"), systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.loading)
            }
            ServerChainSections()
            Section(String(localized: "Verbindung")) {
                LabeledContent(String(localized: "Dieses iPhone").forThisDevice, value: network)
                LabeledContent(String(localized: "Server"), value: model.connection?.baseURL.host ?? "—")
                LabeledContent(String(localized: "Favoriten und Gesehen"), value: syncLabel)
                if let updated = model.lastRefresh {
                    LabeledContent(String(localized: "Zuletzt erreicht")) { Text(updated, style: .relative).foregroundStyle(.secondary) }
                }
            }
            if let storage = model.storage {
                Section("SSD am Server") {
                    LabeledContent("Dateien", value: "\(storage.fileCount)")
                    LabeledContent(String(localized: "Verfügbar"), value: byteLabel(storage.availableBytes))
                    if storage.scanErrors > 0 {
                        LabeledContent("Übersprungene Einträge", value: "\(storage.scanErrors)").foregroundStyle(.orange)
                    }
                }
            }
            if !failed.isEmpty {
                Section {
                    ForEach(failed) { media in row(media) }
                    Button(String(localized: "Liste leeren"), role: .destructive) { playback.clearUnplayable() }
                } header: { Text(String(localized: "Konnte nicht abgespielt werden")) } footer: {
                    Text(String(localized: "iOS hat diese Dateien abgelehnt. Erstelle eine kompatible Kopie: MP4 mit H.264 und AAC für Videos, M4A für Musik."))
                }
            }
            if !unusualFormats.isEmpty {
                Section {
                    ForEach(unusualFormats.prefix(50)) { media in row(media) }
                } header: { Text("Vermutlich nicht direkt abspielbar (\(unusualFormats.count))") } footer: {
                    Text(String(localized: "iOS kennt das Dateiformat dieser Dateien nicht, und auf dem Server gibt es keine vorbereitete Kopie."))
                }
            }
        }
        .miniPlayerRoom()
        .navigationTitle(String(localized: "Verbindungsstatus"))
        .refreshable { await model.refresh() }
    }

    private func row(_ media: Media) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(media.title).lineLimit(1)
            Text(media.formatLabel).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Each link between iPhone and SSD on its own, so an outage shows where it is:
/// internet of this iPhone, the forwarding server (VPS), the tunnel to the Pi, the Pi itself.
struct ServerChainSections: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var connectivity = Connectivity.shared
    @State private var forwarding: Step = .checking
    @State private var pi: Step = .checking
    @State private var info: ServerStatusInfo?
    @State private var checked: Date?

    enum Step: Equatable {
        case checking, ok, failed(String), unknown
        var symbol: String {
            switch self {
            case .checking: "ellipsis.circle"
            case .ok: "checkmark.circle.fill"
            case .failed: "xmark.octagon.fill"
            case .unknown: "questionmark.circle"
            }
        }
        var color: Color {
            switch self {
            case .ok: .mint
            case .failed: .orange
            default: .secondary
            }
        }
    }

    var body: some View {
        Section {
            row(String(localized: "Internet dieses iPhones").forThisDevice, connectivity.state.online ? .ok : .failed(String(localized: "Keine Verbindung")))
            row(String(localized: "Weiterleitung (VPS)"), forwarding)
            row(String(localized: "Tunnel und Raspberry Pi"), pi)
            if let info {
                row(String(localized: "Musik-Dienst"), info.musicServiceSecondsAgo.map { $0 < 120 ? .ok : .failed(String(localized: "antwortet nicht")) } ?? .unknown)
            }
            Button(String(localized: "Erneut prüfen"), systemImage: "arrow.clockwise") { Task { await check() } }
        } header: { Text(String(localized: "Verbindungskette")) } footer: {
            if let checked { Text(String(localized: "Geprüft ")) + Text(checked, style: .relative) }
        }
        .task { await check() }
        if let info {
            Section(String(localized: "Raspberry Pi")) {
                if let total = info.diskTotalBytes, let free = info.diskAvailableBytes, total > 0 {
                    LabeledContent(String(localized: "SSD belegt"), value: "\(Int((Double(total - min(free, total)) / Double(total) * 100).rounded())) % · \(byteLabel(free)) frei")
                }
                if let total = info.memoryTotalBytes, let free = info.memoryAvailableBytes {
                    LabeledContent(String(localized: "Arbeitsspeicher frei"), value: "\(byteLabel(free)) von \(byteLabel(total))")
                }
                if let temperature = info.temperatureC {
                    LabeledContent(String(localized: "Temperatur"), value: String(format: "%.0f °C", temperature))
                }
                if let uptime = info.uptimeSeconds {
                    LabeledContent(String(localized: "Läuft seit"), value: Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2)))
                }
                if let songs = info.songs, songs > 0 {
                    LabeledContent(String(localized: "Lautstärke gemessen"), value: "\(info.songsLevelled ?? 0) von \(songs) Songs")
                }
                if let seasons = info.seasonsWithIntro, seasons > 0 {
                    LabeledContent(String(localized: "Intro erkannt"), value: String(localized: "\(seasons) Staffeln"))
                }
                if let catalog = info.musicCatalog, catalog.artistsListed > 0 {
                    LabeledContent(String(localized: "Musik-Katalog"),
                                   value: String(localized: "\(catalog.artistsReady) von \(catalog.artistsListed) Künstlern · \(byteLabel(catalog.bytes))"))
                }
            }
        }
    }

    private func row(_ title: String, _ step: Step) -> some View {
        HStack {
            Image(systemName: step.symbol).foregroundStyle(step.color)
            Text(title)
            Spacer()
            if case .failed(let reason) = step { Text(reason).font(.caption).foregroundStyle(.secondary) }
            if step == .checking { ProgressView() }
        }
    }

    /// `/healthz` needs no token and is answered by the Pi through the VPS: an error from the
    /// VPS (502–504) means the VPS runs but the tunnel or the Pi does not.
    private func check() async {
        forwarding = .checking; pi = .checking
        defer { checked = Date() }
        guard let base = model.connection?.baseURL else { forwarding = .unknown; pi = .unknown; return }
        var request = URLRequest(url: base.appendingPathComponent("healthz"), timeoutInterval: 8)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            forwarding = .ok
            switch code {
            case 200: pi = .ok
            case 502, 503, 504: pi = .failed(String(localized: "nicht erreichbar"))
            default: pi = .failed("HTTP \(code)")
            }
        } catch {
            forwarding = connectivity.state.online ? .failed(String(localized: "antwortet nicht")) : .unknown
            pi = .unknown
        }
        info = pi == .ok ? try? await model.api?.status() : nil
    }
}

struct StreamingSettingsSection: View {
    @AppStorage(StreamPolicy.cellularKey) private var cellular = "all"
    @AppStorage(StreamPolicy.wifiBufferKey) private var wifiBuffer = "auto"
    @AppStorage(StreamPolicy.cellularBufferKey) private var cellularBuffer = "auto"
    @AppStorage(StreamPolicy.wifiQualityKey) private var wifiQuality = "auto"
    @AppStorage(StreamPolicy.cellularQualityKey) private var cellularQuality = "auto"

    var body: some View {
        Section {
            Picker(String(localized: "Streaming über Mobilfunk"), selection: $cellular) {
                Text(String(localized: "Musik und Videos")).tag("all")
                Text(String(localized: "Nur Musik")).tag("audio")
                Text(String(localized: "Aus")).tag("off")
            }
            bufferPicker(String(localized: "Puffer im WLAN"), selection: $wifiBuffer)
            bufferPicker(String(localized: "Puffer im Mobilfunk"), selection: $cellularBuffer)
            qualityPicker(String(localized: "Videoqualität im WLAN"), selection: $wifiQuality)
            qualityPicker(String(localized: "Videoqualität im Mobilfunk"), selection: $cellularQuality)
        } header: { Text(String(localized: "Streaming")) } footer: {
            Text(String(localized: "„Stabil“ lädt mehr im Voraus und stockt seltener. „Datensparend“ lädt nur wenige Sekunden voraus und verbraucht weniger Daten, wenn du früh abbrichst. Im Datensparmodus von iOS gilt immer „Datensparend“ und niedrige Videoqualität. Die Videoqualität wirkt bei Videos, für die der Server eine HLS-Kopie vorbereitet hat; alle anderen spielen in ihrer Originalqualität."))
        }
    }

    private func qualityPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text(String(localized: "Automatisch")).tag("auto")
            Text(String(localized: "Original (unverändert)")).tag("original")
            Text(String(localized: "Mittel (bis 3 Mbit/s)")).tag("medium")
            Text(String(localized: "Niedrig (bis 1,5 Mbit/s)")).tag("low")
        }
    }

    private func bufferPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text(String(localized: "Automatisch")).tag("auto")
            Text(String(localized: "Datensparend")).tag("saver")
            Text(String(localized: "Stabil")).tag("stable")
        }
    }
}
