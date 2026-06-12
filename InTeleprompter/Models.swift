import Combine
import Foundation
import SwiftUI

// MARK: - Script

struct Script: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var title: String
    var body: String
    var createdAt = Date()
    var updatedAt = Date()

    var wordCount: Int {
        body.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// Rough on-camera read time at ~150 words per minute.
    var estimatedDuration: TimeInterval {
        Double(wordCount) / 150.0 * 60.0
    }

    var estimatedDurationText: String {
        let total = Int(estimatedDuration.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}

// MARK: - Script store (JSON persistence in Documents)

@MainActor
final class ScriptStore: ObservableObject {
    @Published var scripts: [Script] = []

    private var saveTask: Task<Void, Never>?

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("scripts.json")
    }()

    init() {
        load()
        if scripts.isEmpty {
            scripts = [Script(
                title: "Welcome to your teleprompter",
                body: """
                This is a sample script so you can try things out right away.

                Tap Present to open the prompter. The camera preview sits behind \
                this text, and the guide line marks your reading position so your \
                eyes stay close to the lens.

                Tap the red button to start a countdown and begin recording. The \
                text scrolls automatically — drag it at any time to reposition, \
                and use the speed controls to match your natural reading pace.

                When you stop, the video is saved straight to your Photos library \
                in the highest quality your iPhone supports. Open Settings inside \
                the prompter to adjust the font size, margins, mirror mode, and more.

                Delete this script whenever you're ready, and break a leg.
                """
            )]
            save()
        }
    }

    func add(_ script: Script) {
        scripts.insert(script, at: 0)
        save()
    }

    func update(_ script: Script) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        var updated = script
        updated.updatedAt = Date()
        scripts[index] = updated
        save()
    }

    func delete(at offsets: IndexSet) {
        scripts.remove(atOffsets: offsets)
        save()
    }

    func delete(_ script: Script) {
        scripts.removeAll { $0.id == script.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Script].self, from: data) else { return }
        scripts = decoded
    }

    /// Saves are debounced and written off the main thread — the editor
    /// calls update() on every keystroke, and encoding the whole store to
    /// disk per character would stutter typing in long scripts.
    func save() {
        saveTask?.cancel()
        let snapshot = scripts
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            // Scripts are user content; keep them encrypted at rest.
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}
