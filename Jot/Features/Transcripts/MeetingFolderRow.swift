import SwiftUI

/// A row in the Transcripts list. PRD §3.2 Tab 1:
///   - folder name (prominent)
///   - relative date + file count (subtitle)
///   - expandable to show inline file list
///   - double-click on a file opens it in the default app
///   - right-click context menu: Reveal in Finder, Rename, Delete
struct MeetingFolderRow: View {

    let meeting: MeetingFolder
    let onRevealFolder: () -> Void
    let onOpenFile: (URL) -> Void
    let onRevealFile: (URL) -> Void
    let onRenameRequested: () -> Void
    let onDeleteRequested: () -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            // Inline file list — one row per file in the folder.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(meeting.files) { file in
                    fileRow(file)
                }
            }
            .padding(.leading, 8)
            .padding(.top, 4)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(meeting.modifiedAt, format: .relative(presentation: .named))
                        Text("•")
                        Text("\(meeting.files.count) file\(meeting.files.count == 1 ? "" : "s")")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .contextMenu {
                Button { onRevealFolder() } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }
                Divider()
                Button { onRenameRequested() } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    onDeleteRequested()
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: MeetingFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: file))
                .foregroundStyle(iconColor(for: file))
                .frame(width: 18)

            Text(file.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(file.displaySize)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // Double-click — open the file in its default app
        .onTapGesture(count: 2) {
            onOpenFile(file.url)
        }
        .contextMenu {
            Button { onOpenFile(file.url) } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            Button { onRevealFile(file.url) } label: {
                Label("Reveal in Finder", systemImage: "magnifyingglass")
            }
        }
    }

    private func iconName(for file: MeetingFile) -> String {
        switch file.ext {
        case "txt", "md":               return "doc.text"
        case "mp3", "m4a", "wav":       return "waveform"
        default:                        return "doc"
        }
    }

    private func iconColor(for file: MeetingFile) -> Color {
        switch file.ext {
        case "txt", "md":               return .indigo
        case "mp3", "m4a", "wav":       return .green
        default:                        return .secondary
        }
    }
}
