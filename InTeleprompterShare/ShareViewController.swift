import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Receives text and script files from the share sheet, extracts the text,
/// shows a quick preview, and stages the script in the App Group container
/// for the main app to pick up. All extraction happens on-device.
final class ShareViewController: UIViewController {

    private let model = ShareImportModel()

    override func viewDidLoad() {
        super.viewDidLoad()

        let host = UIHostingController(rootView: ShareImportView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        model.extensionContext = extensionContext
        model.onFinish = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        model.process()
    }
}

// MARK: - Model

@MainActor
final class ShareImportModel: ObservableObject {

    enum State {
        case loading
        case ready(Script)
        case failed(String)
        case saved
    }

    @Published private(set) var state: State = .loading

    var extensionContext: NSExtensionContext?
    var onFinish: (() -> Void)?

    func process() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem], !items.isEmpty else {
            state = .failed("Nothing to import was shared.")
            return
        }
        Task {
            do {
                let script = try await ShareExtractor.script(from: items)
                state = .ready(script)
            } catch let error as ScriptImportError {
                state = .failed(error.errorDescription ?? "Couldn't import this content.")
            } catch {
                state = .failed("Couldn't import this content.")
            }
        }
    }

    func save() {
        guard case .ready(let script) = state else { return }
        if PendingScripts.stage(script) {
            state = .saved
        } else {
            state = .failed("Couldn't reach InTeleprompter's shared container. The App Group may not be registered yet — build the app to a device once, then try again.")
        }
    }

    /// The app drains the staged script on open. Falls back to just closing
    /// the sheet — the import lands the next time the app becomes active.
    func openApp() {
        guard let url = URL(string: "inteleprompter://imported") else {
            onFinish?()
            return
        }
        // Capture the closure, not self, so nothing crosses isolation bounds.
        let finish = onFinish
        extensionContext?.open(url) { _ in
            Task { @MainActor in finish?() }
        }
    }

    func cancel() { onFinish?() }
}

// MARK: - Extraction

enum ShareExtractor {

    /// The first supported attachment wins: known file types by UTI, then
    /// unknown file types (branched on extension), then plain shared text.
    static func script(from items: [NSExtensionItem]) async throws -> Script {
        for item in items {
            for provider in item.attachments ?? [] {
                if let script = try await script(from: provider) { return script }
            }
        }
        throw ScriptImportError.unreadableFile
    }

    private static func script(from provider: NSItemProvider) async throws -> Script? {
        let fileTypes = [
            UTType.pdf.identifier,
            "org.openxmlformats.wordprocessingml.document",
            UTType.rtf.identifier,
            UTType.rtfd.identifier,
            "net.daringfireball.markdown",
        ]
        for type in fileTypes where provider.hasItemConformingToTypeIdentifier(type) {
            return try await importFile(provider, type: type)
        }

        // Files whose UTI isn't declared on this system (e.g. .gdoc) arrive
        // as generic data — but only when no text representation exists.
        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            return try await importFile(provider, type: UTType.data.identifier)
        }

        // Shared text (Notes, Safari selections, Google Docs "copy").
        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try await loadText(provider) {
            let imported = try ScriptImporter.load(text: text)
            return Script(title: imported.title, body: imported.text)
        }
        return nil
    }

    private static func importFile(_ provider: NSItemProvider, type: String) async throws -> Script {
        let url = try await loadFile(provider, type: type)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try ScriptImporter.load(from: url)
        return Script(title: imported.title, body: imported.text)
    }

    /// loadFileRepresentation's URL is only valid inside its callback, so
    /// the file is copied somewhere durable before handing it back.
    private static func loadFile(_ provider: NSItemProvider, type: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ScriptImportError.unreadableFile)
                    return
                }
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension)
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.text.identifier) { item, _ in
                switch item {
                case let text as String:
                    continuation.resume(returning: text)
                case let url as URL:
                    continuation.resume(returning: try? String(contentsOf: url, encoding: .utf8))
                case let data as Data:
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - SwiftUI view

private struct ShareImportView: View {
    @ObservedObject var model: ShareImportModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView("Reading shared content…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready(let script):
                    readyContent(script)
                case .failed(let message):
                    failedContent(message)
                case .saved:
                    savedContent
                }
            }
            .navigationTitle("Import to InTeleprompter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
                if case .ready = model.state {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") { model.save() }
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    private func readyContent(_ script: Script) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(script.title)
                .font(.headline)
                .lineLimit(2)
            Text("\(script.wordCount) words · ~\(script.estimatedDurationText) read")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                Text(script.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    private func failedContent(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var savedContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("Added to your scripts")
                .font(.headline)
            HStack(spacing: 12) {
                Button("Open InTeleprompter") { model.openApp() }
                    .buttonStyle(.borderedProminent)
                Button("Done") { model.cancel() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
