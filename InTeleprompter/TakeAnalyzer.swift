import AVFoundation
import Speech

/// One stretch of a take the editor can cut, in seconds of the original.
nonisolated struct TakeCut: Identifiable, Equatable, Sendable {
    enum Kind: CaseIterable, Sendable {
        case deadAir, pause, filler
    }

    let id: Int
    let kind: Kind
    let start: Double
    let end: Double
    /// What's being cut, for the review list: "um", "Pause", …
    let label: String

    var duration: Double { end - start }
}

/// A recognized word and when it was said.
nonisolated struct SpokenWord: Equatable, Sendable {
    /// Normalized like script words (lowercase letters and digits).
    let text: String
    let start: Double
    let end: Double
}

/// A take's audio, decoded for analysis.
nonisolated struct TakeAudio: Sendable {
    static let sampleRate = 16_000.0

    /// Mono samples; sample `i` is at `i / sampleRate` seconds into the take.
    let samples: [Float]
    /// Length of the whole take, video included.
    let duration: Double
    /// Where someone is talking (or making any other sound above the room's
    /// noise floor). Nil when the audio is too uniform to tell sound from
    /// silence — then nothing is cut for being quiet.
    let voiced: [Range<Double>]?
}

/// Finds what to cut from a take: dead air at either end, long pauses, and
/// filler words. Everything here is nonisolated so the heavy lifting runs
/// off the main thread.
nonisolated enum TakeAnalyzer {

    /// Loudness is measured in windows this long.
    static let window = 0.02

    // MARK: - Tuning

    /// Silence kept before the first sound and after the last.
    static let leadIn = 0.25
    static let tailOut = 0.5
    /// Pauses at least this long get shortened…
    static let longPause = 0.75
    /// …to this much silence after the previous phrase plus this much before
    /// the next — about 0.4 s, which still sounds like a breath.
    static let keepAfterSpeech = 0.25
    static let keepBeforeSpeech = 0.15
    /// Unrecognized sound between two words longer than this is probably
    /// speech the recognizer missed, not a filler.
    static let maxFillerSound = 1.5

    static let hesitations: Set<String> = [
        "um", "umm", "uhm", "uh", "uhh", "er", "erm", "ah", "hmm", "hm", "mm", "mmm", "mhm",
    ]

    // MARK: - Audio

    static func loadAudio(from url: URL) async throws -> TakeAudio {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return TakeAudio(samples: [], duration: duration, voiced: nil)
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: TakeAudio.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(duration * TakeAudio.sampleRate) + 4096)
        var firstTimestamp: Double?
        while let buffer = output.copyNextSampleBuffer() {
            if firstTimestamp == nil {
                firstTimestamp = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(block)
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: byteCount / MemoryLayout<Float>.size))
            samples.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount,
                                               destination: bytes.baseAddress!.advanced(by: start * MemoryLayout<Float>.size))
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? CocoaError(.fileReadCorruptFile)
        }
        // Audio that starts after the first frame is padded, so sample
        // positions line up with video time.
        if let firstTimestamp, firstTimestamp > 0.001 {
            samples.insert(contentsOf: repeatElement(0, count: Int(firstTimestamp * TakeAudio.sampleRate)), at: 0)
        }
        return TakeAudio(samples: samples, duration: duration, voiced: voicedRegions(levels: levels(of: samples)))
    }

    /// Loudness in dBFS per `window`.
    static func levels(of samples: [Float]) -> [Float] {
        let size = Int(window * TakeAudio.sampleRate)
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / size + 1)
        var start = 0
        while start < samples.count {
            let end = min(start + size, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            levels.append(20 * log10(max((sum / Float(end - start)).squareRoot(), 1e-6)))
            start = end
        }
        return levels
    }

    /// Stretches of sound, from per-window loudness. The threshold adapts to
    /// the take: a fixed margin above the room's noise floor, scaled by how
    /// much louder the speech is.
    static func voicedRegions(levels: [Float]) -> [Range<Double>]? {
        guard levels.count >= 10 else { return nil }
        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10]
        let peak = sorted[sorted.count * 95 / 100]
        guard peak - floor >= 10 else { return nil }
        let threshold = floor + max(8, (peak - floor) * 0.3)

        var runs: [Range<Int>] = []
        var runStart: Int?
        for (i, level) in levels.enumerated() {
            if level > threshold {
                if runStart == nil { runStart = i }
            } else if let start = runStart {
                runs.append(start..<i)
                runStart = nil
            }
        }
        if let start = runStart { runs.append(start..<levels.count) }

        // Bridge the short dips inside words and between syllables, then
        // drop clicks.
        let maxGap = Int((0.15 / window).rounded())
        var merged: [Range<Int>] = []
        for run in runs {
            if let last = merged.last, run.lowerBound - last.upperBound < maxGap {
                merged[merged.count - 1] = last.lowerBound..<run.upperBound
            } else {
                merged.append(run)
            }
        }
        let minRun = Int((0.06 / window).rounded())
        return merged.filter { $0.count >= minRun }.map {
            Double($0.lowerBound) * window..<Double($0.upperBound) * window
        }
    }

    // MARK: - Dead air and pauses

    static func silenceCuts(voiced: [Range<Double>], duration: Double) -> [TakeCut] {
        guard let first = voiced.first, let last = voiced.last else { return [] }
        var cuts: [TakeCut] = []
        func add(_ kind: TakeCut.Kind, _ start: Double, _ end: Double, _ label: String) {
            guard end - start >= 0.3 else { return }
            cuts.append(TakeCut(id: cuts.count, kind: kind, start: start, end: end, label: label))
        }

        add(.deadAir, 0, first.lowerBound - leadIn, "Start")
        for (before, after) in zip(voiced, voiced.dropFirst())
        where after.lowerBound - before.upperBound >= longPause {
            add(.pause, before.upperBound + keepAfterSpeech, after.lowerBound - keepBeforeSpeech, "Pause")
        }
        add(.deadAir, last.upperBound + tailOut, duration, "End")
        return cuts
    }

    // MARK: - Filler words

    /// Filler cuts from a transcript. Apple's recognizer usually leaves "um"
    /// and "uh" out of transcripts, so besides cutting any it does report,
    /// this looks for sound *between* two words that are next to each other
    /// in the script: nothing from the script was said there, so it's a
    /// filler, a stumble, or a cough. Between words that aren't adjacent in
    /// the script, unrecognized sound may be a script word the recognizer
    /// missed — that's left alone.
    static func fillerCuts(words: [SpokenWord], voiced: [Range<Double>]?,
                           script: [String], firstID: Int) -> [TakeCut] {
        guard !words.isEmpty else { return [] }
        let alignment = align(words.map(\.text), to: script)
        let isFiller = fillerFlags(words.map(\.text))
        var cuts: [TakeCut] = []
        var covered = Set<Int>()

        func add(_ start: Double, _ end: Double, _ label: String) {
            guard end - start >= 0.08 else { return }
            cuts.append(TakeCut(id: firstID + cuts.count, kind: .filler, start: start, end: end, label: label))
        }

        let matched = alignment.indices.filter { alignment[$0] != nil }
        for (p, q) in zip(matched, matched.dropFirst()) where alignment[q]! == alignment[p]! + 1 {
            let between = (p + 1)..<q
            guard between.allSatisfy({ isFiller[$0] }) else { continue }
            let label = between.isEmpty ? "Filler sound" : quoted(words[between].map(\.text))

            if let voiced,
               let before = voiced.lastIndex(where: { $0.lowerBound < words[p].end }),
               let after = voiced.firstIndex(where: { $0.upperBound > words[q].start }),
               after - before > 1 {
                // Sound fully between the two words' own stretches of sound.
                let speechEnd = voiced[before].upperBound
                let speechStart = voiced[after].lowerBound
                let sound = voiced[before + 1].lowerBound..<voiced[after - 1].upperBound
                guard sound.upperBound - sound.lowerBound <= maxFillerSound else { continue }
                // Cut the sound and tighten the silence around it to a
                // normal pause, without touching the words.
                add(max(speechEnd + 0.02, min(sound.lowerBound - 0.04, speechEnd + keepAfterSpeech)),
                    min(speechStart - 0.02, max(sound.upperBound + 0.04, speechStart - keepBeforeSpeech)),
                    label)
                covered.formUnion(between)
            } else if !between.isEmpty {
                // No separate sound found; trust the recognizer's timing.
                add(max(words[p].end, words[between.first!].start - 0.04),
                    min(words[q].start, words[between.last!].end + 0.04),
                    label)
                covered.formUnion(between)
            }
        }

        // Hesitations anywhere else (before the first script word, or where
        // the take skips around the script).
        for (i, word) in words.enumerated()
        where hesitations.contains(word.text) && alignment[i] == nil && !covered.contains(i) {
            let previousEnd = i > 0 ? words[i - 1].end : 0
            let nextStart = i + 1 < words.count ? words[i + 1].start : word.end + 1
            add(max(previousEnd, word.start - 0.04), min(nextStart, word.end + 0.04), quoted([word.text]))
        }
        return cuts.sorted { $0.start < $1.start }
    }

    /// Hesitations, "like", "you know", and "I mean". The soft ones only get
    /// cut when they're inserted between adjacent script words.
    static func fillerFlags(_ words: [String]) -> [Bool] {
        var flags = words.map { hesitations.contains($0) || $0 == "like" }
        for i in words.indices.dropLast() {
            if (words[i] == "you" && words[i + 1] == "know") || (words[i] == "i" && words[i + 1] == "mean") {
                flags[i] = true
                flags[i + 1] = true
            }
        }
        return flags
    }

    private static func quoted(_ words: [String]) -> String {
        "“" + words.joined(separator: " ") + "”"
    }

    // MARK: - Script alignment

    /// The script index each spoken word matches, if any: a longest common
    /// subsequence with the voice tracker's fuzzy word matching.
    static func align(_ spoken: [String], to script: [String]) -> [Int?] {
        var result = [Int?](repeating: nil, count: spoken.count)
        let n = spoken.count
        let m = script.count
        // Past ~20 million cells (hours of speech against a book) skip it.
        guard n > 0, m > 0, (n + 1) * (m + 1) <= 20_000_000 else { return result }

        // Compare distinct words once rather than per cell.
        var ids: [String: Int] = [:]
        func id(_ word: String) -> Int {
            if let existing = ids[word] { return existing }
            ids[word] = ids.count
            return ids.count - 1
        }
        let spokenIDs = spoken.map(id)
        let scriptIDs = script.map(id)
        let vocabulary = ids.sorted { $0.value < $1.value }.map(\.key)
        let size = vocabulary.count
        var equivalent = [Bool](repeating: false, count: size * size)
        for a in Set(spokenIDs) {
            for b in Set(scriptIDs) where SpeechScriptTracker.matches(vocabulary[a], vocabulary[b]) {
                equivalent[a * size + b] = true
            }
        }
        func same(_ i: Int, _ j: Int) -> Bool { equivalent[spokenIDs[i] * size + scriptIDs[j]] }

        var table = [UInt16](repeating: 0, count: (n + 1) * (m + 1))
        let width = m + 1
        for i in 1...n {
            for j in 1...m {
                table[i * width + j] = same(i - 1, j - 1)
                    ? table[(i - 1) * width + j - 1] &+ 1
                    : max(table[(i - 1) * width + j], table[i * width + j - 1])
            }
        }
        var i = n
        var j = m
        while i > 0, j > 0 {
            if same(i - 1, j - 1), table[i * width + j] == table[(i - 1) * width + j - 1] &+ 1 {
                result[i - 1] = j - 1
                i -= 1
                j -= 1
            } else if table[(i - 1) * width + j] >= table[i * width + j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result
    }

    // MARK: - Transcription

    enum FillerSearch: Sendable {
        case found([TakeCut])
        case unavailable(String)
    }

    static func findFillers(in audio: TakeAudio, script: [String], firstID: Int) async -> FillerSearch {
        guard await authorizeSpeech() else {
            return .unavailable("Allow speech recognition in Settings to find filler words.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            return .unavailable("Speech recognition isn't available right now, so filler words weren't checked.")
        }
        guard let words = await transcribe(audio, with: recognizer, hints: hints(from: script)) else {
            return .unavailable("Couldn't listen for filler words in this take.")
        }
        return .found(fillerCuts(words: words, voiced: audio.voiced, script: script, firstID: firstID))
    }

    private static func authorizeSpeech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default:
            return false
        }
    }

    /// Fillers first (asking for them makes the recognizer likelier to
    /// write them down), then distinctive script words.
    private static func hints(from script: [String]) -> [String] {
        var seen = Set<String>()
        let distinctive = script.filter { $0.count >= 5 && seen.insert($0).inserted }
        return ["um", "uh", "erm", "hmm"] + distinctive.prefix(96)
    }

    /// Splits the take at pauses into pieces under a minute — recognizers
    /// that run on Apple's servers stop listening after a minute.
    static func transcriptionChunks(voiced: [Range<Double>]?, duration: Double,
                                    maxLength: Double = 50) -> [Range<Double>] {
        guard let voiced, let first = voiced.first else {
            return stride(from: 0, to: duration, by: maxLength).map { $0..<min($0 + maxLength, duration) }
        }
        var chunks: [Range<Double>] = []
        var start = max(0, first.lowerBound - 0.3)
        var previousEnd = first.upperBound
        for run in voiced.dropFirst() {
            if run.upperBound - start > maxLength {
                let boundary = (previousEnd + run.lowerBound) / 2
                chunks.append(start..<boundary)
                start = boundary
            }
            previousEnd = run.upperBound
        }
        chunks.append(start..<min(duration, previousEnd + 0.3))
        return chunks
    }

    private static func transcribe(_ audio: TakeAudio, with recognizer: SFSpeechRecognizer,
                                   hints: [String]) async -> [SpokenWord]? {
        let rate = TakeAudio.sampleRate
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: 1, interleaved: false) else { return nil }
        var words: [SpokenWord] = []
        for chunk in transcriptionChunks(voiced: audio.voiced, duration: Double(audio.samples.count) / rate) {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = false
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            request.addsPunctuation = false
            request.taskHint = .dictation
            request.contextualStrings = hints

            var index = Int(chunk.lowerBound * rate)
            let end = min(audio.samples.count, Int(chunk.upperBound * rate))
            while index < end {
                let count = min(4096, end - index)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let channel = buffer.floatChannelData?[0] else { return nil }
                buffer.frameLength = AVAudioFrameCount(count)
                audio.samples.withUnsafeBufferPointer { source in
                    channel.update(from: source.baseAddress!.advanced(by: index), count: count)
                }
                request.append(buffer)
                index += count
            }
            request.endAudio()

            guard let segments = await recognize(request, with: recognizer) else { return nil }
            for segment in segments {
                // A segment is normally one word; share its time if not.
                let parts = segment.substring.split(whereSeparator: \.isWhitespace)
                    .map { ScriptTokenizer.normalize(String($0)) }
                    .filter { !$0.isEmpty }
                guard !parts.isEmpty else { continue }
                let share = segment.duration / Double(parts.count)
                for (k, part) in parts.enumerated() {
                    let start = chunk.lowerBound + segment.timestamp + share * Double(k)
                    words.append(SpokenWord(text: part, start: start, end: start + share))
                }
            }
        }
        return words
    }

    /// The final transcription, `[]` when there was no speech, nil on failure.
    private static func recognize(_ request: SFSpeechAudioBufferRecognitionRequest,
                                  with recognizer: SFSpeechRecognizer) async -> [SFTranscriptionSegment]? {
        await withCheckedContinuation { continuation in
            // The recognizer's callbacks and the timeout both run on the main
            // queue, so the flag needs no lock.
            final class Once { var done = false }
            nonisolated(unsafe) let once = Once()
            recognizer.queue = .main
            nonisolated(unsafe) let task = recognizer.recognitionTask(with: request) { result, error in
                guard !once.done else { return }
                if let result, result.isFinal {
                    once.done = true
                    continuation.resume(returning: result.bestTranscription.segments)
                } else if let error {
                    once.done = true
                    // 1110: no speech detected.
                    continuation.resume(returning: (error as NSError).code == 1110 ? [] : nil)
                }
            }
            // A stalled recognizer may never call back, not even after being
            // cancelled — give up rather than leave the editor waiting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                guard !once.done else { return }
                once.done = true
                task.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Applying cuts

    /// What's left of the take after `cuts`, in original seconds. Overlapping
    /// cuts merge, and slivers under 0.12 s left between two cuts go too —
    /// played back they'd sound like a glitch.
    static func keptRanges(duration: Double, cuts: [TakeCut]) -> [Range<Double>] {
        var removed: [Range<Double>] = []
        let ranges = cuts.map { cut -> Range<Double> in
            let lower = min(max(0, cut.start), duration)
            return lower..<min(duration, max(lower, cut.end))
        }
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        for range in ranges {
            if let last = removed.last, range.lowerBound <= last.upperBound {
                removed[removed.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                removed.append(range)
            }
        }
        var kept: [Range<Double>] = []
        var cursor = 0.0
        for range in removed {
            if range.lowerBound > cursor { kept.append(cursor..<range.lowerBound) }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < duration { kept.append(cursor..<duration) }
        return kept.filter { piece in
            let betweenCuts = piece.lowerBound > 0 && piece.upperBound < duration
            return !betweenCuts || piece.upperBound - piece.lowerBound >= 0.12
        }
    }

    static func editedTime(forSourceTime time: Double, kept: [Range<Double>]) -> Double {
        var elapsed = 0.0
        for range in kept {
            if time < range.lowerBound { return elapsed }
            if time < range.upperBound { return elapsed + time - range.lowerBound }
            elapsed += range.upperBound - range.lowerBound
        }
        return elapsed
    }

    static func sourceTime(forEditedTime time: Double, kept: [Range<Double>]) -> Double {
        var remaining = max(0, time)
        for range in kept {
            let length = range.upperBound - range.lowerBound
            if remaining < length { return range.lowerBound + remaining }
            remaining -= length
        }
        return kept.last?.upperBound ?? 0
    }
}

/// Builds the edited video: the kept pieces back to back, with a short audio
/// fade at each join so cuts don't click.
nonisolated enum TakeComposer {
    static let fade = 0.015

    static func composition(of url: URL, keeping kept: [Range<Double>]) async throws
        -> (composition: AVMutableComposition, audioMix: AVMutableAudioMix?) {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        var tracks: [(source: AVAssetTrack, range: CMTimeRange, target: AVMutableCompositionTrack)] = []
        for source in try await asset.loadTracks(withMediaType: .video)
            + asset.loadTracks(withMediaType: .audio) {
            guard let target = composition.addMutableTrack(withMediaType: source.mediaType,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            if source.mediaType == .video {
                target.preferredTransform = try await source.load(.preferredTransform)
            }
            tracks.append((source, try await source.load(.timeRange), target))
        }

        var cursor = CMTime.zero
        var pieces: [CMTimeRange] = []
        for range in kept {
            let piece = CMTimeRange(start: time(range.lowerBound), end: time(range.upperBound))
            for track in tracks {
                // A track can end a hair before the take does.
                let available = piece.intersection(track.range)
                guard !available.isEmpty else { continue }
                try track.target.insertTimeRange(available, of: track.source,
                                                 at: cursor + (available.start - piece.start))
            }
            pieces.append(CMTimeRange(start: cursor, duration: piece.duration))
            cursor = cursor + piece.duration
        }

        guard pieces.count > 1,
              let audio = tracks.first(where: { $0.source.mediaType == .audio })?.target else {
            return (composition, nil)
        }
        let parameters = AVMutableAudioMixInputParameters(track: audio)
        let fadeDuration = time(fade)
        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                                         timeRange: CMTimeRange(start: piece.start, duration: fadeDuration))
            }
            if index < pieces.count - 1 {
                parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                         timeRange: CMTimeRange(start: piece.end - fadeDuration, duration: fadeDuration))
            }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return (composition, mix)
    }

    /// Renders the edit to a movie file at the take's full quality.
    static func export(_ composition: AVComposition, audioMix: AVAudioMix?, to url: URL,
                       progress: @escaping @MainActor (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality)
            ?? AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw CocoaError(.fileWriteUnknown) }
        session.audioMix = audioMix

        if #available(iOS 18, *) {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await session.export(to: url, as: .mov)
                    return true
                }
                group.addTask {
                    for await state in session.states(updateInterval: 0.2) {
                        if case .exporting(let exporting) = state {
                            await progress(exporting.fractionCompleted)
                        }
                    }
                    return false
                }
                // Done when the export is, whether or not progress updates end.
                while let exportFinished = try await group.next(), !exportFinished {}
                group.cancelAll()
            }
        } else {
            session.outputURL = url
            session.outputFileType = .mov
            let poll = Task { @MainActor in
                while !Task.isCancelled {
                    progress(Double(session.progress))
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
            poll.cancel()
            guard session.status == .completed else {
                throw session.error ?? CocoaError(.fileWriteUnknown)
            }
        }
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 48_000)
    }
}
