import AppKit
import Foundation

/// Simple append-only log file that lives at ~/Library/Logs/Whale/whale.log.
/// Every entry is timestamped. The menu-bar "View Log" item opens this file.
enum DiagnosticLog {
    private static let logURL: URL = {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Whale")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("whale.log")
    }()

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]
        return f
    }()

    static func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    static func openInFinder() {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            log("Log file created.")
        }
        NSWorkspace.shared.open(logURL)
    }
}
