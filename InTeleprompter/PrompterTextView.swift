import SwiftUI
import UIKit

/// Renders the script with UIKit text layout (TextKit 1) so the vertical
/// position of every word is known exactly. The voice tracker uses those
/// positions to scroll the prompter to the word currently being read.
struct PrompterTextView: UIViewRepresentable {
    let text: String
    let fontSize: Double
    let lineSpacing: Double
    let width: CGFloat
    /// UTF-16 ranges of the script's words (from ScriptTokenizer).
    let wordRanges: [NSRange]
    /// Words before this index render dimmed — already read by the speaker.
    let readWordCount: Int
    /// Called after (re)layout with the total text height and the vertical
    /// midpoint of every word, in text coordinates.
    let onLayout: (_ height: CGFloat, _ wordYPositions: [CGFloat]) -> Void

    private static let readColor = UIColor.white.withAlphaComponent(0.4)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1, to match the coordinator's measuring stack exactly.
        let view = UITextView(usingTextLayoutManager: false)
        view.isScrollEnabled = false
        view.isEditable = false
        view.isSelectable = false
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let signature = Signature(textLength: text.utf16.count, fontSize: fontSize,
                                  lineSpacing: lineSpacing, width: width)
        if context.coordinator.signature != signature {
            context.coordinator.signature = signature
            context.coordinator.appliedReadCount = 0

            let attributed = Self.attributedScript(text, fontSize: fontSize, lineSpacing: lineSpacing)
            view.attributedText = attributed

            let (height, positions) = context.coordinator.measure(attributed, width: width, wordRanges: wordRanges)
            let onLayout = onLayout
            DispatchQueue.main.async {
                onLayout(height, positions)
            }
        }
        applyReadDimming(in: view, coordinator: context.coordinator)
    }

    /// Recolors only the words whose read state changed. Foreground color
    /// edits don't invalidate layout, so word positions stay valid.
    private func applyReadDimming(in view: UITextView, coordinator: Coordinator) {
        let count = min(max(readWordCount, 0), wordRanges.count)
        let applied = coordinator.appliedReadCount
        guard count != applied else { return }

        let storage = view.textStorage
        storage.beginEditing()
        if count > applied {
            for range in wordRanges[applied..<count] {
                storage.addAttribute(.foregroundColor, value: Self.readColor, range: range)
            }
        } else {
            for range in wordRanges[count..<applied] {
                storage.addAttribute(.foregroundColor, value: UIColor.white, range: range)
            }
        }
        storage.endEditing()
        coordinator.appliedReadCount = count
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        CGSize(width: width, height: max(context.coordinator.height, 1))
    }

    struct Signature: Equatable {
        /// UTF-16 length stands in for the text itself: O(1) to compare on
        /// the 60 fps render path, and the script can't change mid-session.
        let textLength: Int
        let fontSize: Double
        let lineSpacing: Double
        let width: CGFloat
    }

    final class Coordinator {
        var signature: Signature?
        var appliedReadCount = 0
        private(set) var height: CGFloat = 0

        private let textStorage = NSTextStorage()
        private let layoutManager = NSLayoutManager()
        private let textContainer = NSTextContainer(size: .zero)

        init() {
            textContainer.lineFragmentPadding = 0
            layoutManager.addTextContainer(textContainer)
            textStorage.addLayoutManager(layoutManager)
        }

        func measure(_ attributed: NSAttributedString,
                     width: CGFloat,
                     wordRanges: [NSRange]) -> (height: CGFloat, wordYPositions: [CGFloat]) {
            textStorage.setAttributedString(attributed)
            textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)

            height = layoutManager.usedRect(for: textContainer).height.rounded(.up)
            let positions = wordRanges.map { range -> CGFloat in
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).midY
            }
            return (height, positions)
        }
    }

    static func attributedScript(_ text: String, fontSize: Double, lineSpacing: Double) -> NSAttributedString {
        let base = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.rounded)
            .map { UIFont(descriptor: $0, size: fontSize) } ?? base

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing

        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = CGSize(width: 0, height: 1)

        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
            .shadow: shadow,
        ])
    }
}
