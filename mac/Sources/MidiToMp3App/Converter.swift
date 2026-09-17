import Foundation
import MidiToMp3Core

enum ExportFormat: String, CaseIterable, Identifiable {
    case m4a = "Apple Lossless-ish AAC (.m4a)"
    case wav = "WAV (.wav)"

    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .m4a: return "m4a"
        case .wav: return "wav"
        }
    }
}

enum Converter {
    /// Convert one MIDI file. Progress 0...1 is reported through `progress`.
    static func convert(
        midURL: URL,
        samples: [PianoSample],
        transpose: Int,
        tempo: Double,
        format: ExportFormat,
        outputDirectory: URL,
        progress: AsyncStream<Double>.Continuation
    ) async throws -> URL {
        let data = try Data(contentsOf: midURL)
        var song = try parseMidi(data)
        song = transposed(song, by: transpose)
        song = spedUp(song, by: tempo)
        guard !song.notes.isEmpty else {
            throw NSError(domain: "MidiToMp3", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No playable notes found."])
        }
        progress.yield(0.05)

        let (inner, innerCont) = AsyncStream<Double>.makeStream()
        let forward = Task {
            for await f in inner { progress.yield(0.05 + 0.85 * f) }
        }
        let rendered = await Task.detached {
            let r = renderSamples(
                notes: song.notes,
                duration: song.duration,
                samples: samples,
                progress: innerCont
            )
            innerCont.finish()
            return r
        }.value
        await forward.value
        progress.yield(0.92)

        let base = midURL.deletingPathExtension().lastPathComponent
        let out = outputDirectory.appendingPathComponent(base).appendingPathExtension(format.fileExtension)
        let (left, right) = rendered
        try await Task.detached {
            switch format {
            case .m4a:
                try writeM4A(left: left, right: right, sampleRate: 44_100, to: out)
            case .wav:
                try writeWAV(left: left, right: right, sampleRate: 44_100, to: out)
            }
        }.value
        progress.yield(1.0)
        progress.finish()
        return out
    }
}
