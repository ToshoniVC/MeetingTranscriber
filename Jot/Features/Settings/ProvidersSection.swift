import SwiftUI

/// PRD §0.4.5 — replaces `APIConfigSection`. A user can configure many
/// transcription providers simultaneously; the pipeline tries them in
/// the configured order until one succeeds.
///
/// Layout:
///   - SectionHeader with explainer copy
///   - List of provider rows (drag to reorder)
///   - "+ Add provider" button
///   - Info banner about the all-error fallback policy
struct ProvidersSection: View {
    @Environment(ProviderStore.self) private var store

    /// Provider currently being edited or created. Nil when the sheet is
    /// closed; non-nil triggers `.sheet(item:)` to present the edit UI.
    @State private var editing: Provider?

    /// Pending delete confirmation — set when the user clicks the trash
    /// icon on a row. The confirmation dialog reads this to display
    /// "Delete <name>?"; clearing it cancels.
    @State private var pendingDeletion: Provider?

    var body: some View {
        SectionHeader(
            title: "AI providers",
            systemImage: "waveform.path.ecg",
            subtitle: "Configure one or more transcription providers (OpenAI, Groq, …). Enabled providers are tried top-to-bottom; if one fails, the next is used."
        )

        VStack(alignment: .leading, spacing: 12) {
            if store.providers.isEmpty {
                emptyStateView
            } else {
                providerListView
            }

            HStack {
                Button {
                    editing = newDraftProvider()
                } label: {
                    Label("Add provider", systemImage: "plus.circle.fill")
                }

                Spacer()

                Text(fallbackHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .sheet(item: $editing) { draft in
            ProviderEditSheet(provider: draft) { saved in
                editing = nil
                if let saved {
                    do {
                        _ = try store.upsert(saved)
                    } catch {
                        // Re-open the sheet with the user's edits so they
                        // can fix the validation error (e.g., duplicate name).
                        editing = saved
                    }
                }
            }
        }
        .confirmationDialog(
            pendingDeletion.map { "Delete \"\($0.displayName)\"?" } ?? "Delete provider?",
            isPresented: deletionPresented,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { provider in
            Button("Delete", role: .destructive) {
                store.delete(id: provider.id)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text("The provider's API key is also removed from the keychain. This can't be undone.")
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No providers configured yet.")
                .font(.callout)
            Text("Add at least one provider to enable transcription.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
    }

    @ViewBuilder
    private var providerListView: some View {
        VStack(spacing: 8) {
            ForEach(store.providers) { provider in
                ProviderRow(
                    provider: provider,
                    canMoveUp: !isFirst(provider),
                    canMoveDown: !isLast(provider),
                    onEdit: { editing = provider },
                    onDelete: { pendingDeletion = provider },
                    onToggle: { newValue in
                        var updated = provider
                        updated.isEnabled = newValue
                        _ = try? store.upsert(updated)
                    },
                    onMoveUp: { move(provider, by: -1) },
                    onMoveDown: { move(provider, by: +1) }
                )
            }
        }
    }

    // MARK: - Helpers

    private var fallbackHint: String {
        "Any error on one provider falls through to the next."
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    /// A blank `Provider` ready for the edit sheet to fill in. `sortOrder
    /// = providers.count` so a newly-saved provider lands at the bottom
    /// of the chain.
    private func newDraftProvider() -> Provider {
        Provider(
            displayName: "",
            baseURL: "",
            model: "whisper-1",
            isEnabled: true,
            sortOrder: store.providers.count
        )
    }

    private func isFirst(_ provider: Provider) -> Bool {
        store.providers.first?.id == provider.id
    }

    private func isLast(_ provider: Provider) -> Bool {
        store.providers.last?.id == provider.id
    }

    /// Swap this provider with its neighbor `delta` positions away.
    /// `delta = -1` is "move up" (earlier in the chain); `+1` is "down".
    private func move(_ provider: Provider, by delta: Int) {
        let ids = store.providers.map(\.id)
        guard let from = ids.firstIndex(of: provider.id) else { return }
        let to = from + delta
        guard ids.indices.contains(to) else { return }
        var reordered = ids
        reordered.swapAt(from, to)
        store.reorder(toIDs: reordered)
    }
}

// MARK: - Row

/// One provider in the list. Reads its readiness from the store so the
/// status badge stays in sync with key-presence changes.
private struct ProviderRow: View {
    @Environment(ProviderStore.self) private var store

    let provider: Provider
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                .help("Move up in fallback order")

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                .help("Move down in fallback order")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.displayName.isEmpty ? "(Unnamed provider)" : provider.displayName)
                        .font(.callout.weight(.medium))
                    readinessBadge
                }
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: Binding(
                get: { provider.isEnabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .help(provider.isEnabled ? "Enabled — skipped if you flip this off" : "Disabled — pipeline ignores this provider")

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Delete")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private var readinessBadge: some View {
        let readiness = store.readiness(of: provider)
        switch readiness {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.green)
        case .missingKey:
            Label("No key", systemImage: "key.slash")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.orange)
        case .incomplete:
            Label("Incomplete", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.orange)
        case .disabled:
            Label("Off", systemImage: "pause.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var secondaryLine: String {
        let host = URL(string: provider.baseURL)?.host ?? provider.baseURL
        return "\(provider.model)  ·  \(host)"
    }
}
