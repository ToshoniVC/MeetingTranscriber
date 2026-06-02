import SwiftUI

/// Right pane of the Context tab when the pinned "General" entry is selected.
/// Edits the app-wide `GeneralContext`: the wrapper prefix prepended to every
/// Whisper prompt, and the global context applied to every meeting regardless
/// of organization. Both fields autosave on change, matching
/// `OrganizationDetailView`'s live-commit style.
struct GeneralContextDetailView: View {
    @Environment(GeneralContextStore.self) private var store

    @State private var draft: GeneralContext?

    var body: some View {
        Group {
            if let draft {
                form(for: draft)
            } else {
                ProgressView()
            }
        }
        .onAppear { if draft == nil { draft = store.current } }
        // Refresh if the store changes underneath us (e.g., reset elsewhere).
        .onChange(of: store.current) { _, new in
            if draft?.updatedAt != new.updatedAt { draft = new }
        }
    }

    @ViewBuilder
    private func form(for current: GeneralContext) -> some View {
        Form {
            Section("Wrapper prompt") {
                TextEditor(text: prefixBinding)
                    .frame(minHeight: 60)
                    .border(Color.secondary.opacity(0.2))
                Text("Lead-in prepended to every transcription prompt. Keep it short — a long sentence here can get transcribed back as speech during silence. Leave empty to omit it entirely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset to default") {
                    commit(wrapperPrefix: ContextCompiler.defaultWrapperPrefix)
                }
                .controlSize(.small)
                .disabled(current.wrapperPrefix == ContextCompiler.defaultWrapperPrefix)
            }

            Section("General context") {
                TextEditor(text: generalBinding)
                    .frame(minHeight: 120)
                    .border(Color.secondary.opacity(0.2))
                Text("Added to every meeting regardless of organization — recurring names, pronunciations, jargon Whisper should always know.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("General context")
    }

    // MARK: - Bindings (each persists on change)

    private var prefixBinding: Binding<String> {
        Binding(
            get: { draft?.wrapperPrefix ?? "" },
            set: { commit(wrapperPrefix: $0) }
        )
    }

    private var generalBinding: Binding<String> {
        Binding(
            get: { draft?.generalContext ?? "" },
            set: { commit(generalContext: $0) }
        )
    }

    private func commit(wrapperPrefix: String? = nil, generalContext: String? = nil) {
        store.update(wrapperPrefix: wrapperPrefix, generalContext: generalContext)
        draft = store.current
    }
}
