import Foundation
import MidiToMp3Core

/// Downloads the Salamander grand samples on first launch (into Application
/// Support) and keeps them loaded for conversions.
@MainActor
final class SampleManager: ObservableObject {
    enum Status: Equatable {
        case idle
        case working(String)
        case progress(Double)
        case ready
        case failed(String)
    }

    @Published var status: Status = .idle

    private var cached: [PianoSample]?

    var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MidiToMp3/salamander", isDirectory: true)
    }

    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    func samples() async throws -> [PianoSample] {
        if let c = cached { return c }
        let dir = directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !allPresent(in: dir) {
            try await downloadSamples(into: dir)
        }
        status = .working("Loading piano…")
        let loaded: [PianoSample] = try await Task.detached {
            try loadPianoSamples(from: dir)
        }.value
        cached = loaded
        status = .ready
        return loaded
    }

    func check() async {
        if cached != nil { status = .ready; return }
        let present = allPresent(in: directory)
        status = present ? .idle : .idle // idle banner offers the download
    }

    private func allPresent(in dir: URL) -> Bool {
        let fm = FileManager.default
        return salamanderSampleNames.allSatisfy { def in
            fm.fileExists(atPath: dir.appendingPathComponent(def.name + ".wav").path)
        }
    }

    private func downloadSamples(into dir: URL) async throws {
        let total = salamanderSampleNames.count
        for (i, def) in salamanderSampleNames.enumerated() {
            status = .progress(Double(i) / Double(total))
            let mp3URL = URL(string: "https://tonejs.github.io/audio/salamander/\(def.name).mp3")!
            let (data, _) = try await URLSession.shared.data(from: mp3URL)
            let mp3 = dir.appendingPathComponent(def.name + ".mp3")
            let wav = dir.appendingPathComponent(def.name + ".wav")
            try data.write(to: mp3)
            try await Task.detached {
                try Self.decode(mp3: mp3, wav: wav)
            }.value
            try? FileManager.default.removeItem(at: mp3)
        }
        status = .progress(1.0)
    }

    nonisolated private static func decode(mp3: URL, wav: URL) throws {
        let afconvert = URL(fileURLWithPath: "/usr/bin/afconvert")
        let proc = Process()
        if FileManager.default.isExecutableFile(atPath: afconvert.path) {
            proc.executableURL = afconvert
            proc.arguments = ["-f", "WAVE", "-d", "LEI16@44100", mp3.path, wav.path]
        } else if let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        {
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = ["-y", "-loglevel", "error", "-i", mp3.path,
                              "-ar", "44100", "-ac", "2", "-c:a", "pcm_s16le", wav.path]
        } else {
            throw NSError(domain: "MidiToMp3", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Need /usr/bin/afconvert or ffmpeg to decode samples."])
        }
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "MidiToMp3", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Sample decode failed."])
        }
    }
}
