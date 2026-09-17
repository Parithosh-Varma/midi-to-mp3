import Foundation

/// One assembled piano note: MIDI pitch, start/end in seconds, velocity 1...127.
public struct ParsedNote: Sendable, Equatable {
    public var midi: Int
    public var start: Double
    public var end: Double
    public var velocity: Int

    public init(midi: Int, start: Double, end: Double, velocity: Int) {
        self.midi = midi
        self.start = start
        self.end = end
        self.velocity = velocity
    }
}

public struct ParsedSong: Sendable {
    public var notes: [ParsedNote]
    /// Length of the music in seconds (before ring-out tail).
    public var duration: Double
}

public enum MidiParseError: Error, LocalizedError {
    case notSMF
    case notMidiFile(String)
    case unsupportedFormat
    case truncated

    public var errorDescription: String? {
        switch self {
        case .notSMF: return "Not a Standard MIDI file."
        case let .notMidiFile(detail): return detail
        case .unsupportedFormat: return "Only MIDI format 0/1 files are supported."
        case .truncated: return "MIDI file is truncated."
        }
    }
}

/// Look at the first bytes and explain what the file actually is when it
/// is not a Standard MIDI File (dead download links saved as .mid are the
/// classic case — they are XML error pages).
private func sniffNonMidi(_ bytes: [UInt8]) -> MidiParseError {
    let head = String(bytes: bytes.prefix(64), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if head.hasPrefix("<") {
        if head.contains("NoSuchKey") || head.contains("<Error>") {
            return .notMidiFile("This is not a MIDI file — it is a download-error page saved with a .mid name (the link was dead). Please download the file again.")
        }
        return .notMidiFile("This is not a MIDI file — it looks like a web page saved with a .mid name. Please download the actual MIDI file.")
    }
    if head.hasPrefix("RIFF") {
        return .notMidiFile("This is a RIFF (.rmi) MIDI file, not a Standard MIDI (.mid) file. Re-export it as .mid and try again.")
    }
    if head.hasPrefix("ID3") || bytes.prefix(2).elementsEqual([0xFF, 0xFB]) {
        return .notMidiFile("This is an MP3 file, not a MIDI file.")
    }
    if head.hasPrefix("RIFF") == false, bytes.count < 14 {
        return .notMidiFile("This file is too small to be a MIDI file (\(bytes.count) bytes). The download probably failed.")
    }
    return .notSMF
}

private struct Reader {
    var bytes: [UInt8]
    var offset: Int = 0

    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw MidiParseError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16be() throws -> UInt {
        let hi = try u8(), lo = try u8()
        return UInt(hi) << 8 | UInt(lo)
    }

    mutating func u32be() throws -> UInt {
        let a = try u8(), b = try u8(), c = try u8(), d = try u8()
        return UInt(a) << 24 | UInt(b) << 16 | UInt(c) << 8 | UInt(d)
    }

    mutating func varlen() throws -> UInt {
        var v: UInt = 0
        for _ in 0..<4 {
            let c = try u8()
            v = (v << 7) | UInt(c & 0x7F)
            if c & 0x80 == 0 { return v }
        }
        throw MidiParseError.truncated
    }

    mutating func skip(_ n: Int) throws {
        guard remaining >= n else { throw MidiParseError.truncated }
        offset += n
    }

    func ascii(at: Int, length: Int) -> String {
        guard at + length <= bytes.count else { return "" }
        return String(bytes: bytes[at ..< at + length], encoding: .ascii) ?? ""
    }
}

private enum RawEvent {
    case on(channel: Int, pitch: Int, velocity: Int, abs: UInt)
    case off(channel: Int, pitch: Int, abs: UInt)
    case pedal(channel: Int, down: Bool, abs: UInt)
    case allOff(channel: Int, abs: UInt)

    var abs: UInt {
        switch self {
        case let .on(_, _, _, a): return a
        case let .off(_, _, a): return a
        case let .pedal(_, _, a): return a
        case let .allOff(_, a): return a
        }
    }
}

/// Parse a Standard MIDI File: tempo map, sustain pedal (CC64) and note
/// on/off assembly. Every track renders as piano.
public func parseMidi(_ data: Data) throws -> ParsedSong {
    var r = Reader(bytes: Array(data))
    guard r.ascii(at: 0, length: 4) == "MThd" else { throw sniffNonMidi(r.bytes) }
    r.offset = 4
    _ = try r.u32be() // header length
    let format = try r.u16be()
    let ntracks = try r.u16be()
    let division = try r.u16be()
    guard format != 2 else { throw MidiParseError.unsupportedFormat }
    guard division & 0x8000 == 0 else { throw MidiParseError.unsupportedFormat }
    let tpq = Double(division == 0 ? 480 : division)

    var tempos: [(abs: UInt, mpn: Double)] = [(0, 500_000)]
    var raw: [RawEvent] = []

    for _ in 0..<ntracks {
        guard r.ascii(at: r.offset, length: 4) == "MTrk" else { throw MidiParseError.notSMF }
        r.offset += 4
        let len = Int(try r.u32be())
        let end = r.offset + len
        guard end <= r.bytes.count else { throw MidiParseError.truncated }
        var abs: UInt = 0
        var status: UInt8 = 0
        while r.offset < end {
            abs += try r.varlen()
            let b = try r.u8()
            if b == 0xFF {
                let type = try r.u8()
                let mlen = Int(try r.varlen())
                if type == 0x51, mlen == 3 {
                    let mpn = Double(try r.u8()) * 65536 + Double(try r.u8()) * 256 + Double(try r.u8())
                    tempos.append((abs, mpn))
                } else {
                    try r.skip(mlen)
                }
            } else if b == 0xF0 || b == 0xF7 {
                try r.skip(Int(try r.varlen()))
            } else {
                if b & 0x80 != 0 {
                    status = b
                } else {
                    r.offset -= 1 // data byte: running status
                }
                let kind = status & 0xF0
                let ch = Int(status & 0x0F)
                switch kind {
                case 0x90, 0x80:
                    let pitch = Int(try r.u8()), vel = Int(try r.u8())
                    if kind == 0x90, vel > 0 {
                        raw.append(.on(channel: ch, pitch: pitch, velocity: vel, abs: abs))
                    } else {
                        raw.append(.off(channel: ch, pitch: pitch, abs: abs))
                    }
                case 0xA0:
                    try r.skip(2)
                case 0xB0:
                    let cc = Int(try r.u8()), val = Int(try r.u8())
                    if cc == 64 {
                        raw.append(.pedal(channel: ch, down: val >= 64, abs: abs))
                    } else if cc == 123 || cc == 120 {
                        raw.append(.allOff(channel: ch, abs: abs))
                    }
                case 0xC0, 0xD0:
                    try r.skip(1)
                case 0xE0:
                    try r.skip(2)
                default:
                    throw MidiParseError.notSMF
                }
            }
        }
        r.offset = end
    }

    tempos.sort { $0.abs < $1.abs }
    raw.sort { $0.abs < $1.abs }

    func ticksToSec(_ tick: UInt) -> Double {
        var sec = 0.0, lastAbs: UInt = 0, lastMpn = tempos[0].mpn
        for t in tempos.dropFirst() {
            if t.abs > tick { break }
            sec += Double(t.abs - lastAbs) * lastMpn / 1_000_000 / tpq
            lastAbs = t.abs
            lastMpn = t.mpn
        }
        return sec + Double(tick - lastAbs) * lastMpn / 1_000_000 / tpq
    }

    struct Open { var startAbs: UInt; var velocity: Int }
    func key(_ ch: Int, _ pitch: Int) -> Int { ch * 256 + pitch }

    var notes: [ParsedNote] = []
    var sounding: [Int: Open] = [:]
    var heldByPedal: [Int: Open] = [:]
    var pedal = [Bool](repeating: false, count: 16)

    func flush(_ k: Int, _ s: Open, _ abs: UInt, _ pitch: Int) {
        let start = ticksToSec(s.startAbs), end = ticksToSec(abs)
        if end > start {
            notes.append(ParsedNote(midi: pitch, start: start, end: end, velocity: s.velocity))
        }
    }

    for ev in raw {
        switch ev {
        case let .on(ch, pitch, vel, abs):
            let k = key(ch, pitch)
            if let prev = sounding[k] { flush(k, prev, abs, pitch) }
            if let sus = heldByPedal[k] {
                heldByPedal.removeValue(forKey: k)
                flush(k, sus, abs, pitch)
            }
            sounding[k] = Open(startAbs: abs, velocity: vel)
        case let .off(ch, pitch, abs):
            let k = key(ch, pitch)
            guard let s = sounding[k] else { continue }
            sounding.removeValue(forKey: k)
            if pedal[ch] {
                heldByPedal[k] = s
            } else {
                flush(k, s, abs, pitch)
            }
        case let .pedal(ch, down, abs):
            pedal[ch] = down
            if !down {
                for (k, s) in heldByPedal where k / 256 == ch {
                    heldByPedal.removeValue(forKey: k)
                    flush(k, s, abs, k % 256)
                }
            }
        case let .allOff(ch, abs):
            for (k, s) in sounding where k / 256 == ch {
                sounding.removeValue(forKey: k)
                flush(k, s, abs, k % 256)
            }
            for (k, s) in heldByPedal where k / 256 == ch {
                heldByPedal.removeValue(forKey: k)
                flush(k, s, abs, k % 256)
            }
        }
    }

    let lastAbs = raw.last?.abs ?? 0
    let endAbs = lastAbs + UInt(tpq)
    for (k, s) in sounding { flush(k, s, endAbs, k % 256) }
    for (k, s) in heldByPedal { flush(k, s, endAbs, k % 256) }

    let clean = notes.filter { $0.midi >= 21 && $0.midi <= 108 && $0.end > $0.start }
        .sorted { $0.start < $1.start }
    return ParsedSong(notes: clean, duration: clean.reduce(0) { max($0, $1.end) })
}

/// Shift every note by semitones, dropping notes that leave piano range.
public func transposed(_ song: ParsedSong, by semitones: Int) -> ParsedSong {    guard semitones != 0 else { return song }
    let notes = song.notes.compactMap { n -> ParsedNote? in
        let m = n.midi + semitones
        guard (21...108).contains(m) else { return nil }
        return ParsedNote(midi: m, start: n.start, end: n.end, velocity: n.velocity)
    }
    return ParsedSong(notes: notes, duration: notes.reduce(0) { max($0, $1.end) })
}

/// Speed multiplier: 2.0 plays twice as fast, 0.5 half time.
public func spedUp(_ song: ParsedSong, by factor: Double) -> ParsedSong {
    guard factor != 1.0, factor > 0 else { return song }
    let notes = song.notes.map { n in
        ParsedNote(midi: n.midi, start: n.start / factor, end: n.end / factor, velocity: n.velocity)
    }
    return ParsedSong(notes: notes, duration: notes.reduce(0) { max($0, $1.end) })
}
