import Foundation
import Testing
@testable import InTeleprompter

// MARK: - Script importer

struct ScriptImporterTests {

    private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
        let bundle = try #require(Bundle(identifier: "jack.InTeleprompterTests"))
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "ImportFixtures")
            ?? bundle.url(forResource: name, withExtension: ext) {
            return url
        }
        Issue.record("missing fixture \(name).\(ext)")
        return URL(fileURLWithPath: "/dev/null")
    }

    @Test func importsPlainText() throws {
        let result = try ScriptImporter.load(from: fixtureURL("sample", "txt"))
        #expect(result.text.contains("TELEPROMPTERFIXTURE"))
        #expect(result.text.contains("Second paragraph"))
        #expect(result.title == "sample")
    }

    @Test func importsMarkdown() throws {
        let result = try ScriptImporter.load(from: fixtureURL("sample", "md"))
        #expect(result.text.contains("TELEPROMPTERFIXTURE"))
    }

    @Test func importsRTF() throws {
        let result = try ScriptImporter.load(from: fixtureURL("sample", "rtf"))
        #expect(result.text.contains("TELEPROMPTERFIXTURE"))
        #expect(result.text.contains("Second paragraph"))
    }

    @Test func importsDocx() throws {
        let result = try ScriptImporter.load(from: fixtureURL("sample", "docx"))
        #expect(result.text.contains("TELEPROMPTERFIXTURE"))
        #expect(result.text.contains("Second paragraph"))
        // Paragraph structure survives the trip through word/document.xml.
        #expect(result.text.contains("importer.\n"))
    }

    @Test func importsPDF() throws {
        let result = try ScriptImporter.load(from: fixtureURL("sample", "pdf"))
        #expect(result.text.contains("TELEPROMPTERFIXTURE"))
    }

    @Test func googleDocShortcutYieldsGuidanceAndLink() throws {
        do {
            _ = try ScriptImporter.load(from: fixtureURL("sample", "gdoc"))
            Issue.record("expected googleDocShortcut to be thrown")
        } catch ScriptImportError.googleDocShortcut(let url) {
            #expect(url?.absoluteString.contains("docs.google.com") == true)
            #expect(ScriptImportError.googleDocShortcut(url).errorDescription?
                .contains("Share & export") == true)
        }
    }

    @Test func unsupportedExtensionIsRejected() throws {
        // Reuse the fixture under an unsupported extension.
        let source = try fixtureURL("sample", "txt")
        let odd = FileManager.default.temporaryDirectory.appendingPathComponent("sample.xyz")
        try? FileManager.default.removeItem(at: odd)
        try FileManager.default.copyItem(at: source, to: odd)
        defer { try? FileManager.default.removeItem(at: odd) }
        #expect(throws: ScriptImportError.self) { try ScriptImporter.load(from: odd) }
    }

    @Test func sharedTextUsesFirstLineAsTitle() throws {
        let result = try ScriptImporter.load(text: "  My Big Announcement\n\nBody text here. ")
        #expect(result.title == "My Big Announcement")
        #expect(result.text.hasPrefix("My Big Announcement"))
        #expect(!result.text.hasSuffix(" "))
    }

    @Test func emptySharedTextIsRejected() {
        #expect(throws: ScriptImportError.self) { try ScriptImporter.load(text: "  \n ") }
    }
}

// MARK: - Pending scripts hand-off (App Group box used by the share extension)

/// Simulators have no registered App Group, so each test points the box at
/// its own temp directory. Serialized because containerURL is shared.
@Suite(.serialized)
struct PendingScriptsTests {

    private func useTempContainer() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        PendingScripts.containerURL = dir
    }

    @Test func stageThenDrainRoundTrips() {
        useTempContainer()

        let script = Script(title: "Staged", body: "From the share extension")
        #expect(PendingScripts.stage(script))

        let drained = PendingScripts.drain()
        #expect(drained.count == 1)
        #expect(drained.first?.title == "Staged")
        #expect(drained.first?.body == "From the share extension")
        #expect(drained.first?.id == script.id)

        // Draining empties the box.
        #expect(PendingScripts.drain().isEmpty)
    }

    @Test func multipleStagedScriptsAllDrain() {
        useTempContainer()
        #expect(PendingScripts.stage(Script(title: "One", body: "First")))
        #expect(PendingScripts.stage(Script(title: "Two", body: "Second")))

        let drained = PendingScripts.drain()
        #expect(drained.map(\.title) == ["One", "Two"])
        #expect(PendingScripts.drain().isEmpty)
    }
}
