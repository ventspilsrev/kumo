import Combine
import Foundation
import UIKit

/// In-app log. There is no debugger on the iPad, so everything that goes wrong
/// is written here, kept on disk, and shown on the Log tab for screenshots.
final class Log: ObservableObject {
    static let shared = Log()

    struct Entry: Identifiable {
        let id: Int
        let time: String
        let level: String
        let text: String
    }

    @Published private(set) var entries: [Entry] = []
    /// Last lines of the previous run, set only if that run did not end cleanly.
    private(set) var previousCrashTail: String?

    private var counter = 0
    private let fileURL: URL
    private let flagURL: URL
    private let ioQueue = DispatchQueue(label: "kumo.log")
    private let formatter: DateFormatter

    private init() {
        let dir = AppPaths.support
        fileURL = dir.appendingPathComponent("log.txt")
        flagURL = dir.appendingPathComponent("running.flag")
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        let fm = FileManager.default
        // The flag file exists while the app is in the foreground. If it is
        // still there at launch, the last run was killed or crashed.
        if fm.fileExists(atPath: flagURL.path),
           let old = try? String(contentsOf: fileURL, encoding: .utf8) {
            previousCrashTail = String(old.suffix(3000))
        }
        // Keep the file small: start fresh when it is over 300 KB.
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > 300_000 {
            try? fm.removeItem(at: fileURL)
        }
        fm.createFile(atPath: flagURL.path, contents: Data())

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [flagURL] _ in
            try? FileManager.default.removeItem(at: flagURL)
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [flagURL] _ in
            FileManager.default.createFile(atPath: flagURL.path, contents: Data())
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            Log.warn("iOS sent a memory warning")
        }
        add("info", "=== launch ===")
    }

    func add(_ level: String, _ text: String) {
        let time = formatter.string(from: Date())
        let line = "\(time) [\(level)] \(text)\n"
        ioQueue.async { [fileURL] in
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
        DispatchQueue.main.async {
            self.counter += 1
            self.entries.append(Entry(id: self.counter, time: time, level: level, text: text))
            if self.entries.count > 500 { self.entries.removeFirst(self.entries.count - 500) }
        }
    }

    func clear() {
        entries.removeAll()
        previousCrashTail = nil
        ioQueue.async { [fileURL] in try? FileManager.default.removeItem(at: fileURL) }
    }

    var allText: String {
        entries.map { "\($0.time) [\($0.level)] \($0.text)" }.joined(separator: "\n")
    }

    static func info(_ text: String) { shared.add("info", text) }
    static func warn(_ text: String) { shared.add("warn", text) }
    static func error(_ text: String) { shared.add("error", text) }
}

/// Folders the app writes to. Everything is inside the app's own sandbox.
enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Kumo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let caches: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Kumo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
