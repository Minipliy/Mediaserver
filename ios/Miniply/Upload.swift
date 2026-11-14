import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

/// One file on its way to the server. Saved so an upload survives a restart.
struct UploadRecord: Codable, Identifiable {
    /// Also the upload ID on the server.
    let id: String
    let scope: String
    /// Security-scoped bookmark of the picked file or folder.
    let bookmark: Data
    /// Path below the bookmark; empty when the file itself was picked.
    let relativePath: String
    let directory: String
    let name: String
    let bytes: Int64
    var offset: Int64 = 0
    /// Older server: the whole file in one request, without resuming.
    var legacy = false
}

struct UploadTaskInfo: Codable {
    let id: String
    let offset: Int64
    let length: Int64
    let chunk: String
}

/// Uploads files from the iPhone (Files app, iCloud Drive, USB stick) to the
/// server, one after another, in parts. Every finished part stays on the
/// server, so a lost connection or a restart continues there. Parts run in a
/// background session, which keeps going while the app is not in the
/// foreground. A whole folder becomes an album.
@MainActor
final class UploadManager: NSObject, ObservableObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    static let shared = UploadManager()
    static let sessionID = "net.miniply.background-uploads.v1"
    static let chunkSize: Int64 = 8 * 1024 * 1024
    static let maxRetries = 8

    struct Item: Identifiable {
        var record: UploadRecord
        var progress: Double = 0
        var state: State = .waiting
        var id: String { record.id }
        var name: String { record.name }
        var directory: String { record.directory }
        var bytes: Int64 { record.bytes }
        enum State: Equatable { case waiting, uploading, done, failed(String) }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var running = false
    /// Called when files arrived, so the library can be reloaded.
    var onFinished: (() async -> Void)?
    var backgroundCompletion: (() -> Void)?
    /// Normally the saved connection; tests pass their own.
    var connection: () -> Connection? = { Keychain.load() }
    /// Waiting time before a retry, in seconds.
    var retryDelay: (Int) -> Double = { min(30, pow(2, Double(min($0, 8)))) }
    private var retries: [String: Int] = [:]
    private var worker: Task<Void, Never>?
    /// The part each upload is waiting for. A completion of any other part
    /// comes from before a restart, and `begin` has already taken over.
    private var inFlight: [String: String] = [:]
    /// iOS may suspend the app right after the completion handler, so it waits
    /// until the next part is on its way.
    private var preparingParts = 0
    private var backgroundEventsFinished = false
    private var restored = false
    private var finishedAny = false
    private let sessionConfiguration: URLSessionConfiguration?
    private let storeURL: URL
    private let chunkDirectory: URL

    init(configuration: URLSessionConfiguration? = nil, directory: URL? = nil) {
        sessionConfiguration = configuration
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(String(localized: "Miniply"), isDirectory: true)
        storeURL = base.appendingPathComponent("uploads.json")
        chunkDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("miniply-upload-parts", isDirectory: true)
        super.init()
    }

    private lazy var session: URLSession = {
        let config = sessionConfiguration ?? URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    var pending: Int { items.filter { $0.state == .waiting || $0.state == .uploading }.count }

    /// Queue files. `scope` is the security-scoped URL the user picked (a
    /// folder or the file itself).
    func enqueue(_ files: [(URL, String, String)], scope: URL, model: AppModel) {
        let accessing = scope.startAccessingSecurityScopedResource()
        defer { if accessing { scope.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? scope.bookmarkData() else {
            model.error = String(localized: "Auf die Auswahl kann nicht dauerhaft zugegriffen werden.")
            return
        }
        let root = scope.standardizedFileURL.path
        for (url, directory, name) in files {
            let path = url.standardizedFileURL.path
            let relative = path == root ? "" : String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            add(UploadRecord(id: UUID().uuidString.lowercased(), scope: model.downloadScope, bookmark: bookmark,
                             relativePath: relative, directory: directory, name: name, bytes: size))
        }
        persist()
        pump()
    }

    func add(_ record: UploadRecord) { items.append(Item(record: record)) }

    /// After a launch: continue saved uploads. Parts still running are adopted.
    func restore() async {
        guard !restored else { return }
        restored = true
        let saved = (try? Data(contentsOf: storeURL)).flatMap { try? JSONDecoder().decode([UploadRecord].self, from: $0) } ?? []
        for record in saved where !items.contains(where: { $0.id == record.id }) { add(record) }
        for task in await session.allTasks {
            guard let info = Self.info(of: task), let index = items.firstIndex(where: { $0.id == info.id }) else {
                task.cancel()
                continue
            }
            items[index].record.offset = info.offset
            items[index].state = .uploading
            inFlight[info.id] = info.chunk
            updateProgress(index)
        }
        pump()
    }

    func clearFinished() {
        items.removeAll { $0.state == .done }
        persist()
    }

    func cancelAll() {
        let open = items.filter { $0.state == .waiting || $0.state == .uploading }.map(\.record)
        items.removeAll { item in open.contains { $0.id == item.id } }
        persist()
        running = false
        worker?.cancel()
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        guard let connection = connection() else { return }
        let api = API(connection)
        Task { for record in open where !record.legacy { await api.cancelUpload(record.id) } }
    }

    /// The connection was removed: nothing can continue without it.
    func connectionRemoved() {
        worker?.cancel()
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        inFlight = [:]
        retries = [:]
        for index in items.indices where items[index].state == .waiting || items[index].state == .uploading {
            items[index].state = .failed(String(localized: "Kein Server verbunden."))
        }
        running = false
        persist()
    }

    /// Continue a failed upload from what the server already has.
    func retry(_ item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].state = .waiting
        retries[item.id] = nil
        pump()
    }

    private func persist() {
        let open = items.filter { $0.state != .done }.map(\.record)
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(open).write(to: storeURL, options: .atomic)
        } catch { print("Uploads konnten nicht gespeichert werden: \(error.localizedDescription)") }
    }

    /// One file at a time, like before.
    private func pump() {
        guard !items.contains(where: { $0.state == .uploading }),
              let next = items.first(where: { $0.state == .waiting }) else {
            if pending == 0 { finishQueue() }
            return
        }
        running = true
        guard let index = items.firstIndex(where: { $0.id == next.id }) else { return }
        items[index].state = .uploading
        let id = next.id
        worker = Task { await self.begin(id) }
    }

    private func finishQueue() {
        running = false
        guard finishedAny else { return }
        finishedAny = false
        // The server rescans after each upload; fetch the new library.
        Task {
            try? await Task.sleep(for: .seconds(1))
            await onFinished?()
        }
    }

    private func index(_ id: String) -> Int? { items.firstIndex { $0.id == id } }

    private func isUploading(_ id: String) -> Bool { index(id).map { items[$0].state == .uploading } ?? false }

    private func updateProgress(_ index: Int, sent: Int64 = 0) {
        let record = items[index].record
        guard record.bytes > 0 else { return }
        items[index].progress = min(1, Double(record.offset + sent) / Double(record.bytes))
    }

    private func fail(_ id: String, _ message: String) {
        guard let index = index(id) else { return }
        items[index].state = .failed(message)
        retries[id] = nil
        persist()
        pump()
    }

    /// Ask the server how far this upload got, then send the next part.
    private func begin(_ id: String) async {
        guard isUploading(id) else { return }
        guard let connection = connection() else { fail(id, String(localized: "Kein Server verbunden.")); return }
        do {
            guard let received = try await API(connection).uploadStatus(id) else {
                await uploadWhole(id, api: API(connection))
                return
            }
            guard let index = index(id) else { return }
            items[index].record.offset = received
            updateProgress(index)
            persist()
            sendNextPart(id)
        } catch MiniplyError.unauthorized {
            fail(id, String(localized: "Zugriff verweigert."))
        } catch MiniplyError.server(403) {
            fail(id, String(localized: "Uploads sind auf dem Server ausgeschaltet."))
        } catch {
            retryLater(id, reason: error.localizedDescription)
        }
    }

    private func retryLater(_ id: String, reason: String) {
        let attempt = retries[id, default: 0]
        guard attempt < Self.maxRetries else {
            fail(id, String(localized: "Verbindung unterbrochen. Tippe auf „Fortsetzen“, wenn sie wieder steht. (\(reason))"))
            return
        }
        retries[id] = attempt + 1
        let wait = retryDelay(attempt)
        Task {
            try? await Task.sleep(for: .seconds(wait))
            await self.begin(id)
        }
    }

    /// The picked file, readable until `stop` is called.
    private nonisolated static func openSource(_ record: UploadRecord) throws -> (file: URL, scope: URL, accessing: Bool) {
        var stale = false
        let scope = try URL(resolvingBookmarkData: record.bookmark, bookmarkDataIsStale: &stale)
        let accessing = scope.startAccessingSecurityScopedResource()
        return (record.relativePath.isEmpty ? scope : scope.appendingPathComponent(record.relativePath), scope, accessing)
    }

    /// Copy the next part into its own file. Slow storage must not hold up the
    /// interface, and coordination fetches a file that is only in iCloud.
    private nonisolated static func writePart(_ record: UploadRecord, into directory: URL) throws -> (chunk: URL, length: Int64) {
        let source = try openSource(record)
        defer { if source.accessing { source.scope.stopAccessingSecurityScopedResource() } }
        var coordination: NSError?
        var result: Result<(chunk: URL, length: Int64), Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source.file, options: [], error: &coordination) { file in
            result = Result {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(record.offset))
                let data = try handle.read(upToCount: Int(chunkSize)) ?? Data()
                guard !data.isEmpty || record.bytes == 0 else {
                    throw MiniplyError.message(String(localized: "Die Datei ist kürzer als beim Auswählen."))
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let chunk = directory.appendingPathComponent("\(record.id)-\(record.offset)-\(UUID().uuidString).part")
                try data.write(to: chunk, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return (chunk, Int64(data.count))
            }
        }
        if let coordination { throw coordination }
        guard let result else { throw MiniplyError.message(String(localized: "Die Datei konnte nicht geöffnet werden.")) }
        return try result.get()
    }

    private func sendNextPart(_ id: String) {
        guard let index = index(id) else { return }
        guard let connection = connection() else { fail(id, String(localized: "Kein Server verbunden.")); return }
        let record = items[index].record
        guard record.scope == Self.scope(of: connection) else {
            fail(id, String(localized: "Diese Datei gehört zu einem anderen Server."))
            return
        }
        let directory = chunkDirectory
        preparingParts += 1
        Task {
            defer { partPrepared() }
            do {
                let part = try await Task.detached(priority: .utility) { try Self.writePart(record, into: directory) }.value
                guard isUploading(id) else {
                    try? FileManager.default.removeItem(at: part.chunk)
                    return
                }
                let request = try API(connection).uploadChunkRequest(id: id, offset: record.offset, bytes: record.bytes,
                                                                    directory: record.directory, name: record.name)
                let task = session.uploadTask(with: request, fromFile: part.chunk)
                let info = UploadTaskInfo(id: id, offset: record.offset, length: part.length, chunk: part.chunk.lastPathComponent)
                task.taskDescription = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
                inFlight[id] = info.chunk
                task.resume()
            } catch {
                fail(id, String(localized: "Datei nicht lesbar: \(error.localizedDescription)"))
            }
        }
    }

    private func partPrepared() {
        preparingParts -= 1
        completeBackgroundEvents()
    }

    private func completeBackgroundEvents() {
        guard backgroundEventsFinished, preparingParts == 0 else { return }
        backgroundEventsFinished = false
        backgroundCompletion?()
        backgroundCompletion = nil
    }

    static func scope(of connection: Connection) -> String {
        SHA256.hash(data: Data(connection.baseURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func info(of task: URLSessionTask) -> UploadTaskInfo? {
        task.taskDescription?.data(using: .utf8).flatMap { try? JSONDecoder().decode(UploadTaskInfo.self, from: $0) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                                totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        MainActor.assumeIsolated {
            guard let info = Self.info(of: task), let index = index(info.id) else { return }
            updateProgress(index, sent: totalBytesSent)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let info = Self.info(of: task) else { return }
            try? FileManager.default.removeItem(at: chunkDirectory.appendingPathComponent(info.chunk))
            guard index(info.id) != nil else { return }
            let current = inFlight[info.id] == info.chunk
            if current { inFlight[info.id] = nil }
            if let error {
                guard current, (error as NSError).code != NSURLErrorCancelled else { return }
                retryLater(info.id, reason: error.localizedDescription)
                return
            }
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            // "Arrived" holds for any part. Everything else only for the current one.
            if current || status == 201 { partFinished(info, status: status) }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundEventsFinished = true
            completeBackgroundEvents()
        }
    }

    private func partFinished(_ info: UploadTaskInfo, status: Int) {
        guard let index = index(info.id), status == 201 || items[index].state == .uploading else { return }
        switch status {
        case 200:
            retries[info.id] = nil
            items[index].record.offset = info.offset + info.length
            updateProgress(index)
            persist()
            sendNextPart(info.id)
        case 201:
            retries[info.id] = nil
            inFlight[info.id] = nil
            items[index].progress = 1
            items[index].state = .done
            finishedAny = true
            persist()
            pump()
        case 401: fail(info.id, String(localized: "Zugriff verweigert."))
        case 403: fail(info.id, String(localized: "Uploads sind auf dem Server ausgeschaltet."))
        case 409: fail(info.id, String(localized: "Gibt es dort schon."))
        case 507: fail(info.id, String(localized: "Server kann nicht schreiben (Rechte oder Speicher voll)."))
        case 400: fail(info.id, String(localized: "Der Server hat die Datei abgelehnt (ungültiger Name oder Ziel)."))
        // 412: out of step with the server, and every other answer may pass.
        default: retryLater(info.id, reason: "HTTP \(status)")
        }
    }

    /// Older server: the whole file in one request, in the foreground.
    private func uploadWhole(_ id: String, api: API) async {
        guard let index = index(id) else { return }
        items[index].record.legacy = true
        let record = items[index].record
        do {
            let source = try Self.openSource(record)
            defer { if source.accessing { source.scope.stopAccessingSecurityScopedResource() } }
            let request = try api.uploadRequest(directory: record.directory, name: record.name)
            let delegate = UploadProgress { [weak self] fraction in
                Task { @MainActor in
                    guard let self, let i = self.index(id) else { return }
                    self.items[i].progress = fraction
                }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 600
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            let whole = URLSession(configuration: configuration)
            defer { whole.finishTasksAndInvalidate() }
            let (data, response) = try await whole.upload(for: request, fromFile: source.file, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw MiniplyError.message(String(localized: "Ungültige Serverantwort.")) }
            guard let i = self.index(id) else { return }
            switch http.statusCode {
            case 200..<300:
                items[i].progress = 1
                items[i].state = .done
                finishedAny = true
                persist()
                pump()
            case 401: fail(id, String(localized: "Zugriff verweigert."))
            case 403: fail(id, String(localized: "Uploads sind auf dem Server ausgeschaltet."))
            case 409: fail(id, String(localized: "Gibt es dort schon."))
            case 507: fail(id, String(localized: "Server kann nicht schreiben (Rechte oder Speicher voll)."))
            default:
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                fail(id, message ?? "HTTP \(http.statusCode)")
            }
        } catch {
            fail(id, error.localizedDescription)
        }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate {
    let report: @Sendable (Double) -> Void
    init(report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

struct UploadView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var uploads: UploadManager
    @AppStorage("mediaserver.uploadCategory") private var category = "Musik"
    @State private var folder = ""
    @State private var picking = false
    @State private var pickingFolder = false
    private let categories = ["Musik", "Filme", "Serien", "Dokumente"]

    private var targetDirectory: String {
        let parts = [category] + folder.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.joined(separator: "/")
    }
    private var folderHint: String {
        switch category {
        case "Musik": String(localized: "Album, z. B. Linkin Park/Hybrid Theory")
        case "Serien": String(localized: "Serie/Staffel, z. B. Two and a Half Men/Season 1")
        case "Filme": String(localized: "Optionaler Unterordner")
        default: String(localized: "Optionaler Unterordner")
        }
    }

    var body: some View {
        List {
            if model.storage?.uploads == false {
                Section {
                    Label(String(localized: "Uploads sind auf deinem Server noch ausgeschaltet."), systemImage: "lock")
                        .foregroundStyle(.orange)
                    Text(String(localized: "Auf dem Pi in /etc/miniply/server.env die Zeile MINIPLY_UPLOADS=1 ergänzen und Schreibrechte einrichten (siehe Anleitung im Projekt). Danach den Dienst neu starten."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Picker(String(localized: "Bereich"), selection: $category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField(folderHint, text: $folder)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                LabeledContent(String(localized: "Ziel"), value: targetDirectory)
            } header: { Text("Wohin?") } footer: {
                Text(category == "Musik"
                     ? String(localized: "Wählst du einen ganzen Ordner, wird er unter diesem Ziel als eigenes Album angelegt. Ein Bild im Ordner wird zum Cover.")
                     : String(localized: "Vorhandene Dateien werden nie überschrieben."))
            }
            Section {
                Button { pickingFolder = false; picking = true } label: { Label(String(localized: "Dateien auswählen"), systemImage: "doc.badge.plus") }
                Button { pickingFolder = true; picking = true } label: { Label(String(localized: "Ganzen Ordner hochladen"), systemImage: "folder.badge.plus") }
            }
            .disabled(model.api == nil)
            if !uploads.items.isEmpty {
                Section {
                    ForEach(uploads.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: icon(item.state)).foregroundStyle(color(item.state))
                                Text(item.name).lineLimit(1)
                                Spacer()
                                Text(byteLabel(UInt64(max(0, item.bytes)))).font(.caption).foregroundStyle(.secondary)
                            }
                            if item.state == .uploading { ProgressView(value: item.progress).tint(.mint) }
                            if case let .failed(message) = item.state {
                                Text(message).font(.caption).foregroundStyle(.red)
                                Button(String(localized: "Fortsetzen"), systemImage: "arrow.clockwise") { uploads.retry(item) }
                                    .font(.caption).buttonStyle(.borderless)
                            }
                            Text(item.directory).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                } header: {
                    HStack {
                        Text(uploads.pending > 0 ? "Wird hochgeladen · \(uploads.pending) offen" : "Uploads")
                        Spacer()
                        if uploads.pending > 0 {
                            Button(String(localized: "Abbrechen"), role: .destructive) { uploads.cancelAll() }.font(.caption)
                        } else {
                            Button(String(localized: "Liste leeren")) { uploads.clearFinished() }.font(.caption)
                        }
                    }
                }
            }
        }
        .miniPlayerRoom()
        .navigationTitle(String(localized: "Hochladen"))
        // One importer only: SwiftUI ignores all but one fileImporter per view.
        .fileImporter(isPresented: $picking, allowedContentTypes: pickingFolder ? [.folder] : [.item],
                      allowsMultipleSelection: !pickingFolder) { result in
            guard case let .success(urls) = result else { return }
            if pickingFolder, let folderURL = urls.first {
                let accessing = folderURL.startAccessingSecurityScopedResource()
                let files = Self.files(in: folderURL, base: targetDirectory + "/" + folderURL.lastPathComponent)
                if accessing { folderURL.stopAccessingSecurityScopedResource() }
                uploads.enqueue(files, scope: folderURL, model: model)
            } else {
                for url in urls {
                    uploads.enqueue([(url, targetDirectory, url.lastPathComponent)], scope: url, model: model)
                }
            }
        }
    }

    /// Every visible file below `folder`, keeping its sub-folders.
    static func files(in folder: URL, base: String) -> [(URL, String, String)] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [(URL, String, String)] = []
        let rootPath = folder.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = url.deletingLastPathComponent().standardizedFileURL.path.dropFirst(rootPath.count)
                .split(separator: "/").joined(separator: "/")
            let directory = relative.isEmpty ? base : base + "/" + relative
            result.append((url, directory, url.lastPathComponent))
        }
        return result.sorted { ($0.1, $0.2) < ($1.1, $1.2) }
    }

    private func icon(_ state: UploadManager.Item.State) -> String {
        switch state {
        case .waiting: "clock"
        case .uploading: "arrow.up.circle"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
    private func color(_ state: UploadManager.Item.State) -> Color {
        switch state {
        case .waiting: .secondary
        case .uploading: .mint
        case .done: .green
        case .failed: .orange
        }
    }
}
