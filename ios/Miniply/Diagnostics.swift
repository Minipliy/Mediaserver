import CryptoKit
import Foundation
import MetricKit

/// iOS hands crash and hang reports (MetricKit) to the app, usually on a later start.
/// They wait here until the app reaches its own server and are then sent there,
/// never to a third party. On the Pi they land in /var/lib/miniply/diagnostics.
final class DiagnosticsCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = DiagnosticsCollector()
    private static let sentKey = "mediaserver.sentDiagnostics"
    private static let keepSent = 200
    private let lock = NSLock()

    private var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diagnostics", isDirectory: true)
    }

    func start() {
        MXMetricManager.shared.add(self)
        store(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { store(payloads) }

    /// Each report once: its name is the hash of its content, and sent ones are remembered.
    private func store(_ payloads: [MXDiagnosticPayload]) {
        lock.lock(); defer { lock.unlock() }
        let sent = Set(UserDefaults.standard.stringArray(forKey: Self.sentKey) ?? [])
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for payload in payloads {
            let data = payload.jsonRepresentation()
            let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let file = folder.appendingPathComponent(name + ".json")
            guard !sent.contains(name), !FileManager.default.fileExists(atPath: file.path) else { continue }
            try? data.write(to: file, options: .atomic)
        }
    }

    func pending() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
    }

    func markSent(_ file: URL) {
        lock.lock(); defer { lock.unlock() }
        var sent = UserDefaults.standard.stringArray(forKey: Self.sentKey) ?? []
        sent.append(file.deletingPathExtension().lastPathComponent)
        UserDefaults.standard.set(Array(sent.suffix(Self.keepSent)), forKey: Self.sentKey)
        try? FileManager.default.removeItem(at: file)
    }
}

/// Outage warnings: the watchers on the Pi and the VPS send them through Apple's push service
/// straight to this app (no third-party app). The app only hands its push address to its own server.
enum OutageAlerts {
    static let enabledKey = "mediaserver.outageAlerts"
    static let tokenKey = "mediaserver.pushToken"
    static let sentKey = "mediaserver.pushTokenSent"
    static let tokenChanged = Notification.Name("mediaserverPushTokenChanged")

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Push addresses from debug builds only work against Apple's test service.
    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    static let sentAtKey = "mediaserver.pushTokenSentAt"
    /// The server forgets addresses it has not heard of for 90 days, so the app
    /// reports its address again once a week.
    static let resendSeconds: TimeInterval = 7 * 86_400

    /// What still has to reach the server, if anything.
    static var unsentToken: String? {
        let defaults = UserDefaults.standard
        guard isEnabled, let token = defaults.string(forKey: tokenKey) else { return nil }
        let sentAt = defaults.double(forKey: sentAtKey)
        let fresh = defaults.string(forKey: sentKey) == token + environment
            && Date().timeIntervalSince1970 - sentAt < resendSeconds
        return fresh ? nil : token
    }

    static func markSent(_ token: String) {
        UserDefaults.standard.set(token + environment, forKey: sentKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: sentAtKey)
    }

    static func received(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: tokenKey)
        NotificationCenter.default.post(name: tokenChanged, object: nil)
    }
}
