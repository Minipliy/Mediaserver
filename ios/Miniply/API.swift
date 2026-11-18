import CryptoKit
import Foundation

/// The last answer to lists the app fetches again and again, with the server's
/// fingerprint (ETag). Sent back, an unchanged list costs a "304" without data:
/// on mobile data a check is a few bytes instead of the whole library.
final class AnswerStore: @unchecked Sendable {
    static let shared = AnswerStore()
    private let lock = NSLock()
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("miniply-answers", isDirectory: true)

    private func file(_ url: URL, _ ending: String) -> URL {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ending)
    }

    func load(_ url: URL) -> (tag: String, body: Data)? {
        lock.lock(); defer { lock.unlock() }
        guard let tag = try? String(contentsOf: file(url, ".tag"), encoding: .utf8),
              let body = try? Data(contentsOf: file(url, ".body")) else { return nil }
        return (tag, body)
    }

    func save(_ body: Data, tag: String, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Body first: a tag without its body is never read as valid.
        guard (try? body.write(to: file(url, ".body"), options: .atomic)) != nil else { return }
        try? tag.write(to: file(url, ".tag"), atomically: true, encoding: .utf8)
    }

    func forget(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: file(url, ".tag"))
        try? FileManager.default.removeItem(at: file(url, ".body"))
    }
}

/// Refuse cross-origin redirects so a download cannot forward its Bearer token.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let target = request.url,
              original.scheme == target.scheme, original.host == target.host,
              original.port == target.port else { completionHandler(nil); return }
        completionHandler(request)
    }
}

final class API {
    let connection: Connection
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(_ connection: Connection, configuration: URLSessionConfiguration = .ephemeral) {
        self.connection = connection
        let config = configuration
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 86_400
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    deinit { session.invalidateAndCancel() }

    static func validate(address: String, token: String) throws -> Connection {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else {
            throw MiniplyError.message(String(localized: "Bitte eine Serveradresse ohne Pfad oder Zugangsdaten eingeben."))
        }
        var allowed = parts.scheme == "https"
        #if DEBUG
        allowed = allowed || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
        #endif
        guard allowed else { throw MiniplyError.message(String(localized: "Die Serveradresse muss HTTPS verwenden.")) }
        guard token.count >= 32, !token.contains(where: \.isWhitespace) else {
            throw MiniplyError.message(String(localized: "Das API-Token benötigt mindestens 32 Zeichen ohne Leerzeichen."))
        }
        parts.path = ""
        guard let url = parts.url else { throw MiniplyError.message(String(localized: "Ungültige Serveradresse.")) }
        return Connection(baseURL: url, token: token)
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         query: [URLQueryItem] = []) throws -> URLRequest {
        guard var parts = URLComponents(url: connection.baseURL, resolvingAgainstBaseURL: false) else {
            throw MiniplyError.message(String(localized: "Ungültige Serveradresse."))
        }
        parts.path = path
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw MiniplyError.message(String(localized: "Ungültige Anfrage.")) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw MiniplyError.message(String(localized: "Ungültige Serverantwort.")) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw MiniplyError.unauthorized }
            throw MiniplyError.server(http.statusCode)
        }
    }

    /// Lists answered with a fingerprint by the server (see `AnswerStore`).
    static let rememberedPaths: Set<String> = ["/v1/library", "/v1/metadata", "/v1/playlists", "/v1/music/follows"]

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var request = try request(path, query: query)
        let url = request.url
        let stored = Self.rememberedPaths.contains(path) ? url.flatMap(AnswerStore.shared.load) : nil
        if let stored { request.setValue(stored.tag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 304, let stored, let url {
            if let value = try? decoder.decode(T.self, from: stored.body) { return value }
            // A stored answer that no longer fits: ask once more without it.
            AnswerStore.shared.forget(url)
            return try await get(path, query: query)
        }
        try check(response)
        if Self.rememberedPaths.contains(path), let url,
           let tag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") {
            AnswerStore.shared.save(data, tag: tag, for: url)
        }
        return try decoder.decode(T.self, from: data)
    }

    func send<T: Encodable>(_ path: String, method: String, value: T) async throws {
        let (_, response) = try await session.data(for: request(path, method: method, body: encoder.encode(value)))
        try check(response)
    }

    func sendAndDecode<T: Encodable, Response: Decodable>(_ path: String, method: String, value: T) async throws -> Response {
        let (data, response) = try await session.data(for: request(path, method: method, body: encoder.encode(value)))
        try check(response)
        return try decoder.decode(Response.self, from: data)
    }

    /// Sends JSON that is already encoded, such as a MetricKit report.
    func post(_ path: String, json: Data) async throws {
        let (_, response) = try await session.data(for: request(path, method: "POST", body: json))
        try check(response)
    }

    /// The Pi's state for the status page.
    func status() async throws -> ServerStatusInfo { try await get("/v1/status") }

    func perform(_ path: String, method: String) async throws {
        let (_, response) = try await session.data(for: request(path, method: method))
        try check(response)
    }

    /// `preferAdaptive` returns the HLS playlist when the server offers one.
    func ticket(_ media: Media, preferAdaptive: Bool = false) async throws -> URL {
        let (data, response) = try await session.data(for: request("/v1/media/\(media.id)/ticket", method: "POST"))
        try check(response)
        let ticket = try decoder.decode(StreamTicket.self, from: data)
        let adaptive = preferAdaptive ? ticket.hlsPath.flatMap { $0.hasPrefix("/stream/\(media.id)/hls/") ? $0 : nil } : nil
        guard adaptive != nil || ticket.path.hasPrefix("/stream/\(media.id)?"),
              let url = URL(string: adaptive ?? ticket.path, relativeTo: connection.baseURL)?.absoluteURL,
              url.host == connection.baseURL.host, url.scheme == connection.baseURL.scheme,
              url.port == connection.baseURL.port else { throw MiniplyError.message(String(localized: "Ungültige Streaming-Adresse.")) }
        return url
    }

    /// Resume sync is optional during startup. A stalled server must not hold
    /// playable media behind the normal API timeout (or a trickling response).
    func playbackProgress(_ media: Media) async -> PlaybackProgress? {
        await withTaskGroup(of: PlaybackProgress?.self) { group in
            group.addTask { try? await self.get("/v1/progress/\(media.id)") }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let progress = await group.next() ?? nil
            group.cancelAll()
            return progress
        }
    }

    /// Cover image bytes (folder image, embedded cover or online artwork).
    func artwork(_ id: String) async throws -> Data {
        guard !id.isEmpty, id.count <= 80, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw MiniplyError.message(String(localized: "Ungültige Bild-ID."))
        }
        let (data, response) = try await session.data(for: request("/v1/artwork/\(id)"))
        try check(response)
        return data
    }

    /// Lyrics for a track; nil when none were found (HTTP 404).
    func lyrics(_ media: Media) async throws -> LyricsPayload? {
        let (data, response) = try await session.data(for: request("/v1/lyrics/\(media.id)"))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try check(response)
        return try decoder.decode(LyricsPayload.self, from: data)
    }

    /// Subtitle file as WebVTT text.
    func subtitles(_ subtitle: SubtitleRef) async throws -> String {
        let (data, response) = try await session.data(for: request("/v1/subtitles/\(subtitle.id)"))
        try check(response)
        return String(decoding: data, as: UTF8.self)
    }

    /// Bytes the server already has of a resumable upload. Nil on an older
    /// server without resumable uploads.
    func uploadStatus(_ id: String) async throws -> Int64? {
        let (data, response) = try await session.data(for: request("/v1/uploads/\(id)"))
        if [404, 405].contains((response as? HTTPURLResponse)?.statusCode) { return nil }
        try check(response)
        return try decoder.decode(UploadStatus.self, from: data).received
    }

    func cancelUpload(_ id: String) async {
        guard let request = try? request("/v1/uploads/\(id)", method: "DELETE") else { return }
        _ = try? await session.data(for: request)
    }

    /// Request for one part of a resumable upload; the body is sent from a file.
    func uploadChunkRequest(id: String, offset: Int64, bytes: Int64, directory: String, name: String) throws -> URLRequest {
        var request = try request("/v1/uploads/\(id)", method: "PUT", query: [
            URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "bytes", value: String(bytes)),
            URLQueryItem(name: "path", value: directory), URLQueryItem(name: "name", value: name)
        ])
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Nil on an older server without shared favourites and statistics.
    func syncPersonal(_ state: PersonalSyncRequest) async throws -> PersonalSyncResponse? {
        let (data, response) = try await session.data(for: request("/v1/personal/sync", method: "POST", body: encoder.encode(state)))
        if [404, 405].contains((response as? HTTPURLResponse)?.statusCode) { return nil }
        try check(response)
        return try decoder.decode(PersonalSyncResponse.self, from: data)
    }

    /// Request for `POST /v1/upload`; the body is sent from a file.
    func uploadRequest(directory: String, name: String) throws -> URLRequest {
        var request = try request("/v1/upload", method: "POST",
                                  query: [URLQueryItem(name: "path", value: directory), URLQueryItem(name: "name", value: name)])
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        return request
    }

    /// Temporary file with the response; the caller moves or removes it.
    func downloadFile(_ request: URLRequest) async throws -> URL {
        let (file, response) = try await session.download(for: request)
        do { try check(response) } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return file
    }

    func downloadRequest(_ media: Media, allowsCellular: Bool? = nil) throws -> URLRequest {
        var request = try request("/v1/files/\(media.id)/download", query: [URLQueryItem(name: "playback", value: "true")])
        request.allowsCellularAccess = allowsCellular ?? UserDefaults.standard.bool(forKey: "miniply.cellularDownloads")
        return request
    }
}
