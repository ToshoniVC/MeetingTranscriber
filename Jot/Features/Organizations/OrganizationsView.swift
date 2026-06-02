import SwiftUI

/// Selection model for the Context tab's left list: either the pinned global
/// "General" entry or one saved organization.
enum ContextSelection: Hashable {
    case general
    case organization(UUID)
}

/// Root of the Context tab (the 4th sidebar tab — PRD §4.1 calls it
/// "Custom Context"; we render it as just "Context" per the user-approved
/// implementation plan).
///
/// Layout: a list on the left (a pinned "General" entry above the saved
/// organizations), detail editor on the right (via `HSplitView`). "General"
/// edits the app-wide `GeneralContext`; the org rows edit per-org profiles.
/// The system-provided "No Organization" sentinel is *not* shown in the list
/// — it only exists at meeting-start time as a picker option.
struct OrganizationsView: View {
    @Environment(OrganizationStore.self) private var store
    @State private var selection: ContextSelection? = .general
    @State private var creationError: String?

    var body: some View {
        HSplitView {
            OrganizationsListView(
                selection: $selection,
                onAdd: addOrganization,
                onDelete: deleteOrganization
            )
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            detailPane
                .frame(minWidth: 360)
        }
        .navigationTitle("Context")
        .alert(
            "Couldn't create organization",
            isPresented: Binding(
                get: { creationError != nil },
                set: { if !$0 { creationError = nil } }
            ),
            presenting: creationError
        ) { _ in
            Button("OK", role: .cancel) { creationError = nil }
        } message: { error in
            Text(error)
        }
        .onChange(of: store.organizations) { _, new in
            // If the selected org was deleted, fall back to General so the
            // detail pane doesn't go blank.
            if case .organization(let id) = selection,
               !new.contains(where: { $0.id == id }) {
                selection = .general
            }
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        switch selection {
        case .general, nil:
            GeneralContextDetailView()
        case .organization(let id):
            if store.organization(id: id) != nil {
                OrganizationDetailView(organizationID: id)
            } else {
                ContentUnavailableView(
                    "No organization selected",
                    systemImage: "person.crop.rectangle",
                    description: Text("Pick an organization from the list, or create a new one.")
                )
            }
        }
    }

    // MARK: - Actions

    private func addOrganization() {
        let baseName = "New Organization"
        let unique = uniqueName(startingFrom: baseName)
        do {
            let inserted = try store.upsert(Organization(name: unique))
            selection = .organization(inserted.id)
        } catch {
            creationError = error.localizedDescription
        }
    }

    private func deleteOrganization(id: UUID) {
        store.delete(id: id)
    }

    /// Generate "New Organization", "New Organization 2", … so a fresh row
    /// never collides with an existing one.
    private func uniqueName(startingFrom base: String) -> String {
        let existing = Set(store.organizations.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var n = 2
        while existing.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}
