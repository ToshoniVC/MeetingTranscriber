import SwiftUI
import AppKit

/// Sheet UI for the error inspector. Three actions:
///   - **Copy details**: copies a multi-line plain-text dump (timestamp +
///     file + message) to the pasteboard. Useful for pasting into a bug
///     report or chat.
///   - **Open Audit Log**: navigates `MainWindow` to the Audit Log tab and
///     dismisses the sheet — the user can then scroll to find the entry
///     and click Retry.
///   - **Close**: dismiss the sheet. Bound to Escape via
///     `keyboardShortcut(.cancelAction)`.
///
/// Hosted by `MainWindow` so the sheet appears regardless of which tab is
/// currently selected.
struct ErrorInspectorView: View {
    let details: ErrorInspector.ErrorDetails
    let onDismiss: () -> Void
    let onOpenAuditLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header — red triangle + title.
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.title2)
                Text(details.title)
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Body — message, file, time. `.textSelection(.enabled)` lets
            // the user copy individual chunks without pulling the entire
            // "Copy details" payload.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(details.message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if let path = details.sourcePath, !path.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            metaLabel("File")
                            Text(path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .truncationMode(.middle)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        metaLabel("Time")
                        Text(
                            details.timestamp,
                            format: .dateTime
                                .year().month().day()
                                .hour().minute().second()
                        )
                        .font(.caption)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 80, maxHeight: 220)

            // Actions
            HStack {
                Button("Copy details") {
                    copyDetails()
                }
                Spacer()
                Button("Open Audit Log") {
                    onOpenAuditLog()
                }
                Button("Close") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 520, maxWidth: 680)
    }

    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// Build a single plain-text blob and put it on the system pasteboard.
    /// The format is deliberately simple — humans will paste this into a
    /// chat message or bug report.
    private func copyDetails() {
        var lines: [String] = []
        lines.append(details.title)
        lines.append("Time: \(details.timestamp)")
        if let path = details.sourcePath, !path.isEmpty {
            lines.append("File: \(path)")
        }
        lines.append("")
        lines.append(details.message)
        let blob = lines.joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(blob, forType: .string)
    }
}
