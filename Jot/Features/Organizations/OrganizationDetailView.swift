import SwiftUI

/// Right pane of the Context tab: the editable detail form for one
/// organization. Edits autosave on commit (focus loss / explicit
/// commit on lists). Name validation errors surface inline and the
/// name field reverts to the last-good value rather than persisting
/// a broken state.
struct OrganizationDetailView: View {
    @Environment(OrganizationStore.self) private var store
    let organizationID: UUID

    @State private var draft: Organization?
    @State private var nameError: String?

    var body: some View {
        Group {
            if let draft {
                form(for: draft)
            } else {
                ContentUnavailableView(
                    "Organization not found",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .onAppear { loadDraft() }
        .onChange(of: organizationID) { _, _ in loadDraft() }
        // If the store's copy of this org changes (e.g., default-clear
        // ripple from another org being promoted), refresh the draft.
        .onChange(of: store.organization(id: organizationID)) { _, new in
            guard let new, draft?.updatedAt != new.updatedAt else { return }
            draft = new
        }
    }

    // MARK: - Form

    @ViewBuilder
    private func form(for current: Organization) -> some View {
        Form {
            Section("Identity") {
                TextField("Organization name", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                if let nameError {
                    Text(nameError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                TextField(
                    "Company name (optional)",
                    text: companyBinding
                )
                .textFieldStyle(.roundedBorder)

                Toggle("Default for new meetings", isOn: defaultBinding)
                    .help("Preselected in the meeting-start prompt.")
            }

            Section("Staff") {
                StringListEditor(
                    items: stringListBinding(\.staffNames),
                    placeholder: "Add staff name"
                )
            }

            Section("Projects") {
                StringListEditor(
                    items: stringListBinding(\.projectNames),
                    placeholder: "Add project name"
                )
            }

            Section("Glossary terms") {
                StringListEditor(
                    items: stringListBinding(\.glossaryTerms),
                    placeholder: "Add term"
                )
            }

            Section("Acronyms") {
                AcronymListEditor(items: acronymsBinding)
            }

            Section("Freeform notes") {
                TextEditor(text: notesBinding)
                    .frame(minHeight: 100)
                    .border(Color.secondary.opacity(0.2))
                Text("Anything else Whisper should know about this org — pronunciations, jargon, product names.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Bindings (each persists on change)

    private var nameBinding: Binding<String> {
        Binding(
            get: { draft?.name ?? "" },
            set: { newValue in
                guard var d = draft else { return }
                d.name = newValue
                draft = d
                // Persist only when the trimmed name is valid; otherwise
                // hold the bad state in the draft and surface the error.
                attemptPersist(d, allowNameError: true)
            }
        )
    }

    private var companyBinding: Binding<String> {
        Binding(
            get: { draft?.companyName ?? "" },
            set: { newValue in
                guard var d = draft else { return }
                d.companyName = newValue.isEmpty ? nil : newValue
                draft = d
                attemptPersist(d)
            }
        )
    }

    private var defaultBinding: Binding<Bool> {
        Binding(
            get: { draft?.isDefault ?? false },
            set: { newValue in
                guard var d = draft else { return }
                d.isDefault = newValue
                draft = d
                attemptPersist(d)
            }
        )
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { draft?.freeformNotes ?? "" },
            set: { newValue in
                guard var d = draft else { return }
                d.freeformNotes = newValue.isEmpty ? nil : newValue
                draft = d
                attemptPersist(d)
            }
        )
    }

    private func stringListBinding(_ keyPath: WritableKeyPath<Organization, [String]>) -> Binding<[String]> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? [] },
            set: { newValue in
                guard var d = draft else { return }
                d[keyPath: keyPath] = newValue
                draft = d
                attemptPersist(d)
            }
        )
    }

    private var acronymsBinding: Binding<[AcronymEntry]> {
        Binding(
            get: { draft?.acronyms ?? [] },
            set: { newValue in
                guard var d = draft else { return }
                d.acronyms = newValue
                draft = d
                attemptPersist(d)
            }
        )
    }

    // MARK: - Persistence helpers

    private func loadDraft() {
        draft = store.organization(id: organizationID)
        nameError = nil
    }

    /// Try to commit the draft to the store. When `allowNameError` is true
    /// (the name field is currently being edited), validation failures are
    /// surfaced inline and the draft is *not* reverted — the user gets to
    /// fix the typo. Otherwise (a field other than the name failed), revert
    /// silently to the store's copy.
    private func attemptPersist(_ candidate: Organization, allowNameError: Bool = false) {
        do {
            _ = try store.upsert(candidate)
            nameError = nil
        } catch let error as OrganizationValidationError {
            if allowNameError {
                nameError = error.errorDescription
            } else {
                // Non-name change failed; should be impossible (other fields
                // don't validate today) but reverting keeps the UI honest.
                draft = store.organization(id: organizationID)
            }
        } catch {
            draft = store.organization(id: organizationID)
        }
    }
}

// MARK: - Small reusable editors

/// Editable list of plain strings. Used for staff, projects, glossary.
private struct StringListEditor: View {
    @Binding var items: [String]
    let placeholder: String

    @State private var newItem: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, _ in
                HStack {
                    TextField("", text: binding(for: index))
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        items.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField(placeholder, text: $newItem)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addNew)
                Button(action: addNew) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .disabled(newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { items[index] },
            set: { items[index] = $0 }
        )
    }

    private func addNew() {
        let trimmed = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(trimmed)
        newItem = ""
    }
}

/// Editable list of `AcronymEntry` (term + expansion pairs).
private struct AcronymListEditor: View {
    @Binding var items: [AcronymEntry]

    @State private var newTerm: String = ""
    @State private var newExpansion: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, _ in
                HStack {
                    TextField("Term", text: termBinding(index))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                    Text("=")
                        .foregroundStyle(.secondary)
                    TextField("Expansion", text: expansionBinding(index))
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        items.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("Term", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                Text("=")
                    .foregroundStyle(.secondary)
                TextField("Expansion", text: $newExpansion)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addNew)
                Button(action: addNew) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .disabled(
                    newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || newExpansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
    }

    private func termBinding(_ index: Int) -> Binding<String> {
        Binding(get: { items[index].term }, set: { items[index].term = $0 })
    }

    private func expansionBinding(_ index: Int) -> Binding<String> {
        Binding(get: { items[index].expansion }, set: { items[index].expansion = $0 })
    }

    private func addNew() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        let exp = newExpansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !exp.isEmpty else { return }
        items.append(AcronymEntry(term: term, expansion: exp))
        newTerm = ""
        newExpansion = ""
    }
}
