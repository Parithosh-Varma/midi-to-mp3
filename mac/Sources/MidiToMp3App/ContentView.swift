import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import MidiToMp3Core

/// Forwards AVAudioPlayer finish events to SwiftUI state.
private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onFinish: @Sendable () -> Void
    init(onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}

struct Job: Identifiable {
    enum Status: Equatable {
        case queued
        case converting(Double)
        case done(URL)
        case failed(String)
    }

    let id = UUID()
    let source: URL
    var status: Status = .queued

    var name: String { source.lastPathComponent }
}

@MainActor
final class ConverterModel: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var format: ExportFormat = .m4a
    @Published var transpose: Int = 0
    @Published var autoPlay = true
    @Published var playingID: UUID?
    @Published var pausedID: UUID?
    @Published var outputDirectory: URL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MidiToMp3", isDirectory: true)
    @Published var isConverting = false

    let samples = SampleManager()
    private var player: AVAudioPlayer?

    func addFiles(_ urls: [URL]) {
        let mids = urls.filter { ["mid", "midi"].contains($0.pathExtension.lowercased()) }
        for url in mids where !jobs.contains(where: { $0.source == url }) {
            jobs.append(Job(source: url))
        }
    }

    func convertAll() async {
        guard !isConverting else { return }
        isConverting = true
        stopPlayback()
        defer { isConverting = false }
        let piano: [MidiToMp3Core.PianoSample]
        do {
            piano = try await samples.samples()
        } catch {
            for i in jobs.indices where jobs[i].status == .queued {
                jobs[i].status = .failed(error.localizedDescription)
            }
            return
        }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for i in jobs.indices {
            guard jobs[i].status == .queued else { continue }
            jobs[i].status = .converting(0)
            let (stream, cont) = AsyncStream<Double>.makeStream()
            let jobID = jobs[i].id
            let watcher = Task {
                for await f in stream {
                    if let idx = self.jobs.firstIndex(where: { $0.id == jobID }) {
                        self.jobs[idx].status = .converting(f)
                    }
                }
            }
            do {
                let out = try await Converter.convert(
                    midURL: jobs[i].source,
                    samples: piano,
                    transpose: transpose,
                    format: format,
                    outputDirectory: outputDirectory,
                    progress: cont
                )
                jobs[i].status = .done(out)
                if autoPlay { play(out, jobID: jobs[i].id) }
            } catch {
                cont.finish()
                jobs[i].status = .failed(error.localizedDescription)
            }
            await watcher.value
        }
    }

    func clearFinished() {
        stopPlayback()
        jobs.removeAll { job in
            if case .queued = job.status { return false }
            if case .converting = job.status { return false }
            return true
        }
    }

    func play(_ url: URL, jobID: UUID) {
        stopPlayback()
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = PlaybackDelegate { [weak self] in
                Task { @MainActor in
                    self?.playingID = nil
                    self?.pausedID = nil
                }
            }
            player?.play()
            playingID = jobID
            pausedID = nil
        } catch {
            playingID = nil
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingID = nil
        pausedID = nil
    }

    func togglePreview(for job: Job) {
        if playingID == job.id {
            // Pause: keeps position so Play resumes where you left off.
            player?.pause()
            pausedID = job.id
            playingID = nil
            return
        }
        if pausedID == job.id {
            player?.play()
            playingID = job.id
            pausedID = nil
            return
        }
        if case let .done(url) = job.status {
            play(url, jobID: job.id)
        }
    }
}

struct ContentView: View {
    @StateObject private var model = ConverterModel()
    @State private var dragOver = false
    @State private var showOutputPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            sampleBanner
            dropZone
            options
            jobList
            footer
        }
        .padding(20)
        .task { await model.samples.check() }
        .fileImporter(
            isPresented: $showOutputPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                model.outputDirectory = url
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("MIDI → Audio")
                    .font(.largeTitle).bold()
                Text("Real Salamander grand piano sound. Exports AAC (.m4a) and WAV.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add MIDI…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "mid")].compactMap { $0 }
                panel.allowsMultipleSelection = true
                if panel.runModal() == .OK { model.addFiles(panel.urls) }
            }
        }
    }

    @ViewBuilder
    private var sampleBanner: some View {
        switch model.samples.status {
        case .idle:
            HStack {
                Text("Needs the Salamander grand samples (one-time download).")
                Spacer()
                Button("Download piano") {
                    Task {
                        do { _ = try await model.samples.samples() } catch {
                            model.samples.status = .failed(error.localizedDescription)
                        }
                    }
                }.buttonStyle(.borderedProminent)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case let .working(text):
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(text)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case let .progress(f):
            VStack(alignment: .leading) {
                Text("Downloading grand piano…")
                ProgressView(value: f)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .ready:
            EmptyView()
        case let .failed(msg):
            HStack {
                Text("Piano samples failed: \(msg)")
                    .foregroundStyle(.red)
                Spacer()
                Button("Retry") {
                    Task { _ = try? await model.samples.samples() }
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(dragOver ? Color.accentColor : Color.secondary.opacity(0.5),
                          style: StrokeStyle(lineWidth: 2, dash: [8]))
            .background((dragOver ? Color.accentColor.opacity(0.08) : Color.clear), in: RoundedRectangle(cornerRadius: 12))
            .frame(height: 110)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "music.note.list")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Drop .mid files here")
                        .font(.headline)
                    Text("Standard MIDI, format 0/1 · tempo + sustain pedal honored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url {
                            Task { @MainActor in model.addFiles([url]) }
                        }
                    }
                }
                return true
            }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
            Picker("Format", selection: $model.format) {
                ForEach(ExportFormat.allCases) { f in
                    Text(f.fileExtension.uppercased()).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            Stepper("Transpose \(model.transpose > 0 ? "+" : "")\(model.transpose)",
                    value: $model.transpose, in: -24...24)
                .frame(width: 220)
            Toggle("Auto-play", isOn: $model.autoPlay)
            Spacer()
            Button("Output…") { showOutputPicker = true }
            Button("Reveal") {
                NSWorkspace.shared.open(model.outputDirectory)
            }
            }
            .font(.callout)
            Text(model.outputDirectory.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var jobList: some View {
        Group {
            if model.jobs.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("No files yet — drop some MIDI in.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            } else {
                List {
                    ForEach($model.jobs) { $job in
                        HStack {
                            Image(systemName: "music.quarternote.3")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                statusLine(job.status)
                            }
                            Spacer()
                            actions(for: job)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { idx in
                        model.jobs.remove(atOffsets: idx)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 140)
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ status: Job.Status) -> some View {
        switch status {
        case .queued:
            Text("Queued").font(.caption).foregroundStyle(.secondary)
        case let .converting(f):
            ProgressView(value: f)
                .frame(width: 160)
        case let .done(url):
            Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
        case let .failed(msg):
            Text(msg).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func actions(for job: Job) -> some View {
        switch job.status {
        case let .done(url):
            if model.playingID == job.id {
                Button("Pause") { model.togglePreview(for: job) }
                    .buttonStyle(.link)
            } else if model.pausedID == job.id {
                Button("Resume") { model.togglePreview(for: job) }
                    .buttonStyle(.link)
            } else {
                Button("Play") { model.togglePreview(for: job) }
                    .buttonStyle(.link)
            }
            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link)
        case .failed:
            Button("Retry") {
                if let idx = model.jobs.firstIndex(where: { $0.id == job.id }) {
                    model.jobs[idx].status = .queued
                }
            }
            .buttonStyle(.link)
        default:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack {
            Text("Tip: Apple platforms can't encode MP3 — AAC (.m4a) plays everywhere Apple does.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear finished") { model.clearFinished() }
            Button(model.isConverting ? "Converting…" : "Convert all") {
                Task { await model.convertAll() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isConverting || model.jobs.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
    }
}
