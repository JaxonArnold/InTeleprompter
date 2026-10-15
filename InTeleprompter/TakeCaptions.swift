import AVFoundation
import CoreImage
import UIKit

/// A script word as captions show it: with its punctuation, and whether it
/// runs straight into the next word ("3-" + "second").
nonisolated struct ScriptToken: Equatable, Sendable {
    let text: String
    let normalized: String
    var gluedToNext = false
}

nonisolated struct CaptionWord: Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
    var gluedToNext = false
}

/// One caption on screen, in seconds of the edited video.
nonisolated struct CaptionCue: Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

/// Captions built from the script itself, timed by what was heard. Speech
/// recognizers misspell names and jargon; the script doesn't, so wherever
/// the take follows the script, the captions use the script's words.
nonisolated enum TakeCaptions {

    // MARK: - Script text

    /// Display text for each script word: the word plus punctuation attached
    /// to it. Characters between two words go to the earlier word unless
    /// whitespace separates them, so nothing is shown twice.
    static func scriptTokens(for words: [ScriptWord], in text: String) -> [ScriptToken] {
        guard !words.isEmpty else { return [] }
        let string = text as NSString
        func isSpace(_ index: Int) -> Bool {
            UnicodeScalar(string.character(at: index)).map(CharacterSet.whitespacesAndNewlines.contains) ?? false
        }

        var starts = words.map(\.range.location)
        var ends = words.map { NSMaxRange($0.range) }
        var glued = [Bool](repeating: false, count: words.count)

        while starts[0] > 0, !isSpace(starts[0] - 1) { starts[0] -= 1 }
        for i in words.indices.dropLast() {
            let gapEnd = words[i + 1].range.location
            var firstSpace = ends[i]
            while firstSpace < gapEnd, !isSpace(firstSpace) { firstSpace += 1 }
            if firstSpace == gapEnd {
                ends[i] = gapEnd
                glued[i] = true
            } else {
                ends[i] = firstSpace
                var lastSpace = gapEnd - 1
                while !isSpace(lastSpace) { lastSpace -= 1 }
                starts[i + 1] = lastSpace + 1
            }
        }
        let last = words.count - 1
        while ends[last] < string.length, !isSpace(ends[last]) { ends[last] += 1 }

        return words.indices.map { i in
            ScriptToken(text: string.substring(with: NSRange(location: starts[i], length: ends[i] - starts[i])),
                        normalized: words[i].normalized, gluedToNext: glued[i])
        }
    }

    // MARK: - Timing

    /// Caption words in take time. Where the take follows the script, the
    /// script's words are used (including ones the recognizer misheard or
    /// dropped); off-script words use what the recognizer heard; fillers are
    /// left out.
    static func captionWords(spoken: [SpokenWord], script: [ScriptToken]) -> [CaptionWord] {
        let alignment = TakeAnalyzer.align(spoken.map(\.text), to: script.map(\.normalized))
        let isFiller = TakeAnalyzer.fillerFlags(spoken.map(\.text))
        var words: [CaptionWord] = []

        func addSpoken(_ range: Range<Int>) {
            for i in range where !isFiller[i] {
                words.append(CaptionWord(text: spoken[i].shown, start: spoken[i].start, end: spoken[i].end))
            }
        }
        func addScript(_ range: Range<Int>, from start: Double, to end: Double) {
            let share = max(0, end - start) / Double(range.count)
            for (k, j) in range.enumerated() {
                let wordStart = start + share * Double(k)
                words.append(CaptionWord(text: script[j].text, start: wordStart, end: wordStart + share,
                                         gluedToNext: script[j].gluedToNext))
            }
        }

        let matched = alignment.indices.filter { alignment[$0] != nil }
        guard let first = matched.first, let last = matched.last else {
            addSpoken(0..<spoken.count)
            return words
        }
        addSpoken(0..<first)
        for (n, p) in matched.enumerated() {
            let s = alignment[p]!
            words.append(CaptionWord(text: script[s].text, start: spoken[p].start, end: spoken[p].end,
                                     gluedToNext: script[s].gluedToNext))
            guard n + 1 < matched.count else { break }
            let q = matched[n + 1]
            let skippedScript = (s + 1)..<alignment[q]!
            let between = (p + 1)..<q
            if skippedScript.isEmpty {
                // Extra words: ad-libs (kept) or fillers (dropped).
                addSpoken(between)
            } else if between.isEmpty {
                // The recognizer dropped a short word or two; a longer gap
                // means the speaker skipped ahead, so those aren't shown.
                if skippedScript.count <= 2 {
                    addScript(skippedScript, from: spoken[p].end, to: spoken[q].start)
                }
            } else if skippedScript.count <= between.count + 3, between.count <= skippedScript.count + 3 {
                // Misheard script words: show what the script says.
                addScript(skippedScript, from: spoken[between.lowerBound].start, to: spoken[between.upperBound - 1].end)
            } else {
                addSpoken(between)
            }
        }
        addSpoken((last + 1)..<spoken.count)
        return words
    }

    /// Moves words onto the edited timeline; words that were cut are dropped.
    static func edited(_ words: [CaptionWord], kept: [Range<Double>]) -> [CaptionWord] {
        words.compactMap { word in
            let middle = (word.start + word.end) / 2
            guard kept.contains(where: { $0.contains(middle) }) else { return nil }
            return CaptionWord(text: word.text,
                               start: TakeAnalyzer.editedTime(forSourceTime: word.start, kept: kept),
                               end: TakeAnalyzer.editedTime(forSourceTime: word.end, kept: kept),
                               gluedToNext: word.gluedToNext)
        }
    }

    // MARK: - Cues

    /// Short phrases sized for phone screens: a new caption at each
    /// sentence end, after a pause, or once the line gets long.
    static func cues(from words: [CaptionWord], maxCharacters: Int = 32,
                     maxDuration: Double = 3.5, maxGap: Double = 0.6) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        var current: [CaptionWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            cues.append(CaptionCue(text: joined(current), start: first.start, end: last.end))
            current = []
        }

        for word in words {
            // A line may run a little long to finish its sentence, rather
            // than strand the last word on a caption of its own.
            let endsSentence = word.text.last.map { ".!?".contains($0) } ?? false
            let limit = endsSentence ? maxCharacters + 10 : maxCharacters
            if let last = current.last,
               joined(current + [word]).count > limit
                || word.end - current[0].start > maxDuration
                || word.start - last.end > maxGap {
                flush()
            }
            current.append(word)
            if endsSentence {
                flush()
            } else if word.text.last == ",", joined(current).count >= maxCharacters / 2 {
                // Past halfway, a comma is a natural place to break.
                flush()
            }
        }
        flush()

        // Linger a little after the last word, at least long enough to read,
        // but never overlap the next caption.
        return cues.enumerated().map { index, cue in
            let nextStart = index + 1 < cues.count ? cues[index + 1].start : .infinity
            let end = min(nextStart, max(cue.end + 0.3, cue.start + 0.8))
            return CaptionCue(text: cue.text, start: cue.start, end: max(end, cue.start))
        }
    }

    private static func joined(_ words: [CaptionWord]) -> String {
        var text = ""
        for (index, word) in words.enumerated() {
            if index > 0, !words[index - 1].gluedToNext { text += " " }
            text += word.text
        }
        return text
    }

    // MARK: - SubRip

    /// A standard .srt subtitle file — every video app and platform reads it.
    static func srt(_ cues: [CaptionCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}

// MARK: - Burned-in captions

/// Draws captions into the video frames. The same composition drives the
/// editor's preview and the export, so what you see is what's saved.
nonisolated enum CaptionRenderer {

    private struct Overlay {
        let start: Double
        let end: Double
        let image: CIImage
    }

    /// Prepared once; read from the frame callback's background threads.
    private final class Overlays: @unchecked Sendable {
        let items: [Overlay]
        init(_ items: [Overlay]) { self.items = items }

        func image(at time: Double) -> CIImage? {
            items.first { $0.start <= time && time < $0.end }?.image
        }
    }

    static func videoComposition(for asset: AVAsset, cues: [CaptionCue]) async throws -> AVVideoComposition? {
        guard !cues.isEmpty, let size = try await renderSize(of: asset) else { return nil }
        // Drawing every caption takes a moment; keep it off the main thread.
        let overlays = await Task.detached(priority: .userInitiated) {
            Overlays(cues.compactMap { overlay(for: $0, in: size) })
        }.value
        return try await AVVideoComposition.videoComposition(with: asset) { request in
            if let caption = overlays.image(at: request.compositionTime.seconds) {
                request.finish(with: caption.composited(over: request.sourceImage), context: nil)
            } else {
                request.finish(with: request.sourceImage, context: nil)
            }
        }
    }

    /// Frame size once the camera's rotation is applied.
    private static func renderSize(of asset: AVAsset) async throws -> CGSize? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// White text on a dark rounded box, centered in the lower part of the
    /// frame — above where social apps put their own buttons.
    private static func overlay(for cue: CaptionCue, in frame: CGSize) -> Overlay? {
        let fontSize = (min(frame.width, frame.height) * 0.055).rounded()
        let base = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: fontSize) } ?? base
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: cue.text, attributes: [
            .font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph,
        ])

        let padding = CGSize(width: fontSize * 0.55, height: fontSize * 0.3)
        let maxTextWidth = frame.width * 0.86 - padding.width * 2
        let textBounds = text.boundingRect(with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading],
                                           context: nil).integral
        let box = CGSize(width: textBounds.width + padding.width * 2, height: textBounds.height + padding.height * 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: box, format: format).image { context in
            context.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
            context.cgContext.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: box),
                                             cornerWidth: fontSize * 0.35, cornerHeight: fontSize * 0.35,
                                             transform: nil))
            context.cgContext.fillPath()
            text.draw(with: CGRect(x: padding.width, y: padding.height,
                                   width: textBounds.width, height: textBounds.height),
                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        guard let cgImage = image.cgImage else { return nil }
        // Core Image's origin is the bottom-left corner.
        let origin = CGPoint(x: ((frame.width - box.width) / 2).rounded(), y: (frame.height * 0.16).rounded())
        return Overlay(start: cue.start, end: cue.end,
                       image: CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: origin.x,
                                                                                          y: origin.y)))
    }
}
