import SwiftUI

struct ScriptListView: View {
    @EnvironmentObject private var store: ScriptStore
    @State private var presentingScript: Script?
    @State private var newScript: Script?

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
            Text("Tap + to write your first script, then present it with the camera rolling.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
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
