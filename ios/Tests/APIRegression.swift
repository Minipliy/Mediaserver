import Foundation

private final class ProgressProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var cancelled: Set<String> = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "startup-regression.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.url!.lastPathComponent
        // Deliberately never deliver headers for these requests. The API must
        // cancel the actual transfer when its deadline or caller cancels.
        guard id != "stalled" && id != "cancelled" else { return }
        let status = id == "unauthorized" ? 401 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"seconds\":42}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.cancelled.insert(request.url!.lastPathComponent)
        Self.lock.unlock()
    }

    static func wasCancelled(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(id)
    }
}

/// A server that answers playlists with a fingerprint and "304" when it matches.
private final class FingerprintProtocol: URLProtocol {
    nonisolated(unsafe) static var bodies = 0
    nonisolated(unsafe) static var notModified = 0
    nonisolated(unsafe) static var tag = "\"v1\""

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fingerprint-regression.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let matches = request.value(forHTTPHeaderField: "If-None-Match") == Self.tag
        let status = matches ? 304 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["ETag": Self.tag])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if matches { Self.notModified += 1 } else {
            Self.bodies += 1
            client?.urlProtocol(self, didLoad: Data(#"[{"id":"p","name":"Liste \#(Self.tag.count)","media_ids":[]}]"#.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct PlaylistWire: Decodable { let id: String; let name: String }

@main
private struct APIRegression {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProgressProtocol.self]
        let api = API(Connection(baseURL: URL(string: "https://startup-regression.invalid")!, token: "regression-token"),
                      configuration: configuration)
        func media(_ id: String) -> Media {
            Media(id: id, path: "sample.mp3", name: "sample.mp3", kind: "audio", title: "Sample",
                  artist: nil, album: nil, duration: 60, bytes: 100, modified: 1)
        }
        func expect(_ value: Bool, _ message: String) {
            guard value else { fatalError(message) }
            print("PASS " + message)
        }
        // Unchanged lists come from the device after a "304"; a change loads again.
        let fingerprintConfiguration = URLSessionConfiguration.ephemeral
        fingerprintConfiguration.protocolClasses = [FingerprintProtocol.self]
        let fingerprintAPI = API(Connection(baseURL: URL(string: "https://fingerprint-regression.invalid")!, token: "regression-token"),
                                 configuration: fingerprintConfiguration)
        AnswerStore.shared.forget(URL(string: "https://fingerprint-regression.invalid/v1/playlists")!)
        let first: [PlaylistWire] = try await fingerprintAPI.get("/v1/playlists")
        let second: [PlaylistWire] = try await fingerprintAPI.get("/v1/playlists")
        expect(first.first?.id == "p" && second.first?.id == "p" && FingerprintProtocol.bodies == 1 && FingerprintProtocol.notModified == 1,
               "An unchanged list is answered with 304 and read from the device")
        FingerprintProtocol.tag = "\"v2-changed\""
        let third: [PlaylistWire] = try await fingerprintAPI.get("/v1/playlists")
        expect(FingerprintProtocol.bodies == 2 && third.first?.name == "Liste 12", "A changed list is loaded again")
        AnswerStore.shared.forget(URL(string: "https://fingerprint-regression.invalid/v1/playlists")!)

        let quickStart = Date()
        let quick = await api.playbackProgress(media("quick"))
        expect(quick?.seconds == 42 && Date().timeIntervalSince(quickStart) < 1,
               "Available remote position returns without waiting for the deadline")
        let unauthorized = await api.playbackProgress(media("unauthorized"))
        expect(unauthorized == nil, "Failed optional sync preserves the local resume fallback")

        let stalledStart = Date()
        let stalled = await api.playbackProgress(media("stalled"))
        let elapsed = Date().timeIntervalSince(stalledStart)
        expect(stalled == nil && elapsed >= 1.8 && elapsed < 3,
               "Unresponsive progress endpoint is bounded to two seconds")
        let cancelledStart = Date()
        let task = Task { await api.playbackProgress(media("cancelled")) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let cancelled = await task.value
        expect(cancelled == nil && Date().timeIntervalSince(cancelledStart) < 1,
               "Changing or stopping playback cancels pending resume lookup promptly")
        for _ in 0..<20 {
            if ProgressProtocol.wasCancelled("stalled") && ProgressProtocol.wasCancelled("cancelled") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        expect(ProgressProtocol.wasCancelled("stalled") && ProgressProtocol.wasCancelled("cancelled"),
               "Timeout and caller cancellation stop the underlying network requests")
    }
}
