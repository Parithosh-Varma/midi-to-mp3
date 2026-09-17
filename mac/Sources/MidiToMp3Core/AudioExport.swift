import AVFoundation
import Foundation

public enum ExportError: Error, LocalizedError {
    case cannotWrite(String)
    public var errorDescription: String? {
        if case let .cannotWrite(f) = self { return "Cannot write audio file: \(f)" }
        return nil
    }
}

private func pcmBuffer(left: [Float], right: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 2,
        interleaved: false
    ) else { return nil }
    guard let buf = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(left.count)
    ) else { return nil }
    buf.frameLength = buf.frameCapacity
    let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
    l.assign(from: left, count: left.count)
    r.assign(from: right, count: right.count)
    return buf
}

/// 16-bit stereo WAV.
public func writeWAV(left: [Float], right: [Float], sampleRate: Double, to url: URL) throws {
    guard let buf = pcmBuffer(left: left, right: right, sampleRate: sampleRate) else {
        throw ExportError.cannotWrite(url.lastPathComponent)
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    try file.write(from: buf)
}

/// AAC in an M4A container. (Apple platforms offer no public MP3 encoder,
// which is why this app exports M4A instead of MP3.)
public func writeM4A(
    left: [Float],
    right: [Float],
    sampleRate: Double,
    bitRate: Int = 256_000,
    to url: URL
) throws {
    guard let buf = pcmBuffer(left: left, right: right, sampleRate: sampleRate) else {
        throw ExportError.cannotWrite(url.lastPathComponent)
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: bitRate,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    try file.write(from: buf)
}
