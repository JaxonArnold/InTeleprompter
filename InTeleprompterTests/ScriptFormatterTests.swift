import Foundation
import Testing
import UIKit
@testable import InTeleprompter

// MARK: - Script formatter

struct ScriptFormatterTests {

    /// Extracts a display-text substring for a style span.
    private func substring(_ text: String, _ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

    @Test func boldIsParsedAndStripped() {
        let result = ScriptFormatter.parse("say **bold** words")
        #expect(result.text == "say bold words")
        #expect(result.styles.count == 1)
        #expect(result.styles[0].style == [.bold])
        #expect(substring(result.text, result.styles[0].range) == "bold")
    }

    @Test func italicIsParsedAndStripped() {
        let result = ScriptFormatter.parse("read *softly* here")
        #expect(result.text == "read softly here")
        #expect(result.styles.count == 1)
        #expect(result.styles[0].style == [.italic])
        #expect(substring(result.text, result.styles[0].range) == "softly")
    }

    @Test func colorIsParsedAndStripped() {
        let result = ScriptFormatter.parse("[red]stop[/red] now")
        #expect(result.text == "stop now")
        #expect(result.styles.count == 1)
        #expect(result.styles[0].color == .systemRed)
        #expect(substring(result.text, result.styles[0].range) == "stop")
    }

    @Test func nestedBoldInsideColor() {
        let result = ScriptFormatter.parse("[blue]**deep**[/blue]")
        #expect(result.text == "deep")
        #expect(result.styles.count == 1)
        #expect(result.styles[0].style == [.bold])
        #expect(result.styles[0].color == .systemBlue)
    }

    @Test func unmatchedMarkersStayLiteral() {
        #expect(ScriptFormatter.parse("**open").text == "**open")
        #expect(ScriptFormatter.parse("[red]open").text == "[red]open")
        #expect(ScriptFormatter.parse("[green]x[/red]").text == "[green]x[/red]")
        #expect(ScriptFormatter.parse("[notacolor]x[/notacolor]").text == "[notacolor]x[/notacolor]")
    }

    @Test func plainTextPassesThroughExactly() {
        let body = "line one\n\nline three — with emoji 🎬 and * a stray star"
        let result = ScriptFormatter.parse(body)
        #expect(result.text == body)
        #expect(result.styles.isEmpty)
        #expect(result.speakerCueRanges.isEmpty)
    }

    @Test func speakerCueIsStyledAndRecorded() {
        let result = ScriptFormatter.parse("JACK: Hello there\nSAM: Hi")
        #expect(result.text == "JACK: Hello there\nSAM: Hi")
        #expect(result.speakerCueRanges.count == 2)
        #expect(substring(result.text, result.speakerCueRanges[0]) == "JACK:")
        #expect(substring(result.text, result.speakerCueRanges[1]) == "SAM:")
        // Cue ranges also carry the speaker color + bold.
        #expect(result.styles.filter { $0.style == [.bold] }.count == 2)
        // Same name, same color — different names may differ, and must be stable.
        #expect(ScriptPalette.speakerColor(for: "JACK") == ScriptPalette.speakerColor(for: "JACK"))
    }

    @Test func mixedCaseNamesAreNotCues() {
        let result = ScriptFormatter.parse("Jack: hello")
        #expect(result.speakerCueRanges.isEmpty)
    }

    @Test func spokenWordCountExcludesCues() {
        let result = ScriptFormatter.parse("JACK: one two three")
        #expect(result.spokenWordCount == 3)   // four display tokens, minus the cue
    }

    @Test func scriptWordCountIgnoresMarkupAndCues() {
        let script = Script(title: "", body: "JACK: say **bold** [red]things[/red] now")
        #expect(script.wordCount == 4)   // say, bold, things, now
    }
}

// MARK: - Bundled sample scripts

struct SampleScriptTests {

    @Test func welcomeScriptIsPlainText() {
        let formatted = ScriptFormatter.parse(SampleScripts.welcome.body)
        #expect(formatted.text == SampleScripts.welcome.body)
        #expect(formatted.styles.isEmpty)
        #expect(formatted.speakerCueRanges.isEmpty)
    }

    @Test func formattingGuideParsesCleanly() {
        // Every marker in the guide must be matched — nothing left literal.
        let formatted = ScriptFormatter.parse(SampleScripts.formattingGuide.body)
        #expect(!formatted.text.contains("**"))
        #expect(!formatted.text.contains("[/"))
        #expect(formatted.speakerCueRanges.count == 2)   // HOST: and GUEST:
        #expect(formatted.styles.count >= 10)
        // Read-time estimate must be in a sane range for a script this size.
        #expect(SampleScripts.formattingGuide.wordCount > 50)
    }
}

// MARK: - Emphasis fonts

struct EmphasisFontTests {

    private let base = UIFont.systemFont(ofSize: 34, weight: .semibold)

    /// The numeric weight trait (-0.8 … 0.62); regular is 0, bold is 0.4.
    private func weightValue(of font: UIFont) -> Double? {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        return traits?[.weight] as? Double
    }

    @Test func boldIsHeavierThanPlainBold() {
        let font = PrompterTextView.spanFont(for: [.bold], base: base, size: 34)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        let plainBold = UIFont.systemFont(ofSize: 34, weight: .bold)
        #expect(weightValue(of: font)! > weightValue(of: plainBold)!)
    }

    /// Regression: the rounded family has no italic — the span font must
    /// actually carry the italic trait, not silently resolve to upright.
    @Test func italicActuallyCarriesItalicTrait() {
        let font = PrompterTextView.spanFont(for: [.italic], base: base, size: 34)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }

    @Test func plainStyleUsesBaseFont() {
        #expect(PrompterTextView.spanFont(for: [], base: base, size: 34) == base)
    }
}

// MARK: - Voice tracker with speaker cues

@MainActor
struct SpeakerCueTrackingTests {

    @Test func trackerSkipsCueWords() {
        let formatted = ScriptFormatter.parse("JACK: welcome back to the show")
        let tracker = SpeechScriptTracker(scriptText: formatted.text,
                                          excludingRanges: formatted.speakerCueRanges)
        #expect(tracker.words.map(\.normalized) == ["welcome", "back", "to", "the", "show"])
        // Matching starts at the first spoken word, not the cue.
        tracker.match("welcome")
        tracker.match("back")
        #expect(tracker.currentWordIndex == 2)
    }

    @Test func cueRangesDontDim() {
        // The cue isn't among the tracker's word ranges, so PrompterTextView's
        // read-dimming never touches it.
        let formatted = ScriptFormatter.parse("HOST: hello")
        let tracker = SpeechScriptTracker(scriptText: formatted.text,
                                          excludingRanges: formatted.speakerCueRanges)
        #expect(tracker.wordRanges.count == 1)
        #expect((formatted.text as NSString).substring(with: tracker.wordRanges[0]) == "hello")
    }
}

// MARK: - Combined and escaped markup

struct ScriptMarkupCombinationTests {

    private struct Span: Equatable {
        let text: String
        let style: ScriptStyle
        let color: String?
    }

    private func spans(_ body: String) -> [Span] {
        let result = ScriptFormatter.parse(body)
        return result.styles.map {
            Span(text: (result.text as NSString).substring(with: $0.range), style: $0.style, color: $0.colorName)
        }
    }

    @Test func tripleStarIsBoldItalic() {
        #expect(ScriptFormatter.parse("***both***").text == "both")
        #expect(spans("***both***") == [Span(text: "both", style: [.bold, .italic], color: nil)])
    }

    @Test func abuttingBoldThenItalic() {
        #expect(ScriptFormatter.parse("**a***b*").text == "ab")
        #expect(spans("**a***b*") == [Span(text: "a", style: [.bold], color: nil),
                                      Span(text: "b", style: [.italic], color: nil)])
    }

    @Test func abuttingItalicThenBold() {
        #expect(spans("*a***b**") == [Span(text: "a", style: [.italic], color: nil),
                                      Span(text: "b", style: [.bold], color: nil)])
    }

    @Test func boldInsideItalic() {
        #expect(spans("*a **b** c*") == [Span(text: "a ", style: [.italic], color: nil),
                                         Span(text: "b", style: [.bold, .italic], color: nil),
                                         Span(text: " c", style: [.italic], color: nil)])
    }

    @Test func italicEndingWithBold() {
        #expect(spans("**a *b***") == [Span(text: "a ", style: [.bold], color: nil),
                                       Span(text: "b", style: [.bold, .italic], color: nil)])
    }

    @Test func colorsNest() {
        #expect(spans("[red]a [blue]b[/blue] c[/red]") == [Span(text: "a ", style: [], color: "red"),
                                                           Span(text: "b", style: [], color: "blue"),
                                                           Span(text: " c", style: [], color: "red")])
    }

    @Test func escapesAreLiteral() {
        let result = ScriptFormatter.parse(#"\*not italic\* \[red]x[/red] C:\\path C:\Users"#)
        #expect(result.text == #"*not italic* [red]x[/red] C:\path C:\Users"#)
        #expect(result.styles.isEmpty)
    }

    @Test func markupNeverSpansLines() {
        #expect(ScriptFormatter.parse("**a\nb**").text == "**a\nb**")
    }

    @Test func emptyMarkupStaysLiteral() {
        #expect(ScriptFormatter.parse("[red][/red]").text == "[red][/red]")
        #expect(ScriptFormatter.parse("a **** b").text == "a **** b")
    }
}

// MARK: - Editor round trip

struct EditorRoundTripTests {

    /// Deterministic RNG so failures reproduce.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Per-character formatting, as far as markup can express it: nothing
    /// on newlines or inside speaker cues.
    private func formats(of text: NSAttributedString) -> [String] {
        let string = text.string as NSString
        var formats: [String] = []
        var cueEnd = 0
        for i in 0..<string.length {
            let unit = string.character(at: i)
            if i == 0 || string.character(at: i - 1) == 0x0A {
                let lineEnd = string.range(of: "\n", options: [],
                                           range: NSRange(location: i, length: string.length - i)).location
                let line = string.substring(with: NSRange(location: i, length: (lineEnd == NSNotFound ? string.length : lineEnd) - i))
                cueEnd = i + (ScriptFormatter.speakerCue(in: line[...])?.text.utf16.count ?? 0)
            }
            guard unit != 0x0A, i >= cueEnd else {
                formats.append("")
                continue
            }
            let attributes = text.attributes(at: i, effectiveRange: nil)
            let bold = attributes[.scriptBold] as? Bool ?? false
            let italic = attributes[.scriptItalic] as? Bool ?? false
            let color = attributes[.scriptColor] as? String ?? "-"
            formats.append("b\(bold) i\(italic) c\(color)")
        }
        return formats
    }

    @Test func randomFormattedTextSurvivesMarkup() {
        var rng = SplitMix64(state: 2026)
        let alphabet: [String] = ["a", "b", " ", "*", "**", "[", "]", "\\", "/", "red", "RED", "[red]",
                                  "[/blue]", "JK", ":", "\n", "é", "🎬", "AB:"]
        let colors: [String?] = [nil, nil, nil] + ScriptPalette.colorOrder.map { $0 }

        for iteration in 0..<3000 {
            let original = NSMutableAttributedString()
            for _ in 0..<Int.random(in: 0...8, using: &rng) {
                var piece = ""
                for _ in 0..<Int.random(in: 1...4, using: &rng) {
                    piece += alphabet.randomElement(using: &rng)!
                }
                var attributes: [NSAttributedString.Key: Any] = [:]
                if Bool.random(using: &rng) { attributes[.scriptBold] = true }
                if Bool.random(using: &rng) { attributes[.scriptItalic] = true }
                if let color = colors.randomElement(using: &rng)! { attributes[.scriptColor] = color }
                original.append(NSAttributedString(string: piece, attributes: attributes))
            }

            let markup = ScriptFormatter.markup(from: original)
            let restored = ScriptFormatter.editableText(from: markup)
            guard restored.string == original.string, formats(of: restored) == formats(of: original) else {
                Issue.record("Round trip #\(iteration) failed for markup: \(markup.debugDescription)")
                return
            }
        }
    }

    @Test func plainTextIsStoredUnchanged() {
        let plain = NSAttributedString(string: "Hello [there] — no stars, C:/path\nJACK: hi")
        #expect(ScriptFormatter.markup(from: plain) == "Hello [there] — no stars, C:/path\nJACK: hi")
    }

    @Test func literalMarkupCharactersAreEscaped() {
        let typed = NSAttributedString(string: "5 * 3 and [red] and \\")
        #expect(ScriptFormatter.markup(from: typed) == #"5 \* 3 and \[red] and \\"#)
    }

    @Test func formattingGuideRendersIdenticallyAfterEditing() {
        let guide = SampleScripts.formattingGuide.body
        let resaved = ScriptFormatter.markup(from: ScriptFormatter.editableText(from: guide))
        let before = ScriptFormatter.parse(guide)
        let after = ScriptFormatter.parse(resaved)
        #expect(after.text == before.text)
        #expect(after.speakerCueRanges == before.speakerCueRanges)
        #expect(after.styles.map(\.range) == before.styles.map(\.range))
        #expect(after.styles.map(\.style) == before.styles.map(\.style))
        #expect(after.styles.map(\.colorName) == before.styles.map(\.colorName))
    }
}
