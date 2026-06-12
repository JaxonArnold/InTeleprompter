import SwiftUI

struct ScriptEditorView: View {
    @EnvironmentObject private var store: ScriptStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Script
    @State private var pendingUpdate: Task<Void, Never>?
    @Binding var presentingScript: Script?
    @FocusState private var bodyFocused: Bool

    init(script: Script, presentingScript: Binding<Script?>) {
        _draft = State(initialValue: script)
        _presentingScript = presentingScript
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $draft.title)
                .font(.title2.weight(.bold))
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .submitLabel(.next)
                .onSubmit { bodyFocused = true }

            Divider()
                .padding(.top, 12)

            TextEditor(text: $draft.body)
                .focused($bodyFocused)
                .font(.body)
                .lineSpacing(5)
                .padding(.horizontal, 14)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if draft.body.isEmpty {
                        Text("Write or paste your script here…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 19)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
        .safeAreaInset(edge: .bottom) {
            footer
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("\(draft.wordCount) words · ~\(draft.estimatedDurationText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .keyboard) {
                HStack {
                    Spacer()
                    Button("Done") { bodyFocused = false }
                }
            }
        }
        .onChange(of: draft) { _, newValue in
            // Debounced: pushing the store on every keystroke re-renders the
            // list behind this screen (word counts and all) per character.
            pendingUpdate?.cancel()
            pendingUpdate = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                store.update(newValue)
            }
        }
        .onDisappear {
            pendingUpdate?.cancel()
            store.update(draft)
        }
    }

    private var footer: some View {
        Button {
            store.update(draft)
            presentingScript = draft
        } label: {
            Label("Present", systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .disabled(draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
