import Darwin
import Foundation
import OSLog

final class DiagnosticLog {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ScreenSwitch", isDirectory: true)
    #if DEBUG
    static var checkDirectory: URL?
    static let shared = DiagnosticLog(directory: checkDirectory ?? directory)
    #else
    static let shared = DiagnosticLog(directory: directory)
    #endif

    private let directory: URL
    private let maximumBytes: Int
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()
    private let logger = Logger(subsystem: "local.ScreenSwitch", category: "LogFile")

    init(directory: URL, maximumBytes: Int = 1_048_576) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let descriptor = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_WRONLY, 0o600)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
            defer { flock(descriptor, LOCK_UN) }
            let file = directory.appendingPathComponent("ScreenSwitch.log")
            let line = "\(formatter.string(from: Date())) pid=\(ProcessInfo.processInfo.processIdentifier) \(message)\n"
            let data = Data(line.utf8)
            if manager.fileExists(atPath: file.path) {
                let size = (try manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                if size + data.count > maximumBytes {
                    let oldest = directory.appendingPathComponent("ScreenSwitch.2.log")
                    if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
                    let previous = directory.appendingPathComponent("ScreenSwitch.1.log")
                    if manager.fileExists(atPath: previous.path) { try manager.moveItem(at: previous, to: oldest) }
                    try manager.moveItem(at: file, to: previous)
                }
            }
            if !manager.fileExists(atPath: file.path) {
                guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { handle.closeFile() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            logger.error("Diagnostic log write failed: \(error.localizedDescription, privacy: .public)")
            fputs("ScreenSwitch diagnostic log write failed: \(error.localizedDescription)\n", stderr)
        }
    }
}
