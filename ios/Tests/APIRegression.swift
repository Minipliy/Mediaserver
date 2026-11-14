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
