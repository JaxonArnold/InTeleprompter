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
