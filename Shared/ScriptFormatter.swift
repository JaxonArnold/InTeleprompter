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
    /// The markup color name ("red", …) for user-applied color; nil for
    /// uncolored spans and speaker cues.
    var colorName: String? = nil
}

struct ScriptStyle: OptionSet {
    let rawValue: Int
    static let bold = ScriptStyle(rawValue: 1 << 0)
    static let italic = ScriptStyle(rawValue: 1 << 1)
}

extension NSAttributedString.Key {
    /// Editor-side formatting — the editable form of script markup. The
    /// editor derives fonts and colors from these; `markup(from:)` turns
    /// them back into markup for storage.
    static let scriptBold = NSAttributedString.Key("InTeleprompterScriptBold")
    static let scriptItalic = NSAttributedString.Key("InTeleprompterScriptItalic")
    /// A color name from `ScriptPalette.namedColors`.
    static let scriptColor = NSAttributedString.Key("InTeleprompterScriptColor")
}

/// Parses the lightweight script markup in one pass. Everything downstream —
/// rendering, voice tracking, word counts — works on the display text, so
/// markup never leaks into the prompter or the speech matcher.
///
/// Supported markup:
/// - `**bold**`, `*italic*`, `***both***`; bold and italic may overlap or
///   abut freely (`**a***b*` is bold "a" then italic "b")
/// - `[red]colored[/red]` — red, orange, yellow, green, blue, purple, pink
/// - `\*`, `\[`, `\\` — literal characters
/// - `SPEAKER:` cue at line start (2–20 uppercase letters/digits/spaces),
///   rendered bold in a per-name color and excluded from voice tracking
///
/// Markup never spans lines. Unmatched or malformed markers are left as
/// literal text.
enum ScriptFormatter {

    static func parse(_ body: String) -> FormattedScript {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        var output = Output()
        var cueRanges: [NSRange] = []

        let lines = normalized.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            var content = rawLine[...]

            if let cue = speakerCue(in: content) {
                let start = output.length
                output.appendCue(String(cue.text), color: ScriptPalette.speakerColor(for: String(cue.name)))
                cueRanges.append(NSRange(location: start, length: output.length - start))
                content = content[cue.text.endIndex...]
            }

            parseInline(content, into: &output)

            if index < lines.count - 1 { output.appendPlain("\n") }
        }

        return FormattedScript(text: output.text, styles: output.styles, speakerCueRanges: cueRanges)
    }

    // MARK: - Inline markup

    /// A bold/italic/color marker found while scanning a line. Opening
    /// markers stay provisional until a matching close turns up; whatever is
    /// still unmatched at the end of the line is emitted as literal text.
    private struct Marker {
        enum Kind: Equatable {
            case bold, italic, color(String)
        }
        let kind: Kind
        let opens: Bool
        let raw: String
        /// Position in the token list, for the non-empty-content check.
        let tokenIndex: Int
        var matched = false
    }

    private enum Token {
        case text(String)
        case marker(Int)
    }

    private static func parseInline(_ line: Substring, into output: inout Output) {
        var tokens: [Token] = []
        var markers: [Marker] = []
        var literal = ""
        var lastTextToken = -1
        var openBold: Int?
        var openItalic: Int?
        var openColors: [Int] = []

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            tokens.append(.text(literal))
            lastTextToken = tokens.count - 1
            literal = ""
        }

        func addMarker(_ kind: Marker.Kind, opens: Bool, raw: String) -> Int {
            flushLiteral()
            markers.append(Marker(kind: kind, opens: opens, raw: raw, tokenIndex: tokens.count))
            tokens.append(.marker(markers.count - 1))
            return markers.count - 1
        }

        /// Closes `opener` if anything was emitted since it — `**` around
        /// nothing stays literal.
        func close(_ opener: Int, raw: String) -> Bool {
            flushLiteral()
            guard lastTextToken > markers[opener].tokenIndex else { return false }
            let closer = addMarker(markers[opener].kind, opens: false, raw: raw)
            markers[opener].matched = true
            markers[closer].matched = true
            return true
        }

        func toggleBold() {
            if let opener = openBold {
                if close(opener, raw: "**") { openBold = nil } else { literal += "**" }
            } else {
                openBold = addMarker(.bold, opens: true, raw: "**")
            }
        }

        func toggleItalic() {
            if let opener = openItalic {
                if close(opener, raw: "*") { openItalic = nil } else { literal += "*" }
            } else {
                openItalic = addMarker(.italic, opens: true, raw: "*")
            }
        }

        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]

            if c == "\\" {
                let next = line.index(after: i)
                if next < line.endIndex, "\\*[".contains(line[next]) {
                    literal.append(line[next])
                    i = line.index(after: next)
                    continue
                }
            }

            if c == "*" {
                var end = i
                while end < line.endIndex, line[end] == "*" { end = line.index(after: end) }
                let count = line.distance(from: i, to: end)
                switch count {
                case 1:
                    toggleItalic()
                case 2:
                    toggleBold()
                case 3:
                    // The current state decides what a triple means: close
                    // whatever's open (innermost first), open whatever isn't.
                    switch (openBold, openItalic) {
                    case let (bold?, italic?):
                        if italic > bold { toggleItalic(); toggleBold() } else { toggleBold(); toggleItalic() }
                    case (nil, _?):
                        toggleItalic(); toggleBold()
                    default:
                        toggleBold(); toggleItalic()
                    }
                default:
                    literal += String(repeating: "*", count: count)
                }
                i = end
                continue
            }

            if c == "[", let tag = colorTag(at: i, in: line) {
                let raw = String(line[i..<tag.end])
                if !tag.closes {
                    openColors.append(addMarker(.color(tag.name), opens: true, raw: raw))
                } else if let k = openColors.lastIndex(where: { markers[$0].kind == .color(tag.name) }),
                          close(openColors[k], raw: raw) {
                    openColors.remove(at: k)
                } else {
                    literal += raw
                }
                i = tag.end
                continue
            }

            literal.append(c)
            i = line.index(after: i)
        }
        flushLiteral()

        // Emit with the matched markers applied; the rest are literal text.
        var style: ScriptStyle = []
        var colors: [String] = []
        for token in tokens {
            switch token {
            case .text(let text):
                output.append(text, style: style, colorName: colors.last)
            case .marker(let index):
                let marker = markers[index]
                guard marker.matched else {
                    output.append(marker.raw, style: style, colorName: colors.last)
                    continue
                }
                switch marker.kind {
                case .bold:
                    if marker.opens { style.insert(.bold) } else { style.remove(.bold) }
                case .italic:
                    if marker.opens { style.insert(.italic) } else { style.remove(.italic) }
                case .color(let name):
                    if marker.opens {
                        colors.append(name)
                    } else if let k = colors.lastIndex(of: name) {
                        colors.remove(at: k)
                    }
                }
            }
        }
    }

    /// `[name]` or `[/name]` for a known color, case-insensitive.
    private static func colorTag(at start: Substring.Index,
                                 in line: Substring) -> (name: String, closes: Bool, end: Substring.Index)? {
        let afterBracket = line.index(after: start)
        let limit = line.index(afterBracket, offsetBy: 9, limitedBy: line.endIndex) ?? line.endIndex
        guard let close = line[afterBracket..<limit].firstIndex(of: "]") else { return nil }
        var inner = line[afterBracket..<close]
        let closes = inner.first == "/"
        if closes { inner = inner.dropFirst() }
        let name = inner.lowercased()
        guard ScriptPalette.namedColors[name] != nil else { return nil }
        return (name, closes, line.index(after: close))
    }

    // MARK: - Speaker cues

    /// The "NAME:" prefix of a line, if it starts with a speaker cue.
    static func speakerCue(in line: Substring) -> (text: Substring, name: Substring)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = line[line.startIndex..<colon]
        guard isSpeakerName(name) else { return nil }
        return (line[line.startIndex...colon], name)
    }

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

    // MARK: - Output accumulation

    private struct Output {
        var text = ""
        /// UTF-16 length of `text`, tracked to avoid re-measuring per span.
        var length = 0
        var styles: [StyleSpan] = []

        mutating func appendPlain(_ string: String) {
            text += string
            length += string.utf16.count
        }

        mutating func appendCue(_ string: String, color: UIColor) {
            let count = string.utf16.count
            styles.append(StyleSpan(range: NSRange(location: length, length: count),
                                    style: [.bold], color: color))
            appendPlain(string)
        }

        /// Appends styled text, extending the previous span when the style
        /// continues (e.g. across an escaped character or a literal marker).
        mutating func append(_ string: String, style: ScriptStyle, colorName: String?) {
            let count = string.utf16.count
            guard count > 0 else { return }
            if !style.isEmpty || colorName != nil {
                let color = colorName.flatMap { ScriptPalette.namedColors[$0] }
                if let last = styles.last,
                   NSMaxRange(last.range) == length,
                   last.style == style, last.colorName == colorName, last.color == color {
                    styles[styles.count - 1] = StyleSpan(
                        range: NSRange(location: last.range.location, length: last.range.length + count),
                        style: style, color: color, colorName: colorName)
                } else {
                    styles.append(StyleSpan(range: NSRange(location: length, length: count),
                                            style: style, color: color, colorName: colorName))
                }
            }
            appendPlain(string)
        }
    }
}

// MARK: - Editor conversion

extension ScriptFormatter {

    /// The formatting attribute keys the editor reads and writes.
    static let formatKeys: [NSAttributedString.Key] = [.scriptBold, .scriptItalic, .scriptColor]

    /// Markup → display text carrying `.scriptBold`/`.scriptItalic`/
    /// `.scriptColor` attributes, for editing. Speaker cues carry none: their
    /// look is derived, not stored.
    static func editableText(from body: String) -> NSMutableAttributedString {
        let formatted = parse(body)
        let result = NSMutableAttributedString(string: formatted.text)
        let cueRanges = Set(formatted.speakerCueRanges)
        for span in formatted.styles where !cueRanges.contains(span.range) {
            var attributes: [NSAttributedString.Key: Any] = [:]
            if span.style.contains(.bold) { attributes[.scriptBold] = true }
            if span.style.contains(.italic) { attributes[.scriptItalic] = true }
            if let name = span.colorName { attributes[.scriptColor] = name }
            if !attributes.isEmpty { result.addAttributes(attributes, range: span.range) }
        }
        return result
    }

    /// Editable text → markup, the inverse of `editableText(from:)`. Literal
    /// `*`, `\`, and tag-like `[` are escaped, so whatever was typed comes
    /// back exactly as typed. Formatting on newlines and speaker cues is
    /// ignored (markup can't express it).
    static func markup(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        let length = string.length
        var out = ""
        var lineStart = 0

        while true {
            let newline = string.range(of: "\n", options: [],
                                       range: NSRange(location: lineStart, length: length - lineStart))
            let lineEnd = newline.location == NSNotFound ? length : newline.location
            let line = string.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))

            var contentStart = lineStart
            if let cue = speakerCue(in: line[...]) {
                out += cue.text
                contentStart += cue.text.utf16.count
            }

            var state = InlineFormat()
            var pending = ""
            if contentStart < lineEnd {
                text.enumerateAttributes(in: NSRange(location: contentStart, length: lineEnd - contentStart)) {
                    attributes, range, _ in
                    let format = InlineFormat(attributes)
                    if format != state {
                        out += escaped(pending)
                        pending = ""
                        out += transition(from: state, to: format)
                        state = format
                    }
                    pending += string.substring(with: range)
                }
            }
            out += escaped(pending)
            out += transition(from: state, to: InlineFormat())

            guard newline.location != NSNotFound else { break }
            out += "\n"
            lineStart = lineEnd + 1
        }
        return out
    }

    private struct InlineFormat: Equatable {
        var bold = false
        var italic = false
        var color: String?

        init() {}

        init(_ attributes: [NSAttributedString.Key: Any]) {
            bold = attributes[.scriptBold] as? Bool ?? false
            italic = attributes[.scriptItalic] as? Bool ?? false
            if let name = attributes[.scriptColor] as? String, ScriptPalette.namedColors[name] != nil {
                color = name
            }
        }
    }

    /// The markup between two runs. Bold/italic changes always form a single
    /// star run of 1–3 characters, which the parser decodes against the same
    /// open state: e.g. `***` after bold text means "close bold, open italic".
    private static func transition(from current: InlineFormat, to next: InlineFormat) -> String {
        var out = ""
        if current.color != next.color, let color = current.color { out += "[/\(color)]" }
        let stars = (current.bold != next.bold ? 2 : 0) + (current.italic != next.italic ? 1 : 0)
        out += String(repeating: "*", count: stars)
        if current.color != next.color, let color = next.color { out += "[\(color)]" }
        return out
    }

    private static func escaped(_ run: String) -> String {
        guard run.contains(where: { "\\*[".contains($0) }) else { return run }
        var out = ""
        var i = run.startIndex
        while i < run.endIndex {
            let c = run[i]
            switch c {
            case "\\", "*":
                out += "\\"
            case "[" where colorTag(at: i, in: run[...]) != nil:
                out += "\\"
            default:
                break
            }
            out.append(c)
            i = run.index(after: i)
        }
        return out
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

    /// Display order for color pickers.
    static let colorOrder = ["red", "orange", "yellow", "green", "blue", "purple", "pink"]

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
