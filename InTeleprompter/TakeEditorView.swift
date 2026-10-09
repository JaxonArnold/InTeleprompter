import AVKit
import Combine
import Photos
import SwiftUI

/// Edits the last take: finds dead air, long pauses, and filler words,
/// previews the result live, and saves it to Photos as a new video (the
/// original stays as it was).
@MainActor
final class TakeEditorModel: ObservableObject {
    enum Status: Equatable {
        case analyzing
        case ready
        case unavailable(String)
    }

    enum SaveState: Equatable {
        case idle
        case saving(Double)
        case saved
        case failed(String)
    }

    let take: Take
    let player = AVPlayer()

    @Published private(set) var status: Status = .analyzing
    @Published private(set) var isFindingFillers = false
    @Published private(set) var fillerNote: String?
    @Published private(set) var cuts: [TakeCut] = []
    @Published private(set) var enabled: Set<Int> = []
    @Published private(set) var duration: Double = 0
    @Published private(set) var kept: [Range<Double>] = []
    /// Playback position in the original take, for the timeline.
    @Published private(set) var playhead: Double = 0
    @Published private(set) var saveState: SaveState = .idle

    private let scriptWords: [String]
    private var started = false
    private var rebuildTask: Task<Void, Never>?
    private var timeObserver: Any?

    /// The last take's analysis and cut choices, so reopening is instant.
    private static var remembered: (url: URL, duration: Double, cuts: [TakeCut],
                                    enabled: Set<Int>, note: String?)?

    init(take: Take, scriptWords: [String]) {
        self.take = take
        self.scriptWords = scriptWords
    }

    var editedDuration: Double {
        kept.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
    }

    var hasChanges: Bool { duration - editedDuration > 0.05 }

    func cuts(of kind: TakeCut.Kind) -> [TakeCut] { cuts.filter { $0.kind == kind } }

    func isOn(_ cut: TakeCut) -> Bool { enabled.contains(cut.id) }

    func isOn(_ kind: TakeCut.Kind) -> Bool { cuts(of: kind).contains(where: isOn) }

    func set(_ cut: TakeCut, on: Bool) {
        if on { enabled.insert(cut.id) } else { enabled.remove(cut.id) }
        cutsChanged()
    }

    func set(_ kind: TakeCut.Kind, on: Bool) {
        for cut in cuts(of: kind) {
            if on { enabled.insert(cut.id) } else { enabled.remove(cut.id) }
        }
        cutsChanged()
    }

    // MARK: Analysis

    func start() async {
        guard !started else { return }
        started = true
        observePlayhead()

        if let saved = Self.remembered, saved.url == take.url {
            duration = saved.duration
            cuts = saved.cuts
            enabled = saved.enabled
            fillerNote = saved.note
            status = .ready
            await rebuild()
            return
        }

        let url = take.url
        let audio: TakeAudio
        do {
            audio = try await Task.detached(priority: .userInitiated) {
                try await TakeAnalyzer.loadAudio(from: url)
            }.value
        } catch {
            status = .unavailable("Couldn't read this take.")
            return
        }
        duration = audio.duration
        guard !audio.samples.isEmpty else {
            status = .unavailable("This take has no sound to edit.")
            await rebuild()
            return
        }

        // Pauses are quick to find; show them while listening for fillers.
        cuts = TakeAnalyzer.silenceCuts(voiced: audio.voiced ?? [], duration: audio.duration)
        enabled = Set(cuts.map(\.id))
        status = .ready
        await rebuild()

        isFindingFillers = true
        let script = scriptWords
        let search = await Task.detached(priority: .userInitiated) {
            await TakeAnalyzer.findFillers(in: audio, script: script, firstID: 1_000)
        }.value
        isFindingFillers = false
        switch search {
        case .found(let fillers):
            cuts = (cuts + fillers).sorted { $0.start < $1.start }
            enabled.formUnion(fillers.map(\.id))
            cutsChanged()
        case .unavailable(let note):
            fillerNote = note
            remember()
        }
    }

    func stop() {
        player.pause()
        rebuildTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func remember() {
        guard status == .ready, !isFindingFillers else { return }
        Self.remembered = (take.url, duration, cuts, enabled, fillerNote)
    }

    // MARK: Preview

    private func cutsChanged() {
        if saveState != .idle, !isSaving { saveState = .idle }
        remember()
        rebuildTask?.cancel()
        rebuildTask = Task {
            // Coalesce quick toggling into one rebuild.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await rebuild()
        }
    }

    /// Swaps in a composition of the current cuts, keeping the playhead on
    /// the same moment of the take.
    private func rebuild() async {
        let newKept = TakeAnalyzer.keptRanges(duration: duration, cuts: cuts.filter(isOn))
        let wasPlaying = player.rate > 0
        let source = player.currentItem == nil
            ? 0 : TakeAnalyzer.sourceTime(forEditedTime: player.currentTime().seconds, kept: kept)
        guard let edit = try? await TakeComposer.composition(of: take.url, keeping: newKept),
              !Task.isCancelled else { return }
        let item = AVPlayerItem(asset: edit.composition)
        item.audioMix = edit.audioMix
        kept = newKept
        player.replaceCurrentItem(with: item)
        await seek(toEdited: TakeAnalyzer.editedTime(forSourceTime: source, kept: newKept))
        if wasPlaying { player.play() }
    }

    func seek(toSource time: Double) {
        Task { await seek(toEdited: TakeAnalyzer.editedTime(forSourceTime: time, kept: kept)) }
    }

    /// Plays from just before a cut, so you hear how it lands.
    func preview(_ cut: TakeCut) {
        Task {
            await seek(toEdited: max(0, TakeAnalyzer.editedTime(forSourceTime: cut.start, kept: kept) - 2))
            player.play()
        }
    }

    private func seek(toEdited time: Double) async {
        await player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = TakeAnalyzer.sourceTime(forEditedTime: time, kept: kept)
    }

    private func observePlayhead() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                self.playhead = TakeAnalyzer.sourceTime(forEditedTime: time.seconds, kept: self.kept)
            }
        }
    }

    // MARK: Saving

    private var isSaving: Bool {
        if case .saving = saveState { return true }
        return false
    }

    func save() async {
        guard !isSaving else { return }
        player.pause()
        saveState = .saving(0)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("edited-" + UUID().uuidString)
            .appendingPathExtension("mov")
        // Exporting takes a while; keep going if the app is backgrounded.
        let background = UIApplication.shared.beginBackgroundTask(withName: "SaveEditedTake")
        defer {
            try? FileManager.default.removeItem(at: output)
            UIApplication.shared.endBackgroundTask(background)
        }

        do {
            let edit = try await TakeComposer.composition(of: take.url, keeping: kept)
            try await TakeComposer.export(edit.composition, audioMix: edit.audioMix, to: output) { [weak self] fraction in
                guard let self, self.isSaving else { return }
                self.saveState = .saving(fraction)
            }
            let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard access == .authorized || access == .limited else {
                saveState = .failed("Allow Photos access in Settings to save the edit.")
                return
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: output)
            }
            saveState = .saved
            Haptics.action()
        } catch {
            saveState = .failed("Couldn't save the edit: \(error.localizedDescription)")
        }
    }
}

// MARK: - Editor screen

struct TakeEditorView: View {
    @StateObject private var model: TakeEditorModel
    @Environment(\.dismiss) private var dismiss

    init(take: Take, scriptWords: [String]) {
        _model = StateObject(wrappedValue: TakeEditorModel(take: take, scriptWords: scriptWords))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                if geo.size.width > geo.size.height {
                    HStack(spacing: 0) {
                        VideoPlayer(player: model.player)
                        panel.frame(width: min(400, geo.size.width * 0.45))
                    }
                } else {
                    VStack(spacing: 0) {
                        VideoPlayer(player: model.player)
                        panel.frame(height: min(440, geo.size.height * 0.58))
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .task { await model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        ZStack {
            Text("Edit Take")
                .font(.headline)
                .foregroundStyle(.white)
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Close editor")
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.duration > 0 {
                CutTimeline(duration: model.duration, cuts: model.cuts, enabled: model.enabled,
                            playhead: model.playhead, onSeek: model.seek(toSource:))
                    .frame(height: 30)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        switch model.status {
        case .analyzing:
            progressRow("Looking for pauses…")
        case .unavailable(let message):
            Text(message)
                .foregroundStyle(.secondary)
        case .ready:
            ForEach(TakeCut.Kind.allCases, id: \.self) { kind in
                if !model.cuts(of: kind).isEmpty { kindRow(kind) }
            }
            if model.isFindingFillers {
                progressRow("Listening for filler words…")
            } else if model.cuts.isEmpty {
                Text("Nothing to trim — this take is already tight.")
                    .foregroundStyle(.secondary)
            }
            if let note = model.fillerNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !model.cuts.isEmpty {
                DisclosureGroup("Review each cut") {
                    VStack(spacing: 10) {
                        ForEach(model.cuts) { cutRow($0) }
                    }
                    .padding(.top, 8)
                }
                .tint(.white)
            }
        }
        if case .failed(let message) = model.saveState {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
                .foregroundStyle(.secondary)
        }
    }

    private func kindRow(_ kind: TakeCut.Kind) -> some View {
        let cuts = model.cuts(of: kind)
        let seconds = cuts.reduce(0) { $0 + $1.duration }
        return Toggle(isOn: Binding(get: { model.isOn(kind) }, set: { model.set(kind, on: $0) })) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                    Text(kind.summary(count: cuts.count, seconds: seconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: kind.symbol)
                    .foregroundStyle(kind.color)
            }
        }
    }

    private func cutRow(_ cut: TakeCut) -> some View {
        HStack(spacing: 12) {
            Button {
                model.preview(cut)
            } label: {
                Image(systemName: "play.circle")
                    .font(.title3)
                    .foregroundStyle(cut.kind.color)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play around this cut")

            VStack(alignment: .leading, spacing: 2) {
                Text(cut.label)
                Text("\(Self.timestamp(cut.start)) · \(Self.seconds(cut.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(cut.label, isOn: Binding(get: { model.isOn(cut) }, set: { model.set(cut, on: $0) }))
                .labelsHidden()
                // The disclosure group's white tint (for its chevron) would
                // otherwise turn these switches white-on-white.
                .tint(.green)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.timestamp(model.editedDuration))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                if model.hasChanges {
                    Text("\(Self.seconds(model.duration - model.editedDuration)) shorter")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch model.saveState {
            case .saving(let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 90)
                    Text("Saving…")
                        .foregroundStyle(.secondary)
                }
            case .saved:
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .idle, .failed:
                Button {
                    Task { await model.save() }
                } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasChanges)
            }
        }
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func seconds(_ seconds: Double) -> String {
        String(format: "%.1f s", seconds)
    }
}

private extension TakeCut.Kind {
    var title: String {
        switch self {
        case .deadAir: return "Trim start and end"
        case .pause: return "Shorten long pauses"
        case .filler: return "Remove filler words"
        }
    }

    var symbol: String {
        switch self {
        case .deadAir: return "scissors"
        case .pause: return "pause.circle"
        case .filler: return "text.bubble"
        }
    }

    var color: Color {
        switch self {
        case .deadAir: return Color(white: 0.6)
        case .pause: return .orange
        case .filler: return .pink
        }
    }

    func summary(count: Int, seconds: Double) -> String {
        let time = TakeEditorView.seconds(seconds)
        switch self {
        case .deadAir: return "\(time) of dead air"
        case .pause: return count == 1 ? "1 pause · \(time)" : "\(count) pauses · \(time)"
        case .filler: return count == 1 ? "1 found · \(time)" : "\(count) found · \(time)"
        }
    }
}

/// The whole take as a bar, with each cut marked in its kind's color (faded
/// when it's switched off) and the playhead. Tap to jump there.
private struct CutTimeline: View {
    let duration: Double
    let cuts: [TakeCut]
    let enabled: Set<Int>
    let playhead: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = { (time: Double) in CGFloat(time / duration) * width }
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.white.opacity(0.18))
                ForEach(cuts) { cut in
                    Rectangle()
                        .fill(cut.kind.color.opacity(enabled.contains(cut.id) ? 0.9 : 0.3))
                        .frame(width: max(2, x(cut.end) - x(cut.start)))
                        .offset(x: x(cut.start))
                }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .offset(x: min(max(0, x(playhead) - 1), width - 2))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { location in
                onSeek(Double(location.x / width) * duration)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline")
        .accessibilityValue("\(cuts.filter { enabled.contains($0.id) }.count) cuts")
    }
}

// MARK: - Thumbnail

/// The small bottom-corner button that opens the last take in the editor.
struct TakeThumbnailButton: View {
    let take: Take
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                if let thumbnail = take.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.black.opacity(0.55)
                }

                Image(systemName: "scissors")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
                    .frame(maxHeight: .infinity)

                Text(take.durationText)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.55))
            }
            .frame(width: 58, height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white.opacity(0.8), lineWidth: 1.5)
            )
        }
        .accessibilityLabel("Edit last take, \(take.durationText)")
    }
}
