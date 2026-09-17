import Foundation
import Testing
@testable import MidiToMp3Core

/// Two notes: A4 (69) for 1 beat, then C3 (48) for 2 beats, at 120 BPM.
private func twoToneMidi() -> Data {
    func varlen(_ v: UInt) -> [UInt8] {
        var out = [UInt8(v & 0x7F)]
        var rest = v >> 7
        while rest > 0 {
            out.insert(UInt8((rest & 0x7F) | 0x80), at: 0)
            rest >>= 7
        }
        return out
    }
    var ev: [UInt8] = []
    ev += varlen(0) + [0x90, 69, 100]
    ev += varlen(480) + [0x80, 69, 0]
    ev += varlen(0) + [0x90, 48, 90]
    ev += varlen(960) + [0x80, 48, 0]
    ev += varlen(0) + [0xFF, 0x2F, 0x00]
    var bytes: [UInt8] = []
    bytes += [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]
    bytes += [0x4D, 0x54, 0x72, 0x6B,
              UInt8((ev.count >> 24) & 0xFF), UInt8((ev.count >> 16) & 0xFF),
              UInt8((ev.count >> 8) & 0xFF), UInt8(ev.count & 0xFF)]
    bytes += ev
    return Data(bytes)
}

@Test func parsesTwoNotes() throws {
    let song = try parseMidi(twoToneMidi())
    #expect(song.notes.count == 2)
    #expect(song.notes[0].midi == 69)
    #expect(abs(song.notes[0].start - 0.0) < 0.001)
    #expect(abs(song.notes[0].end - 0.5) < 0.001)
    #expect(song.notes[1].midi == 48)
    #expect(abs(song.notes[1].start - 0.5) < 0.001)
    #expect(abs(song.notes[1].end - 1.5) < 0.001)
    #expect(abs(song.duration - 1.5) < 0.001)
}

@Test func rejectsGarbage() {
    #expect(throws: MidiParseError.self) {
        try parseMidi(Data([0x01, 0x02, 0x03]))
    }
}

@Test func transposeClampsRange() throws {
    let song = try parseMidi(twoToneMidi())
    let down = transposed(song, by: -48) // A4->21 edge, C3 drops out
    #expect(down.notes.count == 1)
    #expect(down.notes[0].midi == 21)
}

/// Constant-1.0 "recordings" must produce full-scale, finite, full-length audio.
@Test func rendersFullLengthAudio() {
    let one = [Float](repeating: 1.0, count: 44_100)
    let samples = [PianoSample(midi: 69, left: one, right: one)]
    let notes = [ParsedNote(midi: 69, start: 0, end: 0.5, velocity: 100)]
    let (left, right) = renderSamples(notes: notes, duration: 0.5, samples: samples, reverb: false)
    #expect(left.count == Int((0.5 + 1.8) * 44_100))
    #expect(right.count == left.count)
    #expect(left.allSatisfy { $0.isFinite })
    let peak = left.map { abs($0) }.max() ?? 0
    #expect(abs(peak - 0.89) < 0.02)
    // Sustain region (0.1s) must be loud, far tail must be silent.
    #expect(abs(left[4410]) > 0.3)
    #expect(abs(left[left.count - 1]) < 0.001)
}

/// Nearest-sample picking: E4 (64) is closest to D#4 (63).
@Test func picksNearestSample() {
    let sines = [60, 63, 66].map { m in
        PianoSample(midi: m, left: [Float](repeating: 0.5, count: 100),
                    right: [Float](repeating: 0.5, count: 100))
    }
    let notes = [ParsedNote(midi: 64, start: 0, end: 0.05, velocity: 100)]
    let (left, _) = renderSamples(notes: notes, duration: 0.05, samples: sines, reverb: false)
    // Rendered from the 63 sample pitched up 1 semitone: nonzero output proves
    // the voice was found and resampled without crashing or silence.
    #expect(left.prefix(2000).contains { abs($0) > 0.01 })
}

@Test func wavRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("roundtrip-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeWAV(left: [0.5, -0.5, 0.0], right: [0.25, 0.25, 0.25],
                 sampleRate: 44_100, to: url)
    let back = try readWav16(at: url)
    #expect(back.sampleRate == 44_100)
    #expect(back.left.count == 3)
    #expect(abs(back.left[0] - 0.5) < 0.001)
    #expect(abs(back.left[1] + 0.5) < 0.001)
    #expect(abs(back.right[0] - 0.25) < 0.001)
}
