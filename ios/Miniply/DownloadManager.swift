import Foundation
import UIKit

extension Notification.Name {
    static let miniplyDownloadsChanged = Notification.Name("miniplyDownloadsChanged")
}

/// A stopped transfer that can continue. The resume data holds the original
/// request including its token, so it stays in the protected app directory.
struct PausedDownload: Codable {
    let job: DownloadJob
    var fraction: Double
    /// Nil when the server offered no way to continue: starts over.
    var resumeData: Data?
    /// Stopped by the connection or the server, not by the user: continues by itself
    /// once the server answers again.
    var interrupted: Bool? = nil
    var remainingBytes: UInt64 {
        job.media.bytes - min(job.media.bytes, UInt64(Double(job.media.bytes) * min(1, max(0, fraction))))
    }
    var fileURL: URL { job.directory.appendingPathComponent(job.media.id + ".paused.json") }

    func save() throws {
        try FileManager.default.createDirectory(at: job.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Everything saved on this device. Invalid files are ignored.
    static func loadAll(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Miniply", isDirectory: true)) -> [PausedDownload] {
        let files = FileManager.default
        let scopes = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return scopes.flatMap { scope -> [PausedDownload] in
            let urls = (try? files.contentsOfDirectory(at: scope, includingPropertiesForKeys: nil)) ?? []
            return urls.filter { $0.lastPathComponent.hasSuffix(".paused.json") }.compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let paused = try? JSONDecoder().decode(PausedDownload.self, from: data),
                      DownloadJob.validIdentifier(paused.job.scope), DownloadJob.validIdentifier(paused.job.media.id),
                      paused.job.scope == scope.lastPathComponent,
                      url.lastPathComponent == paused.job.media.id + ".paused.json" else { return nil }
                return paused
            }
        }
    }
}

struct DownloadJob: Codable {
    let scope: String
    let media: Media
    var key: String { scope + "/" + media.id }
    var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Miniply/\(scope)", isDirectory: true)
    }
    var filename: String {
        let ext = (media.name as NSString).pathExtension
        let safe = ext.count <= 12 && ext.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
        return media.id + (ext.isEmpty ? "" : "." + (safe ? ext : "bin"))
    }
    var recordURL: URL { directory.appendingPathComponent(media.id + ".offline.json") }
    static func validIdentifier(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func localURL(for record: OfflineRecord, in directory: URL) -> URL? {
        guard validIdentifier(record.media.id),
              record.filename == DownloadJob(scope: "", media: record.media).filename else { return nil }
        let url = directory.appendingPathComponent(record.filename)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, UInt64(size) == record.media.bytes else { return nil }
        return url
    }
    func storeDownload(from location: URL) throws {
        guard Self.validIdentifier(scope), Self.validIdentifier(media.id) else {
            throw MiniplyError.message(String(localized: "Ungültiger Bibliothekseintrag."))
        }
        let manager = FileManager.default
        // Prepare metadata before touching a previous offline copy. A failed
        // metadata write must not leave a large, unlisted media file behind.
        let metadata = try JSONEncoder().encode(OfflineRecord(media: media, filename: filename))
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(filename)
        let backup = directory.appendingPathComponent(".\(UUID().uuidString).previous")
        let hadPrevious = manager.fileExists(atPath: target.path)
        if hadPrevious { try manager.moveItem(at: target, to: backup) }
        do {
            // Move before returning: iOS deletes the URLSession temporary file.
            try manager.moveItem(at: location, to: target)
            try metadata.write(to: recordURL, options: .atomic)
        } catch {
            try? manager.removeItem(at: target)
            if hadPrevious { try? manager.moveItem(at: backup, to: target) }
            throw error
        }
        if hadPrevious { try? manager.removeItem(at: backup) }
    }
    static func decode(_ task: URLSessionTask) -> DownloadJob? {
        guard let raw = task.taskDescription?.data(using: .utf8),
              let job = try? JSONDecoder().decode(DownloadJob.self, from: raw),
              validIdentifier(job.scope), validIdentifier(job.media.id) else { return nil }
        return job
    }
}

private enum DownloadError: Error { case temporary }

@MainActor
final class DownloadManager: NSObject, URLSessionDownloadDelegate {
    private static let progressInterval = 0.5
    private var progressNoticeWaiting = false
    static let shared = DownloadManager()
    static let sessionID = "net.miniply.background-downloads.v1"
    private(set) var active: [String: (job: DownloadJob, fraction: Double)] = [:]
    private(set) var paused: [String: PausedDownload] = [:]
    /// Automatic retries per transfer since it last received data.
    private var retries: [String: Int] = [:]
    /// The latest point to continue from, also when a retry gets an error page instead of data.
    private var resumePoints: [String: Data] = [:]
    private var pausing: Set<Int> = []
    /// Short outages of the Pi (Wi-Fi, tunnel) last minutes: retry with growing pauses,
    /// about two hours in all, before asking the user. iOS starts the retries itself,
    /// also while the app is in the background.
    static let retryDelays: [TimeInterval] = [15, 30, 60, 120, 300, 600, 900, 1800, 1800, 1800]
    static var maxRetries: Int { retryDelays.count }
    private(set) var lastFailure: (scope: String, message: String)?
    private var pendingBytes: [String: UInt64] = [:]
    private var taskIDs: [String: Int] = [:]
    private var finishedTaskIDs: Set<Int> = []
    private var jobCancellations: [String: UUID] = [:]
    private var scopeCancellations: [String: UUID] = [:]
    var backgroundCompletion: (() -> Void)?
    private var restored: Task<Void, Never>?
    private let sessionConfiguration: URLSessionConfiguration?

    /// Nil uses the background session of the app.
    init(configuration: URLSessionConfiguration?) {
        sessionConfiguration = configuration
        super.init()
    }

    override convenience init() { self.init(configuration: nil) }

    private lazy var session: URLSession = {
        let config = sessionConfiguration ?? URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        config.httpMaximumConnectionsPerHost = 2
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    func restore() {
        guard restored == nil else { return }
        for entry in PausedDownload.loadAll() { paused[entry.job.key] = entry }
        restored = Task {
            let tasks = await session.allTasks
            for task in tasks {
                guard !finishedTaskIDs.contains(task.taskIdentifier), task.state != .completed, task.state != .canceling else { continue }
                guard let job = DownloadJob.decode(task) else { task.cancel(); continue }
                if let current = taskIDs[job.key], current != task.taskIdentifier { task.cancel(); continue }
                taskIDs[job.key] = task.taskIdentifier
                active[job.key] = (job, min(1, max(0, task.progress.fractionCompleted)))
                pendingBytes[job.key] = job.media.bytes - min(job.media.bytes, UInt64(max(0, task.countOfBytesReceived)))
                removePaused(key: job.key)
            }
            notify()
        }
    }

    func start(media: Media, scope: String, request: URLRequest,
               shouldStart: @MainActor () -> Bool = { true }) async throws {
        let job = DownloadJob(scope: scope, media: media)
        let expectedJobCancellation = jobCancellations[job.key]
        let expectedScopeCancellation = scopeCancellations[scope]
        restore()
        await restored?.value
        guard shouldStart(), !Task.isCancelled,
              jobCancellations[job.key] == expectedJobCancellation,
              scopeCancellations[scope] == expectedScopeCancellation else { throw CancellationError() }
        guard DownloadJob.validIdentifier(scope), DownloadJob.validIdentifier(media.id) else {
            throw MiniplyError.message(String(localized: "Ungültiger Bibliothekseintrag. Bibliothek aktualisieren und erneut herunterladen."))
        }
        guard active[job.key] == nil, paused[job.key] == nil else { return }
        try FileManager.default.createDirectory(at: job.directory, withIntermediateDirectories: true)
        var directory = job.directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let free = try job.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        // Reserve the outstanding bytes of all queued downloads on this device.
        // Already received bytes occupy disk space and must not be reserved twice.
        let reserved = (Array(pendingBytes.values) + paused.values.map(\.remainingBytes)).reduce(UInt64(0)) { total, bytes in
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            return overflow ? UInt64.max : sum
        }
        if let free, free >= 0 {
            guard free > 50_000_000, reserved < UInt64(free - 50_000_000),
                  media.bytes <= UInt64(free - 50_000_000) - reserved else {
                throw MiniplyError.message(String(localized: "Zu wenig freier Speicher für diesen Download."))
            }
        }
        let description = String(decoding: try JSONEncoder().encode(job), as: UTF8.self)
        let task = session.downloadTask(with: request)
        task.taskDescription = description
        taskIDs[job.key] = task.taskIdentifier
        pendingBytes[job.key] = media.bytes
        active[job.key] = (job, 0)
        task.resume()
        notify()
    }

    /// Stop a transfer and keep what arrived. Works across app restarts.
    func pause(scope: String, id: String) async {
        restore()
        await restored?.value
        for task in await session.allTasks {
            guard let task = task as? URLSessionDownloadTask, let job = DownloadJob.decode(task),
                  job.scope == scope, job.media.id == id else { continue }
            pausing.insert(task.taskIdentifier)
            let fraction = active[job.key]?.fraction ?? 0
            let data = await task.cancelByProducingResumeData()
            // It may have finished in the meantime.
            if data == nil, FileManager.default.fileExists(atPath: job.recordURL.path) { return }
            keepPaused(PausedDownload(job: job, fraction: data == nil ? 0 : fraction, resumeData: data))
            return
        }
    }

    func resume(scope: String, id: String, request: URLRequest) async throws {
        restore()
        await restored?.value
        let key = scope + "/" + id
        guard let entry = paused[key] else { return }
        let task = entry.resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
        task.taskDescription = String(decoding: try JSONEncoder().encode(entry.job), as: UTF8.self)
        taskIDs[key] = task.taskIdentifier
        pendingBytes[key] = entry.remainingBytes
        active[key] = (entry.job, entry.fraction)
        removePaused(key: key)
        task.resume()
        notify()
    }

    func keepPaused(_ entry: PausedDownload) {
        active.removeValue(forKey: entry.job.key)
        pendingBytes.removeValue(forKey: entry.job.key)
        paused[entry.job.key] = entry
        try? entry.save()
        notify()
    }

    private func removePaused(key: String) {
        guard let entry = paused.removeValue(forKey: key) else { return }
        try? FileManager.default.removeItem(at: entry.fileURL)
    }

    /// Lost connection, the server briefly gone (502 from the VPS) or an iOS interruption:
    /// continue from where it stopped after a pause, and only bother the user when that keeps failing.
    private func interrupted(_ job: DownloadJob, taskID: Int, resumeData: Data?, request: URLRequest?) {
        guard !finishedTaskIDs.contains(taskID) else { return }
        if let resumeData { resumePoints[job.key] = resumeData }
        let resumeData = resumeData ?? resumePoints[job.key]
        let fraction = resumeData == nil ? 0 : active[job.key]?.fraction ?? 0
        let attempts = retries[job.key, default: 0]
        finish(job, taskID: taskID)
        guard attempts < Self.maxRetries, resumeData != nil || request != nil,
              let description = try? JSONEncoder().encode(job) else {
            resumePoints.removeValue(forKey: job.key)
            lastFailure = (job.scope, String(localized: "Der Download von „\(job.media.title)“ wurde unterbrochen. Er geht weiter, sobald der Server wieder antwortet."))
            keepPaused(PausedDownload(job: job, fraction: fraction, resumeData: resumeData, interrupted: true))
            return
        }
        retries[job.key] = attempts + 1
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request!)
        task.earliestBeginDate = Date().addingTimeInterval(Self.retryDelays[attempts])
        task.taskDescription = String(decoding: description, as: UTF8.self)
        taskIDs[job.key] = task.taskIdentifier
        pendingBytes[job.key] = PausedDownload(job: job, fraction: fraction, resumeData: nil).remainingBytes
        active[job.key] = (job, fraction)
        task.resume()
        notify()
    }

    /// Error pages of a server that is briefly unreachable, not a final answer.
    nonisolated static func isTemporary(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    func cancel(scope: String, id: String) async {
        jobCancellations[scope + "/" + id] = UUID()
        restore()
        await restored?.value
        removePaused(key: scope + "/" + id)
        notify()
        for task in await session.allTasks {
            if let job = DownloadJob.decode(task), job.scope == scope, job.media.id == id { task.cancel() }
        }
    }

    func cancelAll(scope: String) async {
        scopeCancellations[scope] = UUID()
        restore()
        await restored?.value
        for key in paused.keys where paused[key]?.job.scope == scope { removePaused(key: key) }
        for task in await session.allTasks {
            if DownloadJob.decode(task)?.scope == scope { task.cancel() }
        }
    }

    func takeFailure(scope: String) -> String? {
        guard lastFailure?.scope == scope else { return nil }
        defer { lastFailure = nil }
        return lastFailure?.message
    }

    private func notify() { NotificationCenter.default.post(name: .miniplyDownloadsChanged, object: nil) }

    /// Several downloads report many times per second; the display needs far less.
    private func notifyProgress() {
        guard !progressNoticeWaiting else { return }
        progressNoticeWaiting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.progressInterval) { [weak self] in
            self?.progressNoticeWaiting = false
            self?.notify()
        }
    }

    private func finish(_ job: DownloadJob, taskID: Int, failure: String? = nil) {
        guard !finishedTaskIDs.contains(taskID) else { return }
        finishedTaskIDs.insert(taskID)
        guard taskIDs[job.key] == nil || taskIDs[job.key] == taskID else { return }
        taskIDs.removeValue(forKey: job.key)
        pendingBytes.removeValue(forKey: job.key)
        active.removeValue(forKey: job.key)
        retries.removeValue(forKey: job.key)
        if let failure { lastFailure = (job.scope, failure) }
        notify()
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                               totalBytesExpectedToWrite: Int64) {
        guard let job = DownloadJob.decode(downloadTask) else { return }
        let taskID = downloadTask.taskIdentifier
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finishedTaskIDs.contains(taskID),
                  self.taskIDs[job.key] == nil || self.taskIDs[job.key] == taskID else { return }
            self.taskIDs[job.key] = taskID
            self.retries.removeValue(forKey: job.key)
            self.pendingBytes[job.key] = job.media.bytes - min(job.media.bytes, UInt64(max(0, totalBytesWritten)))
            if let old = self.active[job.key]?.fraction, abs(old - fraction) < 0.01 { return }
            self.active[job.key] = (job, min(1, max(0, fraction)))
            self.notifyProgress()
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = DownloadJob.decode(downloadTask) else { return }
        let taskID = downloadTask.taskIdentifier
        do {
            if let response = downloadTask.response as? HTTPURLResponse, Self.isTemporary(status: response.statusCode) {
                throw DownloadError.temporary
            }
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 || response.statusCode == 206 else {
                throw MiniplyError.message(String(localized: "Download fehlgeschlagen. Zugriff und Serververbindung prüfen."))
            }
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.uint64Value
            guard size == job.media.bytes else {
                throw MiniplyError.message(String(localized: "Dateigröße hat sich geändert. Bibliothek aktualisieren und erneut herunterladen."))
            }
            try job.storeDownload(from: location)
            var directory = job.directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            DispatchQueue.main.async { [weak self] in
                self?.resumePoints.removeValue(forKey: job.key)
                self?.finish(job, taskID: taskID)
            }
        } catch DownloadError.temporary {
            let request = downloadTask.originalRequest ?? downloadTask.currentRequest
            DispatchQueue.main.async { [weak self] in
                self?.interrupted(job, taskID: taskID, resumeData: nil, request: request)
            }
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in
                self?.finish(job, taskID: taskID, failure: message)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = DownloadJob.decode(task) else { return }
        let taskID = task.taskIdentifier
        let message = error.map { ($0 as NSError).code == NSURLErrorCancelled ? nil : $0.localizedDescription } ?? nil
        let resumeData = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.pausing.remove(taskID) != nil {
                self.finish(job, taskID: taskID)
            } else if resumeData != nil || Self.isLostConnection(error) {
                self.interrupted(job, taskID: taskID, resumeData: resumeData,
                                 request: task.originalRequest ?? task.currentRequest)
            } else {
                self.finish(job, taskID: taskID, failure: message)
            }
        }
    }

    /// The server or the way to it went away; worth trying again later.
    nonisolated static func isLostConnection(_ error: Error?) -> Bool {
        guard let error = error as NSError?, error.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                NSURLErrorSecureConnectionFailed, NSURLErrorBadServerResponse].contains(error.code)
    }

    /// Interrupted downloads continue once the app reaches the server again.
    func resumeInterrupted(scope: String, request: (Media) throws -> URLRequest) async {
        restore()
        await restored?.value
        for entry in paused.values where entry.job.scope == scope && entry.interrupted == true {
            guard let request = try? request(entry.job.media) else { continue }
            try? await resume(scope: scope, id: entry.job.media.id, request: request)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                               completionHandler: @escaping (URLRequest?) -> Void) {
        // Defense in depth for sessions delivering redirect callbacks.
        // The deployed download endpoint itself serves files without redirects.
        completionHandler(nil)
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.notify()
            self?.backgroundCompletion?()
            self?.backgroundCompletion = nil
        }
    }
}
