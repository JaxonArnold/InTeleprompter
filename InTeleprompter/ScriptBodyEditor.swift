import SwiftUI
import UIKit

/// The script body editor. Shows formatting the way it will look — bold,
/// italic, colors, speaker cues — instead of raw markup, and formats the
/// selection from the edit menu or the bar above the keyboard. Scripts are
/// still stored as markup; this view converts in both directions.
struct ScriptBodyEditor: UIViewRepresentable {
    @Binding var markup: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        let coordinator = context.coordinator
        textView.delegate = coordinator
        textView.backgroundColor = .clear
        // Formatting goes through the commands below. This also makes pastes
        // arrive as plain text in the current style, not another app's fonts.
        textView.allowsEditingTextAttributes = false
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.inputAccessoryView = coordinator.makeFormatBar()
        coordinator.textView = textView
        coordinator.load(markup)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if markup != coordinator.lastMarkup {
            coordinator.load(markup)
        }
        if isFocused != textView.isFirstResponder {
            DispatchQueue.main.async { [isFocused] in
                guard textView.window != nil, isFocused != textView.isFirstResponder else { return }
                if isFocused { textView.becomeFirstResponder() } else { textView.resignFirstResponder() }
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ScriptBodyEditor
        weak var textView: UITextView?
        /// The markup the text view currently reflects, to tell this view's
        /// own binding writes apart from outside changes.
        var lastMarkup = ""
        /// Characters changed since the last restyle.
        private var pendingRestyle: NSRange?
        private var fontCache: [Int: UIFont] = [:]
        private weak var boldItem: UIBarButtonItem?
        private weak var italicItem: UIBarButtonItem?
        private weak var colorItem: UIBarButtonItem?

        init(parent: ScriptBodyEditor) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(contentSizeChanged),
                                                   name: UIContentSizeCategory.didChangeNotification,
                                                   object: nil)
        }

        // MARK: Loading and saving

        func load(_ markup: String) {
            guard let textView else { return }
            lastMarkup = markup
            pendingRestyle = nil
            let text = ScriptFormatter.editableText(from: markup)
            textView.textStorage.setAttributedString(text)
            restyle(NSRange(location: 0, length: text.length))
            textView.typingAttributes = typingAttributes(from: [:])
            updateFormatBar()
        }

        private func commit() {
            guard let textView else { return }
            let markup = ScriptFormatter.markup(from: textView.textStorage)
            lastMarkup = markup
            if parent.markup != markup { parent.markup = markup }
        }

        // MARK: Text view delegate

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            let edited = NSRange(location: range.location, length: (text as NSString).length)
            pendingRestyle = pendingRestyle.map { NSUnionRange($0, edited) } ?? edited
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            // Mid-composition (CJK input, dictation) the text isn't final, and
            // restyling marked text can disrupt the input method.
            guard textView.markedTextRange == nil else { return }
            var range = textView.selectedRange
            if let pending = pendingRestyle { range = NSUnionRange(range, pending) }
            pendingRestyle = nil
            restyle(range)
            commit()
            updateFormatBar()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            updateFormatBar()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return UIMenu(children: suggestedActions) }
            return UIMenu(children: [formatMenu()] + suggestedActions)
        }

        // MARK: Format commands

        @objc private func toggleBold() { toggle(.scriptBold, actionName: "Bold") }
        @objc private func toggleItalic() { toggle(.scriptItalic, actionName: "Italic") }

        @objc private func dismissKeyboard() {
            textView?.resignFirstResponder()
        }

        /// Bold or italic: off if the whole selection already has it, else on.
        private func toggle(_ key: NSAttributedString.Key, actionName: String) {
            guard let textView else { return }
            let selection = textView.selectedRange
            guard selection.length > 0 else {
                // No selection: the change applies to what's typed next.
                var attributes = textView.typingAttributes
                attributes[key] = attributes[key] as? Bool == true ? nil : true
                textView.typingAttributes = typingAttributes(from: attributes)
                updateFormatBar()
                return
            }
            let ranges = formattableRanges(in: selection)
            guard !ranges.isEmpty else { return }
            let alreadyOn = ranges.allSatisfy { isSet(key, throughout: $0) }
            applyFormat(in: selection, actionName: actionName) { storage in
                for range in ranges {
                    if alreadyOn {
                        storage.removeAttribute(key, range: range)
                    } else {
                        storage.addAttribute(key, value: true, range: range)
                    }
                }
            }
        }

        private func setColor(_ name: String?) {
            guard let textView else { return }
            let selection = textView.selectedRange
            guard selection.length > 0 else {
                var attributes = textView.typingAttributes
                attributes[.scriptColor] = name
                textView.typingAttributes = typingAttributes(from: attributes)
                updateFormatBar()
                return
            }
            let ranges = formattableRanges(in: selection)
            guard !ranges.isEmpty else { return }
            applyFormat(in: selection, actionName: name == nil ? "Remove Color" : "Color") { storage in
                for range in ranges {
                    if let name {
                        storage.addAttribute(.scriptColor, value: name, range: range)
                    } else {
                        storage.removeAttribute(.scriptColor, range: range)
                    }
                }
            }
        }

        private func applyFormat(in range: NSRange, actionName: String,
                                 _ change: (NSTextStorage) -> Void) {
            guard let storage = textView?.textStorage else { return }
            let before = formatSnapshot(in: range)
            storage.beginEditing()
            change(storage)
            storage.endEditing()
            formatDidChange(in: range)
            registerUndo(restoring: before, in: range, actionName: actionName)
        }

        private func formatDidChange(in range: NSRange) {
            restyle(range)
            commit()
            updateFormatBar()
        }

        // MARK: Undo

        private typealias FormatSnapshot = [(range: NSRange, attributes: [NSAttributedString.Key: Any])]

        private func formatSnapshot(in range: NSRange) -> FormatSnapshot {
            var snapshot: FormatSnapshot = []
            textView?.textStorage.enumerateAttributes(in: range) { attributes, run, _ in
                let format = attributes.filter { ScriptFormatter.formatKeys.contains($0.key) }
                if !format.isEmpty { snapshot.append((run, format)) }
            }
            return snapshot
        }

        /// Formatting changes edit attributes directly, which the text view's
        /// own undo doesn't track — so each one registers its inverse.
        private func registerUndo(restoring snapshot: FormatSnapshot, in range: NSRange, actionName: String) {
            guard let undoManager = textView?.undoManager else { return }
            undoManager.registerUndo(withTarget: self) { coordinator in
                coordinator.restore(snapshot, in: range, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }

        private func restore(_ snapshot: FormatSnapshot, in range: NSRange, actionName: String) {
            guard let storage = textView?.textStorage, NSMaxRange(range) <= storage.length else { return }
            let current = formatSnapshot(in: range)
            storage.beginEditing()
            for key in ScriptFormatter.formatKeys { storage.removeAttribute(key, range: range) }
            for (run, attributes) in snapshot { storage.addAttributes(attributes, range: run) }
            storage.endEditing()
            formatDidChange(in: range)
            registerUndo(restoring: current, in: range, actionName: actionName)
        }

        // MARK: Styling

        /// Derives fonts and colors from the format attributes for every line
        /// touching `range`, and styles speaker cues (whose look is automatic,
        /// so any formatting on them is dropped).
        private func restyle(_ range: NSRange) {
            guard let storage = textView?.textStorage else { return }
            let string = storage.string as NSString
            storage.beginEditing()
            for line in Self.lines(covering: range, in: string) {
                // Style the trailing newline with its line.
                let end = min(NSMaxRange(line) + 1, string.length)
                var styledStart = line.location
                if let cue = ScriptFormatter.speakerCue(in: string.substring(with: line)[...]) {
                    let cueRange = NSRange(location: line.location, length: cue.text.utf16.count)
                    for key in ScriptFormatter.formatKeys { storage.removeAttribute(key, range: cueRange) }
                    storage.addAttributes(displayAttributes(bold: true, italic: false,
                                                            color: ScriptPalette.speakerColor(for: String(cue.name))),
                                          range: cueRange)
                    styledStart = NSMaxRange(cueRange)
                }
                guard styledStart < end else { continue }
                storage.enumerateAttributes(in: NSRange(location: styledStart, length: end - styledStart)) {
                    attributes, run, _ in
                    let format = Self.format(of: attributes)
                    storage.addAttributes(displayAttributes(bold: format.bold, italic: format.italic,
                                                            color: format.uiColor),
                                          range: run)
                }
            }
            storage.endEditing()
        }

        private static let paragraphStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5
            return style
        }()

        private func font(bold: Bool, italic: Bool) -> UIFont {
            let key = (bold ? 1 : 0) | (italic ? 2 : 0)
            if let cached = fontCache[key] { return cached }
            let base = UIFont.preferredFont(forTextStyle: .body)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if bold { traits.insert(.traitBold) }
            if italic { traits.insert(.traitItalic) }
            let font = base.fontDescriptor.withSymbolicTraits(traits)
                .map { UIFont(descriptor: $0, size: 0) } ?? base
            fontCache[key] = font
            return font
        }

        private func displayAttributes(bold: Bool, italic: Bool,
                                       color: UIColor?) -> [NSAttributedString.Key: Any] {
            [
                .font: font(bold: bold, italic: italic),
                .foregroundColor: color ?? UIColor.label,
                .paragraphStyle: Self.paragraphStyle,
            ]
        }

        /// The format keys from `attributes`, plus the look they imply.
        private func typingAttributes(from attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var result = attributes.filter { ScriptFormatter.formatKeys.contains($0.key) }
            let format = Self.format(of: result)
            result.merge(displayAttributes(bold: format.bold, italic: format.italic, color: format.uiColor)) { $1 }
            return result
        }

        @objc private func contentSizeChanged() {
            fontCache.removeAll()
            guard let textView else { return }
            restyle(NSRange(location: 0, length: textView.textStorage.length))
            textView.typingAttributes = typingAttributes(from: textView.typingAttributes)
        }

        // MARK: Selection state

        private struct Format {
            var bold = false
            var italic = false
            var color: String?

            var uiColor: UIColor? { color.flatMap { ScriptPalette.namedColors[$0] } }
        }

        private static func format(of attributes: [NSAttributedString.Key: Any]) -> Format {
            Format(bold: attributes[.scriptBold] as? Bool ?? false,
                   italic: attributes[.scriptItalic] as? Bool ?? false,
                   color: attributes[.scriptColor] as? String)
        }

        /// What the selection has throughout (or what typing will produce,
        /// with no selection). A color counts only if it's uniform.
        private func currentFormat() -> Format {
            guard let textView else { return Format() }
            let selection = textView.selectedRange
            guard selection.length > 0 else { return Self.format(of: textView.typingAttributes) }
            let ranges = formattableRanges(in: selection)
            guard !ranges.isEmpty else { return Format() }
            var result = Format(bold: true, italic: true)
            var colors = Set<String?>()
            for range in ranges {
                textView.textStorage.enumerateAttributes(in: range) { attributes, _, _ in
                    let format = Self.format(of: attributes)
                    result.bold = result.bold && format.bold
                    result.italic = result.italic && format.italic
                    colors.insert(format.color)
                }
            }
            if colors.count == 1, let only = colors.first { result.color = only }
            return result
        }

        private func isSet(_ key: NSAttributedString.Key, throughout range: NSRange) -> Bool {
            var allSet = true
            textView?.textStorage.enumerateAttribute(key, in: range) { value, _, stop in
                if value as? Bool != true {
                    allSet = false
                    stop.pointee = true
                }
            }
            return allSet
        }

        /// The parts of `range` that formatting can apply to: everything but
        /// newlines and speaker cues.
        private func formattableRanges(in range: NSRange) -> [NSRange] {
            guard let storage = textView?.textStorage else { return [] }
            let string = storage.string as NSString
            var result: [NSRange] = []
            for line in Self.lines(covering: range, in: string) {
                var start = line.location
                if let cue = ScriptFormatter.speakerCue(in: string.substring(with: line)[...]) {
                    start += cue.text.utf16.count
                }
                let lower = max(start, range.location)
                let upper = min(NSMaxRange(line), NSMaxRange(range))
                if lower < upper { result.append(NSRange(location: lower, length: upper - lower)) }
            }
            return result
        }

        /// The full lines covering `range`, newlines excluded — split on "\n"
        /// exactly as the formatter does.
        private static func lines(covering range: NSRange, in string: NSString) -> [NSRange] {
            let length = string.length
            let lower = min(range.location, length)
            let upper = min(NSMaxRange(range), length)
            let previous = string.range(of: "\n", options: .backwards,
                                        range: NSRange(location: 0, length: lower))
            var start = previous.location == NSNotFound ? 0 : NSMaxRange(previous)
            var result: [NSRange] = []
            while true {
                let next = string.range(of: "\n", options: [],
                                        range: NSRange(location: start, length: length - start))
                let end = next.location == NSNotFound ? length : next.location
                result.append(NSRange(location: start, length: end - start))
                if next.location == NSNotFound || end >= upper { break }
                start = end + 1
            }
            return result
        }

        // MARK: Menus and format bar

        func makeFormatBar() -> UIToolbar {
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            let bold = UIBarButtonItem(image: UIImage(systemName: "bold"), style: .plain,
                                       target: self, action: #selector(toggleBold))
            bold.accessibilityLabel = "Bold"
            let italic = UIBarButtonItem(image: UIImage(systemName: "italic"), style: .plain,
                                         target: self, action: #selector(toggleItalic))
            italic.accessibilityLabel = "Italic"
            let colorElements = UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.colorMenuElements() ?? [])
            }
            let color = UIBarButtonItem(title: nil, image: UIImage(systemName: "paintpalette"),
                                        primaryAction: nil, menu: UIMenu(children: [colorElements]))
            color.accessibilityLabel = "Text Color"
            let done = UIBarButtonItem(barButtonSystemItem: .done, target: self,
                                       action: #selector(dismissKeyboard))
            bar.items = [bold, italic, color, .flexibleSpace(), done]
            bar.sizeToFit()
            boldItem = bold
            italicItem = italic
            colorItem = color
            return bar
        }

        private func updateFormatBar() {
            let format = currentFormat()
            for (item, isOn) in [(boldItem, format.bold), (italicItem, format.italic)] {
                item?.isSelected = isOn
                item?.tintColor = isOn ? nil : .label
            }
            colorItem?.tintColor = format.uiColor ?? .label
        }

        /// Shown in the edit menu when text is selected.
        private func formatMenu() -> UIMenu {
            let format = currentFormat()
            let bold = UIAction(title: "Bold", image: UIImage(systemName: "bold"),
                                state: format.bold ? .on : .off) { [weak self] _ in
                self?.toggle(.scriptBold, actionName: "Bold")
            }
            let italic = UIAction(title: "Italic", image: UIImage(systemName: "italic"),
                                  state: format.italic ? .on : .off) { [weak self] _ in
                self?.toggle(.scriptItalic, actionName: "Italic")
            }
            let color = UIMenu(title: "Color", image: UIImage(systemName: "paintpalette"),
                               children: colorMenuElements())
            return UIMenu(title: "Format", image: UIImage(systemName: "textformat"),
                          children: [bold, italic, color])
        }

        private func colorMenuElements() -> [UIMenuElement] {
            let selected = currentFormat().color
            let colors = ScriptPalette.colorOrder.map { name in
                let swatch = UIImage(systemName: "circle.fill")?
                    .withTintColor(ScriptPalette.namedColors[name] ?? .label, renderingMode: .alwaysOriginal)
                return UIAction(title: name.capitalized, image: swatch,
                                state: name == selected ? .on : .off) { [weak self] _ in
                    self?.setColor(name)
                }
            }
            let clear = UIAction(title: "No Color", image: UIImage(systemName: "circle.slash")) { [weak self] _ in
                self?.setColor(nil)
            }
            return colors + [UIMenu(options: .displayInline, children: [clear])]
        }
    }
}
