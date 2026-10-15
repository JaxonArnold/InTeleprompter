import AVFoundation
import Foundation
import Testing
@testable import InTeleprompter

// MARK: - Script text

struct CaptionScriptTokenTests {

    private func tokens(_ text: String) -> [ScriptToken] {
        // Speaker cues aren't spoken, so the tracker leaves them out.
        let words = ScriptTokenizer.words(in: text).filter { $0.normalized != "host" }
        return TakeCaptions.scriptTokens(for: words, in: text)
    }

    @Test func keepsPunctuationWithItsWord() {
        let result = tokens("Welcome back, everyone! It's a \"test\".\n\nHOST: Thanks.")
        #expect(result.map(\.text) == ["Welcome", "back,", "everyone!", "It's", "a", "\"test\".", "Thanks."])
    }

    @Test func gluesWordsWithNoSpaceBetween() {
        let result = tokens("a 3-second clip")
        #expect(result.map(\.text) == ["a", "3-", "second", "clip"])
        #expect(result.map(\.gluedToNext) == [false, true, false, false])
    }
}

// MARK: - Caption words

struct CaptionWordTests {

    private let script = TakeCaptions.scriptTokens(
        for: ScriptTokenizer.words(in: "Welcome back to the show. Our guest is Kaiden Ostrowski."),
        in: "Welcome back to the show. Our guest is Kaiden Ostrowski.")

    private func spoken(_ words: [(String, Double)]) -> [SpokenWord] {
        words.map { word, start in
            SpokenWord(text: ScriptTokenizer.normalize(word), start: start, end: start + 0.3, display: word)
        }
    }

    private func texts(_ words: [SpokenWord]) -> [String] {
        TakeCaptions.captionWords(spoken: words, script: script).map(\.text)
    }

    @Test func usesTheScriptsSpellingAndDropsFillers() {
        let heard = spoken([("welcome", 0), ("back", 0.4), ("um", 0.8), ("to", 1.2), ("the", 1.4), ("show", 1.6),
                            ("our", 2.5), ("guest", 2.8), ("is", 3.1), ("Kayden", 3.3), ("Ostrowsky", 3.7)])
        #expect(texts(heard) == ["Welcome", "back", "to", "the", "show.", "Our", "guest", "is", "Kaiden", "Ostrowski."])
    }

    @Test func replacesMisheardWordsWithTheScript() {
        let heard = spoken([("our", 0), ("guest", 0.3), ("is", 0.6), ("Kay", 0.9), ("done", 1.2), ("Ostrowski", 1.5)])
        #expect(texts(heard) == ["Our", "guest", "is", "Kaiden", "Ostrowski."])
    }

    @Test func keepsAdLibsAsHeard() {
        let heard = spoken([("welcome", 0), ("back", 0.3), ("everybody", 0.6), ("to", 1.0), ("the", 1.2), ("show", 1.4)])
        #expect(texts(heard) == ["Welcome", "back", "everybody", "to", "the", "show."])
    }

    @Test func restoresShortWordsTheRecognizerDropped() {
        let heard = spoken([("welcome", 0), ("back", 0.3), ("the", 0.7), ("show", 0.9)])
        #expect(texts(heard) == ["Welcome", "back", "to", "the", "show."])
    }

    @Test func leavesOutWholeSkippedPassages() {
        let heard = spoken([("welcome", 0), ("back", 0.3), ("Kaiden", 1.0), ("Ostrowski", 1.3)])
        #expect(texts(heard) == ["Welcome", "back", "Kaiden", "Ostrowski."])
    }

    @Test func withoutAScriptUsesWhatWasHeard() {
        let heard = spoken([("Hello", 0), ("um", 0.4), ("there", 0.8)])
        #expect(TakeCaptions.captionWords(spoken: heard, script: []).map(\.text) == ["Hello", "there"])
    }
}

// MARK: - Cues and subtitles

struct CaptionCueTests {

    private func word(_ text: String, _ start: Double, _ end: Double) -> CaptionWord {
        CaptionWord(text: text, start: start, end: end)
    }

    @Test func breaksAtSentencesAndLingers() {
        let cues = TakeCaptions.cues(from: [
            word("Welcome", 0, 0.4), word("back.", 0.5, 0.9),
            word("Our", 2.0, 2.2), word("guest.", 2.3, 2.7),
        ])
        #expect(cues.map(\.text) == ["Welcome back.", "Our guest."])
        // Lingers 0.3 s after the last word, without overlapping the next.
        #expect(abs(cues[0].end - 1.2) < 0.001)
        #expect(abs(cues[1].end - 3.0) < 0.001)
    }

    @Test func breaksLongLinesAndPauses() {
        let words = ["This", "line", "has", "far", "too", "many", "words", "to", "fit"].enumerated().map {
            word($0.element, Double($0.offset) * 0.3, Double($0.offset) * 0.3 + 0.25)
        }
        let cues = TakeCaptions.cues(from: words)
        #expect(cues.count == 2)
        #expect(cues.allSatisfy { $0.text.count <= 32 })

        let paused = TakeCaptions.cues(from: [word("Wait", 0, 0.3), word("what", 1.5, 1.8)])
        #expect(paused.map(\.text) == ["Wait", "what"])
    }

    @Test func finishesTheSentenceInsteadOfStrandingAWord() {
        let words = ["This", "script", "is", "a", "quick", "tour", "today."].enumerated().map {
            word($0.element, Double($0.offset) * 0.3, Double($0.offset) * 0.3 + 0.25)
        }
        #expect(TakeCaptions.cues(from: words).map(\.text) == ["This script is a quick tour today."])
    }

    @Test func breaksAfterACommaOnceTheLineIsLong() {
        let words = ["Open", "it", "in", "the", "prompter,", "then", "steal", "it."].enumerated().map {
            word($0.element, Double($0.offset) * 0.3, Double($0.offset) * 0.3 + 0.25)
        }
        #expect(TakeCaptions.cues(from: words).map(\.text) == ["Open it in the prompter,", "then steal it."])
    }

    @Test func gluedWordsJoinWithoutASpace() {
        let cues = TakeCaptions.cues(from: [
            CaptionWord(text: "a", start: 0, end: 0.1),
            CaptionWord(text: "3-", start: 0.1, end: 0.2, gluedToNext: true),
            CaptionWord(text: "second", start: 0.2, end: 0.4),
        ])
        #expect(cues.map(\.text) == ["a 3-second"])
    }

    @Test func followsTheEditAndDropsCutWords() {
        let words = [word("Hello", 0.5, 0.9), word("um", 1.0, 1.4), word("there", 2.0, 2.4)]
        let edited = TakeCaptions.edited(words, kept: [0..<0.95, 1.9..<3])
        #expect(edited.map(\.text) == ["Hello", "there"])
        #expect(abs(edited[1].start - 1.05) < 0.001)   // 0.95 kept before it, then 0.1 s in
    }

    @Test func writesSubRip() {
        let srt = TakeCaptions.srt([CaptionCue(text: "Hello there.", start: 1.25, end: 3.5),
                                    CaptionCue(text: "Bye.", start: 3661.007, end: 3662)])
        #expect(srt == """
            1
            00:00:01,250 --> 00:00:03,500
            Hello there.

            2
            01:01:01,007 --> 01:01:02,000
            Bye.

            """)
    }
}

// MARK: - Burned-in captions, end to end

struct BurnedInCaptionTests {

    /// A 2-second clip, stored sideways with a 90° rotation — the way the
    /// camera writes portrait takes. Red on the left of the stored frame,
    /// blue on the right, so upright it's red on top.
    private func makeSidewaysClip() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-test-" + UUID().uuidString).appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
        ])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let pixels = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt32.self)
            let row = CVPixelBufferGetBytesPerRow(buffer!) / 4
            for y in 0..<360 {
                for x in 0..<640 {
                    pixels[y * row + x] = x < 320 ? 0xFFFF_0000 : 0xFF00_00FF   // BGRA: red | blue
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// RGB of one pixel, with (0, 0) at the top left.
    private func pixel(of image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    @Test func captionsAreUprightAndOnlyShowDuringTheirCue() async throws {
        let source = try await makeSidewaysClip()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-out-" + UUID().uuidString).appendingPathExtension("mov")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }

        let edit = try await TakeComposer.composition(of: source, keeping: [0..<2])
        let cues = [CaptionCue(text: "WWWWWWWW", start: 0.5, end: 1.5)]
        let captions = try #require(try await CaptionRenderer.videoComposition(for: edit.composition, cues: cues))
        #expect(captions.renderSize == CGSize(width: 360, height: 640))

        try await TakeComposer.export(edit.composition, audioMix: edit.audioMix, videoComposition: captions,
                                      to: output) { _ in }

        let result = AVURLAsset(url: output)
        let track = try #require(try await result.loadTracks(withMediaType: .video).first)
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let shown = CGRect(origin: .zero, size: size).applying(transform)
        #expect(abs(shown.width) == 360 && abs(shown.height) == 640)

        let frames = AVAssetImageGenerator(asset: result)
        frames.appliesPreferredTrackTransform = true
        frames.requestedTimeToleranceBefore = .zero
        frames.requestedTimeToleranceAfter = .zero
        let before = try await frames.image(at: CMTime(value: 2, timescale: 10)).image
        let during = try await frames.image(at: CMTime(value: 10, timescale: 10)).image

        // The caption box sits centered, 16% up from the bottom.
        let x = 180
        let y = 640 - Int(640 * 0.16) - 12
        let plain = pixel(of: before, x: x, y: y)
        let captioned = pixel(of: during, x: x, y: y)
        #expect(plain.b > 200 && plain.r < 60 && plain.g < 60)       // just the blue frame
        #expect(captioned.b < 180 || captioned.r > 120)              // box or text drawn over it
        // Away from the caption the frame is untouched, and turned upright
        // rather than cropped sideways: red fills the top.
        let top = pixel(of: during, x: x, y: 60)
        #expect(top.r > 200 && top.b < 60 && top.g < 60)
    }
}
