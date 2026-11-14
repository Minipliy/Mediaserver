import Foundation
import UIKit

private struct RegressionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private enum DownloadRegression {
    private static let files = FileManager.default

    static func run() async throws {
        try checkFiles()
        try checkStorage()
        try await checkLifecycle()
        try await checkCancelledStart()
        try checkPausedFiles()
        try await checkPauseLifecycle()
    }

    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw RegressionFailure(message: message) }
    }

    private static func freshScope() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func media(id: String = String(repeating: "b", count: 64), bytes: UInt64 = 3) -> Media {
        Media(id: id, path: "Music/demo.mp3", name: "demo.mp3", kind: "audio", title: "Demo",
              artist: nil, album: nil, duration: nil, bytes: bytes, modified: 1)
    }

    private static func checkFiles() throws {
        let directory = files.temporaryDirectory.appendingPathComponent("download-files-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let job = DownloadJob(scope: freshScope(), media: media())
        let record = OfflineRecord(media: job.media, filename: job.filename)
        try require(DownloadJob.validIdentifier(job.scope), "Valid identifier rejected")
        for invalid in [String(repeating: "A", count: 64), String(repeating: "a", count: 63),
                        "../" + String(repeating: "b", count: 61), String(repeating: "ａ", count: 64)] {
            try require(!DownloadJob.validIdentifier(invalid), "Invalid identifier accepted")
        }
        let target = directory.appendingPathComponent(job.filename)
        try Data("old".utf8).write(to: target)
        try require(DownloadJob.localURL(for: record, in: directory) == target, "Valid offline file rejected")
        let traversal = OfflineRecord(media: job.media, filename: "../outside.mp3")
        try require(DownloadJob.localURL(for: traversal, in: directory) == nil, "Traversal filename accepted")
        let truncated = OfflineRecord(media: media(bytes: 4), filename: job.filename)
        try require(DownloadJob.localURL(for: truncated, in: directory) == nil, "Truncated file accepted")
        try files.removeItem(at: target)
        let outside = directory.appendingPathComponent("outside.mp3")
        try Data("old".utf8).write(to: outside)
        try files.createSymbolicLink(at: target, withDestinationURL: outside)
        try require(DownloadJob.localURL(for: record, in: directory) == nil, "Symbolic link accepted")
        try files.removeItem(at: target)
        try files.createDirectory(at: target, withIntermediateDirectories: false)
        try require(DownloadJob.localURL(for: record, in: directory) == nil, "Directory accepted as media file")
        try files.removeItem(at: target)
        try Data().write(to: target)
        let empty = OfflineRecord(media: media(bytes: 0), filename: job.filename)
        try require(DownloadJob.localURL(for: empty, in: directory) != nil, "Valid empty file rejected")
        print("PASS: identifiers, filenames, file size, symbolic links and regular-file validation")
    }

    private static func checkStorage() throws {
        let job = DownloadJob(scope: freshScope(), media: media())
        let incoming = files.temporaryDirectory.appendingPathComponent("download-incoming-\(UUID().uuidString)")
        try files.createDirectory(at: job.directory, withIntermediateDirectories: true)
        defer {
            try? files.removeItem(at: job.directory)
            try? files.removeItem(at: incoming)
        }
        let target = job.directory.appendingPathComponent(job.filename)
        try Data("old".utf8).write(to: target)
        try Data("new".utf8).write(to: incoming)
        try job.storeDownload(from: incoming)
        try require((try? Data(contentsOf: target)) == Data("new".utf8), "Successful save did not replace media")
        let metadata = try Data(contentsOf: job.recordURL)
        let saved = try JSONDecoder().decode(OfflineRecord.self, from: metadata)
        try require(saved.media.id == job.media.id && saved.filename == job.filename, "Saved metadata mismatch")

        let missing = files.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        do {
            try job.storeDownload(from: missing)
            throw RegressionFailure(message: "Missing source unexpectedly saved")
        } catch is RegressionFailure { throw RegressionFailure(message: "Missing source unexpectedly saved") }
        catch {}
        try require((try? Data(contentsOf: target)) == Data("new".utf8), "Previous copy lost after media move failed")
        try require((try? Data(contentsOf: job.recordURL)) == metadata, "Metadata changed after media move failed")

        // A directory at the record path forces its atomic write to fail.
        try files.removeItem(at: job.recordURL)
        try files.createDirectory(at: job.recordURL, withIntermediateDirectories: false)
        try Data("bad".utf8).write(to: incoming)
        do {
            try job.storeDownload(from: incoming)
            throw RegressionFailure(message: "Metadata failure unexpectedly succeeded")
        } catch is RegressionFailure { throw RegressionFailure(message: "Metadata failure unexpectedly succeeded") }
        catch {}
        try require((try? Data(contentsOf: target)) == Data("new".utf8), "Previous copy lost after metadata write failed")

        try files.removeItem(at: target)
        try Data("bad".utf8).write(to: incoming)
        do {
            try job.storeDownload(from: incoming)
            throw RegressionFailure(message: "First-time metadata failure unexpectedly succeeded")
        } catch is RegressionFailure { throw RegressionFailure(message: "First-time metadata failure unexpectedly succeeded") }
        catch {}
        try require(!files.fileExists(atPath: target.path), "Unlisted media remained after metadata write failed")
        print("PASS: successful save, replacement rollback, metadata preservation and orphan cleanup")
    }

    private static func flushDelegateEvents() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func checkLifecycle() async throws {
        let manager = DownloadManager()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let job = DownloadJob(scope: freshScope(), media: media(bytes: 100))
        let description = String(decoding: try JSONEncoder().encode(job), as: UTF8.self)
        let first = session.downloadTask(with: URL(string: "https://example.invalid/one")!)
        let second = session.downloadTask(with: URL(string: "https://example.invalid/two")!)
        first.taskDescription = description
        second.taskDescription = description
        try require(DownloadJob.decode(first)?.key == job.key, "Download task restoration failed")
        manager.urlSession(session, downloadTask: first, didWriteData: 10, totalBytesWritten: 10, totalBytesExpectedToWrite: 100)
        await flushDelegateEvents()
        try require(manager.active[job.key]?.fraction == 0.1, "Progress event was not registered")
        manager.urlSession(session, task: first, didCompleteWithError: URLError(.cancelled))
        await flushDelegateEvents()
        try require(manager.active.isEmpty && manager.takeFailure(scope: job.scope) == nil, "Cancelled transfer was not silently removed")
        manager.urlSession(session, downloadTask: first, didWriteData: 10, totalBytesWritten: 20, totalBytesExpectedToWrite: 100)
        await flushDelegateEvents()
        try require(manager.active.isEmpty, "Late progress resurrected a finished transfer")
        manager.urlSession(session, downloadTask: second, didWriteData: 10, totalBytesWritten: 10, totalBytesExpectedToWrite: 100)
        await flushDelegateEvents()
        manager.urlSession(session, task: first, didCompleteWithError: nil)
        await flushDelegateEvents()
        try require(manager.active[job.key]?.fraction == 0.1, "Old completion removed a restarted transfer")
        manager.urlSession(session, downloadTask: second, didWriteData: 140, totalBytesWritten: 150, totalBytesExpectedToWrite: 100)
        await flushDelegateEvents()
        try require(manager.active[job.key]?.fraction == 1, "Displayed progress exceeded 100 percent")
        manager.urlSession(session, task: second, didCompleteWithError: URLError(.timedOut))
        await flushDelegateEvents()
        try require(manager.active.isEmpty && manager.takeFailure(scope: job.scope) != nil, "Transfer failure was not reported")
        print("PASS: task restoration, cancellation, late callbacks, progress bounds and failure reporting")
    }

    private static func checkPausedFiles() throws {
        let root = files.temporaryDirectory.appendingPathComponent("paused-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let job = DownloadJob(scope: freshScope(), media: media(bytes: 1000))
        let entry = PausedDownload(job: job, fraction: 0.25, resumeData: Data("resume".utf8))
        try require(entry.remainingBytes == 750, "Remaining bytes of a paused download are wrong")
        let folder = root.appendingPathComponent(job.scope, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = try JSONEncoder().encode(entry)
        try saved.write(to: folder.appendingPathComponent(job.media.id + ".paused.json"))
        let loaded = PausedDownload.loadAll(root: root)
        try require(loaded.count == 1 && loaded[0].resumeData == entry.resumeData && loaded[0].fraction == 0.25, "Paused download did not survive a restart")
        try saved.write(to: folder.appendingPathComponent("other.paused.json"))
        let foreign = root.appendingPathComponent(freshScope(), isDirectory: true)
        try files.createDirectory(at: foreign, withIntermediateDirectories: true)
        try saved.write(to: foreign.appendingPathComponent(job.media.id + ".paused.json"))
        try Data("kaputt".utf8).write(to: folder.appendingPathComponent(String(repeating: "c", count: 64) + ".paused.json"))
        try require(PausedDownload.loadAll(root: root).count == 1, "Renamed, moved or damaged paused file was accepted")
        print("PASS: paused downloads persist and invalid files are ignored")
    }

    private static func checkPauseLifecycle() async throws {
        let manager = DownloadManager()
        let job = DownloadJob(scope: freshScope(), media: media(bytes: 1000))
        defer { try? files.removeItem(at: job.directory) }
        let entry = PausedDownload(job: job, fraction: 0.5, resumeData: nil)
        manager.keepPaused(entry)
        try require(files.fileExists(atPath: entry.fileURL.path) && manager.paused[job.key] != nil, "Pause was not stored")
        let request = URLRequest(url: URL(string: "https://example.invalid/download")!)
        try await manager.start(media: job.media, scope: job.scope, request: request)
        try require(manager.active[job.key] == nil, "A paused download was started a second time")
        try await manager.resume(scope: job.scope, id: job.media.id, request: request)
        try require(manager.active[job.key]?.fraction == 0.5 && manager.paused[job.key] == nil && !files.fileExists(atPath: entry.fileURL.path),
                    "Resume did not move the download back to active")
        await manager.cancel(scope: job.scope, id: job.media.id)
        manager.keepPaused(entry)
        await manager.cancel(scope: job.scope, id: job.media.id)
        try require(manager.paused[job.key] == nil && !files.fileExists(atPath: entry.fileURL.path), "Cancel did not remove a paused download")
        manager.keepPaused(entry)
        await manager.cancelAll(scope: job.scope)
        try require(manager.paused[job.key] == nil, "Disconnect did not remove paused downloads")
        print("PASS: pause, resume and cancel of stored downloads")
    }

    private static func checkCancelledStart() async throws {
        let manager = DownloadManager()
        let scope = freshScope()
        let item = media()
        let job = DownloadJob(scope: scope, media: item)
        let request = URLRequest(url: URL(string: "https://example.invalid/download")!)
        do {
            try await manager.start(media: item, scope: scope, request: request, shouldStart: { false })
            throw RegressionFailure(message: "Disconnected start unexpectedly succeeded")
        } catch is CancellationError {}
        try require(manager.active.isEmpty && !files.fileExists(atPath: job.directory.path), "Disconnected start caused side effects")
        let cancelled = Task { @MainActor in try await manager.start(media: item, scope: scope, request: request) }
        cancelled.cancel()
        do {
            try await cancelled.value
            throw RegressionFailure(message: "Cancelled start unexpectedly succeeded")
        } catch is CancellationError {}
        try require(manager.active.isEmpty && !files.fileExists(atPath: job.directory.path), "Cancelled start caused side effects")
        await manager.cancelAll(scope: scope)
        print("PASS: disconnected and cancelled starts stop before filesystem or download side effects")
    }
}

@MainActor
private final class DownloadRegressionDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Task {
            do {
                try await DownloadRegression.run()
                print("MINIPLY_DOWNLOAD_REGRESSION_PASS")
                fflush(stdout)
                exit(0)
            } catch {
                print("MINIPLY_DOWNLOAD_REGRESSION_FAIL: \(error.localizedDescription)")
                fflush(stdout)
                exit(1)
            }
        }
        return true
    }
}

@main
private enum DownloadRegressionMain {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(DownloadRegressionDelegate.self))
    }
}
