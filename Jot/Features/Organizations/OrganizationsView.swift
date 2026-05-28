import SwiftUI

/// Root of the Context tab (the 4th sidebar tab — PRD §4.1 calls it
/// "Custom Context"; we render it as just "Context" per the user-approved
/// implementation plan).
///
/// Layout: org list on the left, detail editor on the right (via
/// `HSplitView`). The system-provided "No Organization" sentinel is *not*
/// shown in the list — it only exists at meeting-start time as a picker
/// option, not as a stored record.
struct OrganizationsView: View {
    @Environment(OrganizationStore.self) private var store
    @State private var selectedID: UUID?
    @State private var creationError: String?

    var body: some View {
        Group {
            if store.organizations.isEmpty {
                emptyState
            } else {
                HSplitView {
                    OrganizationsListView(
                        selection: $selectedID,
                        onAdd: addOrganization,
                        onDelete: deleteOrganization
                    )
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

                    detailPane
                        .frame(minWidth: 360)
                }
            }
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
        .onAppear {
            if selectedID == nil {
                selectedID = store.organizations.first?.id
            }
        }
        .onChange(of: store.organizations) { _, new in
            // If the selected org was deleted (or never existed), select the
            // first one so the detail pane doesn't go blank.
            if let id = selectedID, new.contains(where: { $0.id == id }) {
                return
            }
            selectedID = new.first?.id
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let id = selectedID,
           let _ = store.organization(id: id) {
            OrganizationDetailView(organizationID: id)
        } else {
            ContentUnavailableView(
                "No organization selected",
                systemImage: "person.crop.rectangle",
                description: Text("Pick an organization from the list, or create a new one.")
            )
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.text.rectangle")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No organizations yet")
                .font(.title2)
            Text("Create a profile so Jot can include staff names, projects, and glossary in each transcription request.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Create your first organization", action: addOrganization)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Actions

    private func addOrganization() {
        let baseName = "New Organization"
        let unique = uniqueName(startingFrom: baseName)
        do {
            let inserted = try store.upsert(Organization(name: unique))
            selectedID = inserted.id
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
