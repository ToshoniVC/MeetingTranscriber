import SwiftUI

/// One row in the Audit Log list. PRD §3.2 Tab 2:
///   - kind icon (info/success/failure with appropriate color)
///   - one-line message
///   - source filename + duration (gray subtitle)
///   - Retry button for retryable failures
struct AuditLogRow: View {
    let entry: AuditLogEntry
    let onRetry: () -> Void
    /// Optional — only populated for failure rows. When set, a "Details"
    /// button surfaces the error inspector modal with this entry.
    let onShowDetails: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kindSystemImage)
                .foregroundStyle(kindColor)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.callout)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(URL(fileURLWithPath: entry.sourcePath).lastPathComponent)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let ms = entry.durationMs, ms > 0 {
                        Text("• \(formattedDuration(ms))")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }

                    Text("• \(entry.timestamp, format: .relative(presentation: .named))")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Failure-only "Details" button, opens the modal inspector
            // with the full message + Copy details affordance.
            if entry.kind == .failure, let onShowDetails {
                Button("Details") { onShowDetails() }
                    .controlSize(.small)
            }

            if entry.retryable {
                Button("Retry") { onRetry() }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    private var kindSystemImage: String {
        switch entry.kind {
        case .info:    return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private var kindColor: Color {
        switch entry.kind {
        case .info:    return .secondary
        case .success: return .green
        case .failure: return .red
        }
    }

    /// Pretty-print a duration in ms. Goal: humans see "12.4s", not "12387 ms".
    private func formattedDuration(_ ms: Int) -> String {
        if ms < 1_000 {
            return "\(ms) ms"
        }
        let seconds = Double(ms) / 1_000
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds / 60)
        let remainder = Int(seconds.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(remainder)s"
    }
}
