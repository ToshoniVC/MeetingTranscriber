import SwiftUI

/// Left pane of the Context tab: the list of saved organizations plus
/// add/delete controls. Selection drives the detail pane on the right.
struct OrganizationsListView: View {
    @Environment(OrganizationStore.self) private var store
    @Binding var selection: UUID?
    let onAdd: () -> Void
    let onDelete: (UUID) -> Void

    @State private var deleteCandidate: Organization?

    var body: some View {
        VStack(spacing: 0) {
            List(store.organizations, selection: $selection) { org in
                row(for: org)
                    .tag(org.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            deleteCandidate = org
                        }
                    }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("New organization")

                Button {
                    if let id = selection,
                       let org = store.organization(id: id) {
                        deleteCandidate = org
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(selection == nil)
                .help("Delete selected organization")

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .confirmationDialog(
            deleteCandidate.map { "Delete \"\($0.name)\"?" } ?? "Delete organization?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            presenting: deleteCandidate
        ) { org in
            Button("Delete", role: .destructive) {
                onDelete(org.id)
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { _ in
            Text("Meetings already filed under this organization are unaffected. Future meetings will need a new selection.")
        }
    }

    @ViewBuilder
    private func row(for org: Organization) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(org.name)
                    .lineLimit(1)
                if let company = org.companyName, !company.isEmpty {
                    Text(company)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if org.isDefault {
                Text("Default")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.secondary.opacity(0.4))
                    )
            }
        }
    }
}
