// Recorder — a thin supervisor for the EXISTING cmd/recorder binary.
//
// The recorder is not reimplemented here. This app is a second front door onto
// the same proven pipeline the Claude/CLI flow uses, and it speaks the same
// contract src/cli.ts does:
//
//   recorder <windowID> <durationSeconds> <outputPath>
//   env RECORDER_BG_IMAGE=<path to background>
//   duration 0 = open-ended, stop with SIGTERM (5-minute safety cap is built in)

import AppKit
import Foundation

@MainActor
final class Recorder {
    enum StartError: LocalizedError {
        case binaryMissing(String)

        var errorDescription: String? {
            switch self {
            case let .binaryMissing(path):
                return "recorder binary missing at \(path) — run `pnpm run build:recorder`"
            }
        }
    }

    private var process: Process?
    private(set) var outputURL: URL?
    private(set) var startedAt: Date?

    /// Called on the main actor when the recorder exits, with its status code.
    var onExit: (Int32) -> Void = { _ in }

    var isRunning: Bool { process?.isRunning ?? false }
    var elapsed: TimeInterval { startedAt.map { -$0.timeIntervalSinceNow } ?? 0 }

    // MARK: - Repo layout

    /// Only meaningful for dev builds run from inside the checkout. An installed
    /// app in /Applications has no repo, which is exactly why the bundled copies
    /// below are consulted first.
    static var repoRoot: URL {
        if let override = ProcessInfo.processInfo.environment["STAGE_STUDIO_ROOT"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.bundleURL
            .deletingLastPathComponent()  // build/
            .deletingLastPathComponent()  // app/
            .deletingLastPathComponent()  // <repo>
    }

    /// Bundled copy first, checkout second.
    ///
    /// The app's permanent home is /Applications, so it cannot depend on a
    /// checkout that may be moved or deleted — `build.sh` embeds the recorder in
    /// `Contents/MacOS/`. The repo fallback keeps a dev build working when the
    /// helper hasn't been built into the bundle yet.
    static var binaryURL: URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/recorder")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return repoRoot.appendingPathComponent("cmd/recorder/recorder")
    }

    /// Same default background the CLI uses, so both front doors produce clips
    /// that look like they came from the same tool.
    static var backgroundImageURL: URL? {
        let fm = FileManager.default
        if let bundled = Bundle.main.url(forResource: "big-sur-graphic", withExtension: "jpg"),
           fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        let url = repoRoot.appendingPathComponent("assets/big-sur-graphic.jpg")
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    static func defaultOutputURL(now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        return desktop.appendingPathComponent("recording-\(formatter.string(from: now)).mp4")
    }

    // MARK: - Lifecycle

    func start(windowID: CGWindowID, output: URL) throws {
        let binary = Self.binaryURL
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw StartError.binaryMissing(binary.path)
        }

        let task = Process()
        task.executableURL = binary
        // duration 0 = open-ended; we own the stop.
        task.arguments = [String(windowID), "0", output.path]

        var env = ProcessInfo.processInfo.environment
        env["RECORDER_BG_IMAGE"] = Self.backgroundImageURL?.path ?? ""
        task.environment = env

        task.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.process = nil
                self.onExit(status)
            }
        }

        try task.run()
        process = task
        outputURL = output
        startedAt = Date()
        note("recorder started (pid \(task.processIdentifier)) → \(output.path)")
    }

    /// Clean finalize — the same SIGTERM path the Claude flow uses.
    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    /// Abort: stop the recorder AND remove the partial file. A cancelled take
    /// must leave nothing behind, or the Desktop fills with junk that looks like
    /// real recordings.
    func cancel() {
        onExit = { _ in }
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        self.process = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
            note("cancelled — removed \(outputURL.lastPathComponent)")
        }
        outputURL = nil
        startedAt = nil
    }
}
