import SwiftUI

/// Right pane of the Context tab when the pinned "General" entry is selected.
/// Edits the app-wide `GeneralContext`: the default transcription language,
/// the optional wrapper prefix prepended to every Whisper prompt, and the
/// global context applied to every meeting regardless of organization. All
/// fields autosave on change, matching `OrganizationDetailView`'s
/// live-commit style.
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
            Section("Default language") {
                Picker("Language", selection: languageBinding) {
                    Text("Auto-detect").tag("")
                    ForEach(TranscriptionLanguage.pickerCodes, id: \.self) { code in
                        Text("\(TranscriptionLanguage.displayName(for: code)) (\(code))").tag(code)
                    }
                }
                .pickerStyle(.menu)
                Text("Sent as the transcription language unless an organization or a meeting picks its own. Pinning it stops Whisper from drifting into another language over silence and from translating what was said.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Wrapper prompt") {
                TextEditor(text: prefixBinding)
                    .frame(minHeight: 60)
                    .border(Color.secondary.opacity(0.2))
                Text("Optional lead-in before the term list. Empty by default — a lead-in is transcribed back as speech during silence, and Whisper only needs the terms.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear") {
                    commit(wrapperPrefix: ContextCompiler.defaultWrapperPrefix)
                }
                .controlSize(.small)
                .disabled(current.wrapperPrefix == ContextCompiler.defaultWrapperPrefix)
            }

            Section("General context") {
                TextEditor(text: generalBinding)
                    .frame(minHeight: 120)
                    .border(Color.secondary.opacity(0.2))
                Text("Added to every meeting regardless of organization — recurring names and jargon Whisper should always know how to spell. Keep it to terms: full sentences get echoed back over silence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("General context")
    }

    // MARK: - Bindings (each persists on change)

    private var languageBinding: Binding<String> {
        Binding(
            get: {
                let code = TranscriptionLanguage.normalized(draft?.defaultLanguageCode) ?? ""
                return code == TranscriptionLanguage.autoDetectCode ? "" : code
            },
            set: { commit(defaultLanguageCode: $0) }
        )
    }

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

    private func commit(
        wrapperPrefix: String? = nil,
        generalContext: String? = nil,
        defaultLanguageCode: String? = nil
    ) {
        store.update(
            wrapperPrefix: wrapperPrefix,
            generalContext: generalContext,
            defaultLanguageCode: defaultLanguageCode
        )
        draft = store.current
    }
}
