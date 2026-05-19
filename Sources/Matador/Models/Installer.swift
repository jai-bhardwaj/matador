import Foundation
import AppKit

/// Handles the full in-app update flow:
///   download → mount → stage → spawn detached swap helper → quit
///
/// The swap helper waits for our PID to exit, replaces /Applications/Matador.app
/// with the staged copy, then relaunches. Same pattern Sparkle uses, without
/// the dependency.
@MainActor
@Observable
final class Installer {
    enum Phase: Equatable {
        case idle
        case downloading(progress: Double, bytesDone: Int64, bytesTotal: Int64)
        case mounting
        case staging
        case relaunching
        case failed(String)

        var isWorking: Bool {
            if case .idle = self { return false }
            if case .failed = self { return false }
            return true
        }
    }

    var phase: Phase = .idle

    func install(version: String, from urlString: String) async {
        phase = .downloading(progress: 0, bytesDone: 0, bytesTotal: 0)
        guard let url = URL(string: urlString) else {
            phase = .failed("Invalid download URL")
            return
        }
        do {
            let dmg = try await downloadDMG(version: version, from: url)
            phase = .mounting
            let mountPoint = try mountDMG(dmg)
            phase = .staging
            let staged: URL
            do {
                staged = try copyAppToStaging(from: mountPoint)
            } catch {
                _ = try? detachDMG(mountPoint)
                throw error
            }
            _ = try? detachDMG(mountPoint)

            try spawnSwapHelper(stagedApp: staged)
            phase = .relaunching
            // Terminate immediately — the helper is already polling for our PID
            // to disappear and will swap+launch the moment we're gone.
            NSApplication.shared.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Download
    //
    // URLSessionDownloadDelegate gives us native chunked transfers + progress
    // callbacks from the system networking stack — no per-byte async overhead.

    private func downloadDMG(version: String, from url: URL) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Matador-\(version)-\(UUID().uuidString).dmg")
        try? FileManager.default.removeItem(at: dest)

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let delegate = DownloadProgressDelegate { [weak self] done, total in
            guard let self = self else { return }
            // Apple already throttles delegate callbacks to roughly per-chunk
            // boundaries, but cap UI churn anyway.
            Task { @MainActor in
                let progress = total > 0 ? Double(done) / Double(total) : 0
                self.phase = .downloading(progress: progress, bytesDone: done, bytesTotal: total)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let tempURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            delegate.onFinish = { result in
                switch result {
                case .success(let url): cont.resume(returning: url)
                case .failure(let err): cont.resume(throwing: err)
                }
            }
            let task = session.downloadTask(with: request)
            task.resume()
        }

        // Move out of system-managed temp before the delegate's location dies.
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    // MARK: Mount / detach

    private func mountDMG(_ dmgPath: URL) throws -> URL {
        let task = Process()
        task.launchPath = "/usr/bin/hdiutil"
        task.arguments = ["attach", dmgPath.path, "-nobrowse", "-readonly", "-plist"]
        let pipe = Pipe()
        let err = Pipe()
        task.standardOutput = pipe
        task.standardError = err
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallerError.mount("hdiutil attach failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw InstallerError.mount("Could not parse hdiutil plist output")
        }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String {
                return URL(fileURLWithPath: mountPoint)
            }
        }
        throw InstallerError.mount("DMG mounted but no mount-point reported")
    }

    @discardableResult
    private func detachDMG(_ mountPoint: URL) throws -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/hdiutil"
        task.arguments = ["detach", mountPoint.path, "-quiet"]
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // MARK: Stage

    private func copyAppToStaging(from mountPoint: URL) throws -> URL {
        let source = mountPoint.appendingPathComponent("Matador.app")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw InstallerError.stage("Matador.app not found inside DMG")
        }
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("Matador-staging-\(UUID().uuidString).app")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: source, to: staged)
        // Strip quarantine so the launched copy doesn't trigger Gatekeeper.
        let xattr = Process()
        xattr.launchPath = "/usr/bin/xattr"
        xattr.arguments = ["-cr", staged.path]
        try? xattr.run()
        xattr.waitUntilExit()
        return staged
    }

    // MARK: Swap helper
    //
    // Writes a tiny bash script to /tmp, launches it detached, and lets it
    // outlive us. It polls for our PID to disappear, then does the file swap
    // and `open`s the new .app. We `terminate` immediately after.

    private func spawnSwapHelper(stagedApp: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let destApp = "/Applications/Matador.app"
        let logPath = "/tmp/matador-installer.log"

        let script = #"""
        #!/bin/bash
        set -u
        LOG="\#(logPath)"
        echo "[$(date)] swap helper start pid=\#(pid)" >> "$LOG"

        # Tighter poll: 50ms × 600 iters = 30s ceiling. Typical exit is well
        # under 200ms after NSApplication.terminate runs the teardown.
        for i in $(seq 1 600); do
            if ! kill -0 \#(pid) 2>/dev/null; then
                break
            fi
            /bin/sleep 0.05
        done
        if kill -0 \#(pid) 2>/dev/null; then
            echo "[$(date)] parent still alive after 30s, force-killing" >> "$LOG"
            kill -9 \#(pid) 2>/dev/null || true
            /bin/sleep 0.2
        fi

        if [ -d "\#(destApp)" ]; then
            rm -rf "\#(destApp)" >> "$LOG" 2>&1
        fi
        mv "\#(stagedApp.path)" "\#(destApp)" >> "$LOG" 2>&1
        /usr/bin/xattr -cr "\#(destApp)" >> "$LOG" 2>&1 || true
        echo "[$(date)] launching new app" >> "$LOG"
        /usr/bin/open "\#(destApp)" >> "$LOG" 2>&1
        rm -f "$0"
        """#

        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("matador-install-\(UUID().uuidString).sh")
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = [scriptPath.path]
        // Detach so the helper outlives this process.
        task.standardInput = nil
        task.standardOutput = nil
        task.standardError = nil
        try task.run()
        // Intentionally do not wait — let it run in the background.
    }
}

enum InstallerError: LocalizedError {
    case io(String)
    case mount(String)
    case stage(String)

    var errorDescription: String? {
        switch self {
        case .io(let m): return m
        case .mount(let m): return m
        case .stage(let m): return m
        }
    }
}

// MARK: - URLSessionDownloadDelegate wrapper

final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Called from the URLSession delegate queue (background) — caller is
    /// responsible for hopping back to the main actor.
    let onProgress: (Int64, Int64) -> Void
    /// One-shot terminal callback. On success the URL is the system-managed
    /// temp file — the caller has to move it before the delegate returns.
    var onFinish: ((Result<URL, Error>) -> Void)?

    private var movedDest: URL?

    init(onProgress: @escaping (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The downloaded file is at `location`. We must move it before this
        // method returns or the system will delete it.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("matador-dl-\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: location, to: staging)
            movedDest = staging
        } catch {
            onFinish?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            onFinish?(.failure(error))
            return
        }
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            onFinish?(.failure(InstallerError.io("HTTP \(http.statusCode) downloading DMG")))
            return
        }
        if let url = movedDest {
            onFinish?(.success(url))
        } else {
            onFinish?(.failure(InstallerError.io("Download finished with no file")))
        }
    }
}

// MARK: - Byte formatting helper for the UI

extension Int64 {
    var prettyBytes: String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(self)
        var idx = 0
        while value >= 1024, idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        return String(format: idx == 0 ? "%.0f %@" : "%.1f %@", value, units[idx])
    }
}
