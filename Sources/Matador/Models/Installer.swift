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
            // Give the helper a beat to start polling before we exit.
            try? await Task.sleep(nanoseconds: 250_000_000)
            NSApplication.shared.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Download

    private func downloadDMG(version: String, from url: URL) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Matador-\(version)-\(UUID().uuidString).dmg")
        try? FileManager.default.removeItem(at: dest)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: dest.path) else {
            throw InstallerError.io("Could not open temp file for writing")
        }
        defer { try? handle.close() }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallerError.io("HTTP \(http.statusCode) downloading DMG")
        }
        let total = max(response.expectedContentLength, 0)

        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var written: Int64 = 0
        var lastEmit: TimeInterval = 0
        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                // Emit progress at most every 50ms to avoid flooding the UI
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastEmit > 0.05 {
                    lastEmit = now
                    let progress = total > 0 ? Double(written) / Double(total) : 0
                    self.phase = .downloading(progress: progress, bytesDone: written, bytesTotal: total)
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        self.phase = .downloading(progress: 1, bytesDone: written, bytesTotal: max(total, written))
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

        # Wait up to 30s for the parent app to exit.
        for i in $(seq 1 300); do
            if ! kill -0 \#(pid) 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        if kill -0 \#(pid) 2>/dev/null; then
            echo "[$(date)] parent still alive after 30s, force-killing" >> "$LOG"
            kill -9 \#(pid) 2>/dev/null || true
            sleep 0.3
        fi

        # Move out of the way, swap in, strip quarantine, launch.
        if [ -d "\#(destApp)" ]; then
            rm -rf "\#(destApp)" >> "$LOG" 2>&1
        fi
        mv "\#(stagedApp.path)" "\#(destApp)" >> "$LOG" 2>&1
        /usr/bin/xattr -cr "\#(destApp)" >> "$LOG" 2>&1 || true
        echo "[$(date)] launching new app" >> "$LOG"
        /usr/bin/open "\#(destApp)" >> "$LOG" 2>&1
        # Best-effort self-clean.
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
