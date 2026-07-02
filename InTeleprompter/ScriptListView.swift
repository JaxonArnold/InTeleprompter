import SwiftUI
import UniformTypeIdentifiers

struct ScriptListView: View {
    @EnvironmentObject private var store: ScriptStore
    @State private var presentingScript: Script?
    @State private var newScript: Script?
    @State private var showImporter = false
    @State private var showRemote = false
    @State private var importError: ScriptImportError?

    var body: some View {
        NavigationStack {
            Group {
                if store.scripts.isEmpty {
                    emptyState
                } else {
                    scriptList
                }
            }
            .navigationTitle("Scripts")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showRemote = true
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    .accessibilityLabel("Remote control another device")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showImporter = true
                        } label: {
                            Label("Import File…", systemImage: "doc")
                        }
                        Button {
                            pasteFromClipboard()
                        } label: {
                            Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Import script")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let script = Script(title: "", body: "")
                        store.add(script)
                        newScript = script
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New script")
                }
            }
            .navigationDestination(item: $newScript) { script in
                ScriptEditorView(script: script, presentingScript: $presentingScript)
            }
        }
        .fullScreenCover(item: $presentingScript) { script in
            PrompterView(script: script)
        }
        .sheet(isPresented: $showRemote) {
            RemoteControlView()
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: ScriptImporter.pickerContentTypes) { result in
            if case .success(let url) = result { importFile(from: url) }
        }
        .alert("Couldn't Import Script",
               isPresented: Binding(
                   get: { importError != nil },
                   set: { if !$0 { importError = nil } }
               )) {
            if case .googleDocShortcut(let url) = importError, let url {
                Button("Open Google Docs") { UIApplication.shared.open(url) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError?.errorDescription ?? "")
        }
    }

    private var scriptList: some View {
        List {
            ForEach(store.scripts) { script in
                NavigationLink {
                    ScriptEditorView(script: script, presentingScript: $presentingScript)
                } label: {
                    ScriptRow(script: script) {
                        presentingScript = script
                    }
                }
            }
            .onDelete { store.delete(at: $0) }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("No scripts yet")
                .font(.title3.weight(.semibold))
            Text("Tap + to write your first script, or import one — PDF, Word, RTF, Markdown, and plain text all work.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Importing

    private func importFile(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let imported = try ScriptImporter.load(from: url)
            store.add(Script(title: imported.title, body: imported.text))
        } catch let error as ScriptImportError {
            importError = error
        } catch {
            importError = .unreadableFile
        }
    }

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string else {
            importError = .emptyText(.generic)
            return
        }
        do {
            let imported = try ScriptImporter.load(text: text)
            store.add(Script(title: imported.title, body: imported.text))
        } catch let error as ScriptImportError {
            importError = error
        } catch {
            importError = .unreadableFile
        }
    }
}

private struct ScriptRow: View {
    let script: Script
    let onPresent: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(script.title.isEmpty ? "Untitled" : script.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(script.body.isEmpty ? "Empty script" : script.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("\(script.wordCount) words · ~\(script.estimatedDurationText) read")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(action: onPresent) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Present script")
        }
        .padding(.vertical, 4)
    }
}
