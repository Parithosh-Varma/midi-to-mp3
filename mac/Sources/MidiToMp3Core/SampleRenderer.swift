import Foundation

/// One grand-piano recording at a known MIDI pitch.
public struct PianoSample: Sendable {
    public var midi: Int
    public var left: [Float]
    public var right: [Float]

    public init(midi: Int, left: [Float], right: [Float]) {
        self.midi = midi
        self.left = left
        self.right = right
    }
}

/// Salamander set: C / D# / F# / A of octaves 2...6.
public let salamanderSampleNames: [(name: String, midi: Int)] = {
    var out: [(String, Int)] = []
    for oct in 2...6 {
        for (name, semi) in [("C", 0), ("Ds", 3), ("Fs", 6), ("A", 9)] {
            out.append((name + String(oct), (oct + 1) * 12 + semi))
        }
    }
    return out
}()

public func loadPianoSamples(from directory: URL) throws -> [PianoSample] {
    try salamanderSampleNames.map { def in
        let wav = try readWav16(at: directory.appendingPathComponent(def.name + ".wav"))
        return PianoSample(midi: def.midi, left: wav.left, right: wav.right)
    }
}

/// Render notes by resampling the nearest recording. Returns stereo Float32
/// at 44.1 kHz, peak-normalized to 0.89. Runs synchronously; call it off the
/// main thread and pass an AsyncStream continuation for progress.
public func renderSamples(
    notes: [ParsedNote],
    duration: Double,
    samples: [PianoSample],
    sampleRate: Double = 44_100,
    tail: Double = 1.8,
    reverb: Bool = true,
    progress: AsyncStream<Double>.Continuation? = nil
) -> (left: [Float], right: [Float]) {
    let total = Int((duration + tail) * sampleRate)
    var left = [Float](repeating: 0, count: total)
    var right = [Float](repeating: 0, count: total)
    let attackN = max(1, Int(0.003 * sampleRate))
    let releaseN = max(1, Int(0.12 * sampleRate))

    for (ni, n) in notes.enumerated() {
        var best = samples[0]
        var bd = Int.max
        for s in samples {
            let d = abs(s.midi - n.midi)
            if d < bd { bd = d; best = s }
        }
        let ratio = pow(2.0, Double(n.midi - best.midi) / 12.0)
        let velN = Double(n.velocity) / 127.0
        let gain = Float(pow(velN, 1.2) * 0.6)
        // Soft strikes sound darker, hard strikes brighter.
        let alpha = Float(min(1.0, (2.0 * .pi * (1200 + velN * 11_000)) / sampleRate))
        let startIdx = Int(n.start * sampleRate)
        let holdFrames = max(0, Int(n.end * sampleRate) - startIdx)
        guard startIdx < total else { continue }
        var lpL: Float = 0, lpR: Float = 0
        var i = 0
        while true {
            let pos = Double(i) * ratio
            let i0 = Int(pos)
            guard i0 + 1 < best.left.count else { break }
            let out = startIdx + i
            guard out < total else { break }
            if i > holdFrames + releaseN { break }
            let fr = Float(pos - Double(i0))
            let xL = best.left[i0] + (best.left[i0 + 1] - best.left[i0]) * fr
            let xR = best.right[i0] + (best.right[i0 + 1] - best.right[i0]) * fr
            lpL += alpha * (xL - lpL)
            lpR += alpha * (xR - lpR)
            var env: Float = i < attackN ? Float(i) / Float(attackN) : 1
            if i > holdFrames {
                let rt = min(1.0, Float(i - holdFrames) / Float(releaseN))
                env *= 0.5 + 0.5 * cos(.pi * rt)
            }
            left[out] += lpL * env * gain
            right[out] += lpR * env * gain
            i += 1
        }
        if ni % 200 == 0 { progress?.yield(Double(ni) / Double(notes.count)) }
    }

    if reverb {
        // The recordings already carry the hall; just a breath of room.
        let dryL = left, dryR = right
        for (delayS, g) in [(0.231, Float(0.1)), (0.317, Float(0.07))] {
            let d = Int(delayS * sampleRate)
            for i in d..<total { left[i] += dryL[i - d] * g }
        }
        for (delayS, g) in [(0.257, Float(0.1)), (0.463, Float(0.06))] {
            let d = Int(delayS * sampleRate)
            for i in d..<total { right[i] += dryR[i - d] * g }
        }
    }

    normalizeStereo(left: &left, right: &right)
    progress?.yield(1.0)
    return (left, right)
}

func normalizeStereo(left: inout [Float], right: inout [Float]) {
    var peak: Float = 0
    for i in left.indices {
        peak = max(peak, abs(left[i]), abs(right[i]))
    }
    guard peak > 0 else { return }
    let g = 0.89 / peak
    for i in left.indices {
        left[i] = tanh(left[i] * g * 1.05) * 0.92
        right[i] = tanh(right[i] * g * 1.05) * 0.92
    }
    var p2: Float = 0
    for i in left.indices {
        p2 = max(p2, abs(left[i]), abs(right[i]))
    }
    guard p2 > 0 else { return }
    let g2 = 0.89 / p2
    for i in left.indices {
        left[i] *= g2
        right[i] *= g2
    }
}
