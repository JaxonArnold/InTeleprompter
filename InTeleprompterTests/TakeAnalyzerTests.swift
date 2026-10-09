import AVFoundation
import Foundation
import Testing
@testable import InTeleprompter

// MARK: - Silence detection

struct SilenceDetectionTests {

    /// Per-window loudness: 50 windows a second.
    private func levels(_ pieces: [(seconds: Double, db: Float)]) -> [Float] {
        pieces.flatMap { Array(repeating: $0.db, count: Int(($0.seconds / TakeAnalyzer.window).rounded())) }
    }

    private func close(_ a: [Range<Double>]?, _ b: [Range<Double>]) -> Bool {
        guard let a, a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs($0.lowerBound - $1.lowerBound) < 0.001 && abs($0.upperBound - $1.upperBound) < 0.001 }
    }

    @Test func findsSpeechAndBridgesShortDips() {
        let regions = TakeAnalyzer.voicedRegions(levels: levels([
            (1, -70), (0.44, -25), (0.1, -70), (0.46, -25),   // a word with a brief dip
            (1.5, -70), (0.5, -25), (1, -70),
        ]))
        #expect(close(regions, [1.0..<2.0, 3.5..<4.0]))
    }

    @Test func uniformAudioIsNotGuessedAt() {
        #expect(TakeAnalyzer.voicedRegions(levels: levels([(5, -40)])) == nil)
    }

    @Test func trimsEndsAndShortensLongPauses() {
        let cuts = TakeAnalyzer.silenceCuts(voiced: [1.0..<2.0, 3.5..<4.0], duration: 5)
        #expect(cuts.map(\.kind) == [.deadAir, .pause, .deadAir])
        #expect(abs(cuts[0].start - 0) < 0.001 && abs(cuts[0].end - 0.75) < 0.001)
        // A 1.5 s pause keeps 0.25 s after the phrase and 0.15 s before the next.
        #expect(abs(cuts[1].start - 2.25) < 0.001 && abs(cuts[1].end - 3.35) < 0.001)
        #expect(abs(cuts[2].start - 4.5) < 0.001 && abs(cuts[2].end - 5) < 0.001)
    }

    @Test func leavesNaturalPausesAlone() {
        let cuts = TakeAnalyzer.silenceCuts(voiced: [0.1..<1.0, 1.5..<2.5], duration: 2.6)
        #expect(cuts.isEmpty)
    }
}

// MARK: - Filler words

struct FillerDetectionTests {

    private let script = ["welcome", "back", "to", "the", "show"]

    private func word(_ text: String, _ start: Double, _ end: Double) -> SpokenWord {
        SpokenWord(text: text, start: start, end: end)
    }

    /// "welcome back … to the show", with sound at 1.1–1.35 s between
    /// "back" and "to".
    private var reading: [SpokenWord] {
        [word("welcome", 0, 0.4), word("back", 0.45, 0.8),
         word("to", 1.6, 1.7), word("the", 1.75, 1.85), word("show", 1.9, 2.3)]
    }
    private let voiced = [0.0..<0.85, 1.1..<1.35, 1.55..<2.35]

    @Test func alignsSpokenWordsToTheScript() {
        let spoken = ["so", "welcome", "back", "um", "to", "the", "shows"]
        #expect(TakeAnalyzer.align(spoken, to: script) == [nil, 0, 1, nil, 2, 3, 4])
    }

    @Test func cutsUnrecognizedSoundBetweenAdjacentScriptWords() {
        let cuts = TakeAnalyzer.fillerCuts(words: reading, voiced: voiced, script: script, firstID: 0)
        #expect(cuts.count == 1)
        #expect(cuts.first?.label == "Filler sound")
        // The sound goes, the words stay, and the gap closes to a normal pause.
        #expect(abs((cuts.first?.start ?? 0) - 1.06) < 0.001)
        #expect(abs((cuts.first?.end ?? 0) - 1.40) < 0.001)
    }

    @Test func leavesSoundAloneWhereScriptWordsWereSkipped() {
        // "everyone" was never recognized — the sound may be that word.
        let script = ["welcome", "back", "everyone", "to", "the", "show"]
        #expect(TakeAnalyzer.fillerCuts(words: reading, voiced: voiced, script: script, firstID: 0).isEmpty)
    }

    @Test func labelsRecognizedHesitations() {
        var words = reading
        words.insert(word("um", 1.1, 1.35), at: 2)
        let cuts = TakeAnalyzer.fillerCuts(words: words, voiced: voiced, script: script, firstID: 0)
        #expect(cuts.map(\.label) == ["“um”"])
    }

    @Test func keepsAdLibs() {
        var words = reading
        words.insert(word("really", 1.1, 1.35), at: 2)
        #expect(TakeAnalyzer.fillerCuts(words: words, voiced: voiced, script: script, firstID: 0).isEmpty)
    }

    @Test func cutsOffScriptLike() {
        var words = reading
        words.insert(word("like", 1.1, 1.35), at: 2)
        let cuts = TakeAnalyzer.fillerCuts(words: words, voiced: voiced, script: script, firstID: 0)
        #expect(cuts.map(\.label) == ["“like”"])
    }

    @Test func longUnrecognizedSoundIsNotTreatedAsFiller() {
        let words = [word("welcome", 0, 0.4), word("back", 0.45, 0.8),
                     word("to", 3.6, 3.7), word("the", 3.75, 3.85), word("show", 3.9, 4.3)]
        let voiced = [0.0..<0.85, 1.1..<3.1, 3.55..<4.35]
        #expect(TakeAnalyzer.fillerCuts(words: words, voiced: voiced, script: script, firstID: 0).isEmpty)
    }

    @Test func hesitationsAreCutEvenWithoutAScript() {
        let words = [word("hi", 0, 0.3), word("um", 0.5, 0.8), word("there", 1.0, 1.3)]
        let cuts = TakeAnalyzer.fillerCuts(words: words, voiced: nil, script: [], firstID: 7)
        #expect(cuts.count == 1)
        #expect(cuts.first?.id == 7)
        #expect(abs((cuts.first?.start ?? 0) - 0.46) < 0.001)
        #expect(abs((cuts.first?.end ?? 0) - 0.84) < 0.001)
    }

    @Test func flagsMultiWordFillers() {
        #expect(TakeAnalyzer.fillerFlags(["you", "know", "like", "i", "mean", "um", "know"])
                == [true, true, true, true, true, true, false])
    }
}

// MARK: - Applying cuts

struct EditTimelineTests {

    private func cut(_ start: Double, _ end: Double) -> TakeCut {
        TakeCut(id: 0, kind: .pause, start: start, end: end, label: "")
    }

    @Test func mergesOverlapsAndDropsSlivers() {
        let kept = TakeAnalyzer.keptRanges(duration: 10, cuts: [cut(1, 2), cut(1.95, 3), cut(3.05, 4)])
        #expect(kept == [0..<1, 4..<10])
    }

    @Test func cutsOutsideTheTakeAreHarmless() {
        let kept = TakeAnalyzer.keptRanges(duration: 10, cuts: [cut(12, 13), cut(-1, 0.5), cut(9.5, 11)])
        #expect(kept == [0.5..<9.5])
    }

    @Test func mapsTimeBetweenOriginalAndEdit() {
        let kept: [Range<Double>] = [0..<1, 4..<10]
        #expect(TakeAnalyzer.editedTime(forSourceTime: 4.5, kept: kept) == 1.5)
        #expect(TakeAnalyzer.editedTime(forSourceTime: 2, kept: kept) == 1)   // inside a cut
        #expect(TakeAnalyzer.sourceTime(forEditedTime: 1.5, kept: kept) == 4.5)
        #expect(TakeAnalyzer.sourceTime(forEditedTime: 0.5, kept: kept) == 0.5)
        #expect(TakeAnalyzer.sourceTime(forEditedTime: 99, kept: kept) == 10)
    }

    @Test func transcriptionChunksSplitInPausesAndCoverEverything() {
        let voiced = stride(from: 0.0, to: 120, by: 10).map { $0..<($0 + 8) }
        let chunks = TakeAnalyzer.transcriptionChunks(voiced: voiced, duration: 125)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.upperBound - $0.lowerBound <= 50 })
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(a.upperBound == b.lowerBound)
        }
        for run in voiced {
            #expect(chunks.contains { $0.lowerBound <= run.lowerBound && run.upperBound <= $0.upperBound })
        }
    }
}

// MARK: - Real audio, end to end

struct TakeAudioEndToEndTests {

    /// Writes a tone/silence pattern to an audio file.
    private func makeFile(_ pattern: [(seconds: Double, tone: Bool)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analyzer-test-" + UUID().uuidString)
            .appendingPathExtension("caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        var phase = 0.0
        for piece in pattern {
            let frames = AVAudioFrameCount(piece.seconds * 44_100)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let samples = buffer.floatChannelData![0]
            for i in 0..<Int(frames) {
                // A faint hiss stands in for room noise.
                let noise = Float.random(in: -0.0005...0.0005)
                samples[i] = (piece.tone ? Float(sin(phase) * 0.3) : 0) + noise
                phase += 2 * .pi * 220 / 44_100
            }
            try file.write(from: buffer)
        }
        return url
    }

    @Test func decodesAndFindsTheQuietParts() async throws {
        let url = try makeFile([(1, false), (1, true), (1.5, false), (0.5, true), (1, false)])
        defer { try? FileManager.default.removeItem(at: url) }

        let audio = try await TakeAnalyzer.loadAudio(from: url)
        #expect(abs(audio.duration - 5) < 0.05)
        let voiced = try #require(audio.voiced)
        #expect(voiced.count == 2)
        #expect(abs(voiced[0].lowerBound - 1) < 0.05 && abs(voiced[0].upperBound - 2) < 0.05)
        #expect(abs(voiced[1].lowerBound - 3.5) < 0.05 && abs(voiced[1].upperBound - 4) < 0.05)

        let cuts = TakeAnalyzer.silenceCuts(voiced: voiced, duration: audio.duration)
        #expect(cuts.map(\.kind) == [.deadAir, .pause, .deadAir])

        // The edit plays back as exactly the kept pieces, back to back.
        let kept = TakeAnalyzer.keptRanges(duration: audio.duration, cuts: cuts)
        let edit = try await TakeComposer.composition(of: url, keeping: kept)
        let expected = kept.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        #expect(abs(edit.composition.duration.seconds - expected) < 0.01)
        #expect(edit.audioMix != nil)
    }
}
