import Foundation

/// 16-bit PCM WAV samples, mono or stereo, converted to Float32.
public struct WavSamples: Sendable {
    public var sampleRate: Int
    public var left: [Float]
    public var right: [Float]
}

public enum WavError: Error, LocalizedError {
    case unreadable(String)
    public var errorDescription: String? {
        if case let .unreadable(f) = self { return "Unreadable WAV file: \(f)" }
        return nil
    }
}

public func readWav16(at url: URL) throws -> WavSamples {
    let data = try Data(contentsOf: url)
    let b = [UInt8](data)
    func ascii(_ at: Int) -> String {
        String(bytes: b[at ..< at + 4], encoding: .ascii) ?? ""
    }
    func u16(_ at: Int) -> Int { Int(b[at]) | (Int(b[at + 1]) << 8) }
    func u32(_ at: Int) -> Int {
        Int(b[at]) | (Int(b[at + 1]) << 8) | (Int(b[at + 2]) << 16) | (Int(b[at + 3]) << 24)
    }
    guard b.count > 44, ascii(0) == "RIFF" else { throw WavError.unreadable(url.lastPathComponent) }
    var off = 12, channels = 0, bits = 0, sampleRate = 0
    var dataOff = 0, dataLen = 0, audioFmt = 0
    while off + 8 <= b.count {
        let id = ascii(off), len = u32(off + 4)
        if id == "fmt " {
            audioFmt = u16(off + 8)
            channels = u16(off + 10)
            sampleRate = u32(off + 12)
            bits = u16(off + 22)
        } else if id == "data" {
            dataOff = off + 8
            dataLen = len
        }
        off += 8 + len + (len & 1)
    }
    guard audioFmt == 1, bits == 16, channels >= 1, dataOff > 0 else {
        throw WavError.unreadable(url.lastPathComponent)
    }
    let frames = dataLen / (channels * 2)
    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)
    for i in 0..<frames {
        let base = dataOff + i * channels * 2
        let l = Int16(bitPattern: UInt16(b[base]) | (UInt16(b[base + 1]) << 8))
        left[i] = Float(l) / 32768
        if channels > 1 {
            let r = Int16(bitPattern: UInt16(b[base + 2]) | (UInt16(b[base + 3]) << 8))
            right[i] = Float(r) / 32768
        } else {
            right[i] = left[i]
        }
    }
    return WavSamples(sampleRate: sampleRate, left: left, right: right)
}
