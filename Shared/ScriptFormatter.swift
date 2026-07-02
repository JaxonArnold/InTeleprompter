import Foundation
import UIKit

/// The result of parsing script markup: plain display text (what gets
/// rendered and voice-tracked), styled ranges in display-text coordinates,
/// and the speaker-cue ranges that are displayed but not spoken aloud.
struct FormattedScript {
    /// The script with all markup stripped.
    let text: String
    /// Bold/italic/color spans, in display-text UTF-16 coordinates.
    let styles: [StyleSpan]
    /// "NAME:" ranges, in display-text UTF-16 coordinates. The voice
    /// tracker skips these — you don't read cues aloud.
    let speakerCueRanges: [NSRange]

    /// Word count of the spoken parts (display words minus cue words).
    var spokenWordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count - speakerCueRanges.count
    }
}

struct StyleSpan {
    let range: NSRange
    let style: ScriptStyle
    let color: UIColor?
}

struct ScriptStyle: OptionSet {
    let rawValue: Int
    static let bold = ScriptStyle(rawValue: 1 << 0)
    static let italic = ScriptStyle(rawValue: 1 << 1)
}

/// Parses the lightweight script markup in one pass. Everything downstream —
/// rendering, voice tracking, word counts — works on the display text, so
/// markup never leaks into the prompter or the speech matcher.
///
/// Supported markup:
/// - `**bold**`, `*italic*`
/// - `[red]colored[/red]` — red, orange, yellow, green, blue, purple, pink
/// - `SPEAKER:` cue at line start (2–20 uppercase letters/digits/spaces),
///   rendered bold in a per-name color and excluded from voice tracking
///
/// Unmatched or malformed markers are left as literal text.
enum ScriptFormatter {

    static func parse(_ body: String) -> FormattedScript {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        var result = ""
        var styles: [StyleSpan] = []
        var cueRanges: [NSRange] = []

        let lines = normalized.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            var content = rawLine[...]

            // Speaker cue: "NAME:" at line start, all caps.
            if let colon = content.firstIndex(of: ":") {
                let name = content[content.startIndex..<colon]
                if isSpeakerName(name) {
                    let start = utf16Length(of: result)
                    let cue = content[content.startIndex...colon]
                    result += cue
                    let range = NSRange(location: start, length: utf16Length(of: cue))
                    styles.append(StyleSpan(range: range, style: [.bold],
                                            color: ScriptPalette.speakerColor(for: String(name))))
                    cueRanges.append(range)
                    content = content[content.index(after: colon)...]
                }
            }

            parseInline(content, into: &result, styles: &styles,
                        inheritedColor: nil, inheritedStyle: [])

            if index < lines.count - 1 { result.append("\n") }
        }

        return FormattedScript(text: result, styles: styles, speakerCueRanges: cueRanges)
    }

    // MARK: - Inline markup

    private static func parseInline(_ text: Substring,
                                    into result: inout String,
                                    styles: inout [StyleSpan],
                                    inheritedColor: UIColor?,
                                    inheritedStyle: ScriptStyle) {
        var i = text.startIndex
        var plainRun = ""

        // Emits the accumulated literal run, styled if we're inside markup.
        func flushPlainRun() {
            guard !plainRun.isEmpty else { return }
            let start = utf16Length(of: result)
            result += plainRun
            if inheritedColor != nil || !inheritedStyle.isEmpty {
                styles.append(StyleSpan(
                    range: NSRange(location: start, length: utf16Length(of: plainRun)),
                    style: inheritedStyle,
                    color: inheritedColor
                ))
            }
            plainRun = ""
        }

        while i < text.endIndex {
            // Bold: **...**
            if text[i...].hasPrefix("**") {
                let contentStart = text.index(i, offsetBy: 2)
                if let close = text[contentStart...].range(of: "**"), close.lowerBound > contentStart {
                    flushPlainRun()
                    parseInline(text[contentStart..<close.lowerBound],
                                into: &result, styles: &styles,
                                inheritedColor: inheritedColor,
                                inheritedStyle: inheritedStyle.union(.bold))
                    i = close.upperBound
                    continue
                }
            }
            // Italic: *...*
            if text[i] == "*" {
                let contentStart = text.index(after: i)
                if let close = text[contentStart...].range(of: "*"), close.lowerBound > contentStart {
                    flushPlainRun()
                    parseInline(text[contentStart..<close.lowerBound],
                                into: &result, styles: &styles,
                                inheritedColor: inheritedColor,
                                inheritedStyle: inheritedStyle.union(.italic))
                    i = close.upperBound
                    continue
                }
            }
            // Color: [red]...[/red]
            if text[i] == "[", let tagEnd = text[i...].firstIndex(of: "]") {
                let name = text[text.index(after: i)..<tagEnd].lowercased()
                if let color = ScriptPalette.namedColors[name] {
                    let contentStart = text.index(after: tagEnd)
                    let closeTag = "[/\(name)]"
                    if let close = text[contentStart...].range(of: closeTag), close.lowerBound > contentStart {
                        flushPlainRun()
                        parseInline(text[contentStart..<close.lowerBound],
                                    into: &result, styles: &styles,
                                    inheritedColor: color,
                                    inheritedStyle: inheritedStyle)
                        i = close.upperBound
                        continue
                    }
                }
            }
            plainRun.append(text[i])
            i = text.index(after: i)
        }
        flushPlainRun()
    }

    // MARK: - Speaker cues

    /// 2–20 chars, uppercase letters/digits/spaces, at least one letter —
    /// so "JACK:" and "SPEAKER 1:" are cues but "Jack:" and "Note:" are not.
    private static func isSpeakerName(_ candidate: Substring) -> Bool {
        guard (2...20).contains(candidate.count) else { return false }
        var hasLetter = false
        for scalar in candidate.unicodeScalars {
            if CharacterSet.uppercaseLetters.contains(scalar) {
                hasLetter = true
            } else if !CharacterSet.decimalDigits.contains(scalar), scalar != " " {
                return false
            }
        }
        return hasLetter
    }

    private static func utf16Length(of string: String) -> Int {
        (string as NSString).length
    }

    private static func utf16Length(of string: Substring) -> Int {
        (string as NSString).length
    }
}

/// Emphasis colors by name, plus a stable per-name color for speaker cues.
enum ScriptPalette {
    static let namedColors: [String: UIColor] = [
        "red": .systemRed,
        "orange": .systemOrange,
        "yellow": .systemYellow,
        "green": .systemGreen,
        "blue": .systemBlue,
        "purple": .systemPurple,
        "pink": .systemPink,
    ]

    private static let speakerColors: [UIColor] = [
        .systemYellow, .systemGreen, .systemBlue, .systemOrange,
        .systemPurple, .systemPink, .systemTeal, .systemIndigo,
    ]

    /// Same speaker name always lands on the same color.
    static func speakerColor(for name: String) -> UIColor {
        var hash = 0
        for scalar in name.unicodeScalars {
            hash = (hash &* 31) &+ Int(scalar.value)
        }
        return speakerColors[abs(hash) % speakerColors.count]
    }
}
