import Combine
import Foundation
import SwiftUI   // for remove(atOffsets:) with IndexSet

// MARK: - Bundled sample scripts

enum SampleScripts {
    static let welcome = Script(
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
    )

    /// Teaches the lightweight markup by demonstrating it — present it and
    /// the formatting renders itself.
    static let formattingGuide = Script(
        title: "Formatting guide",
        body: """
        This script is a quick tour of script formatting. Open it in the \
        prompter to see it rendered, then steal whatever's useful.

        **Bold** pops on camera. Use it for the words you want to land. \
        *Italic* is softer, good for asides and whispers.

        Colors highlight whole phrases: [red]red[/red], [orange]orange[/orange], \
        [yellow]yellow[/yellow], [green]green[/green], [blue]blue[/blue], \
        [purple]purple[/purple], and [pink]pink[/pink]. You can even nest \
        emphasis inside a color: [green]**important**[/green].

        For two-person scripts, start a line with a name in all caps:

        HOST: Welcome back to the show!
        GUEST: Thanks for having me.

        Speaker cues get their own color per name and voice tracking \
        skips them, since you never read the cue out loud. Each speaker's \
        lines still track word by word.

        Delete this script whenever you're done with it.
        """
    )
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
        importPendingSharedScripts()
        seedSampleScriptsIfNeeded()
    }

    /// Fresh installs get the welcome script and the formatting guide (in
    /// that order). Installs from before the guide existed get it exactly
    /// once — deleting it doesn't bring it back.
    private static let hasSeededFormattingGuideKey = "hasSeededFormattingGuide"

    private func seedSampleScriptsIfNeeded() {
        if scripts.isEmpty {
            scripts = [SampleScripts.welcome, SampleScripts.formattingGuide]
            UserDefaults.standard.set(true, forKey: Self.hasSeededFormattingGuideKey)
            save()
            return
        }
        guard !UserDefaults.standard.bool(forKey: Self.hasSeededFormattingGuideKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.hasSeededFormattingGuideKey)
        guard !scripts.contains(where: { $0.title == SampleScripts.formattingGuide.title }) else { return }
        scripts.append(SampleScripts.formattingGuide)
        save()
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

    /// Pulls in anything the share extension staged while the app wasn't
    /// running. Called at launch, on becoming active, and on URL-scheme open.
    func importPendingSharedScripts() {
        let pending = PendingScripts.drain()
        guard !pending.isEmpty else { return }
        scripts.insert(contentsOf: pending, at: 0)
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
