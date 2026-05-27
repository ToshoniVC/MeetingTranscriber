import SwiftUI

/// Small layout primitives shared by the Settings section subviews.
///
/// They live here in `Features/Settings/` rather than `Shared/` because no
/// other feature uses them yet — per Claude/coding-instructions.md §2,
/// premature `Shared/` extraction is the anti-pattern we want to avoid.
/// Promote when a second feature needs them.

/// A section title row with an icon and an optional subtitle.
struct SectionHeader: View {
    let title: String
    let systemImage: String
    let subtitle: String?

    init(title: String, systemImage: String, subtitle: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A single row in a settings form: a label on the left, an arbitrary editor
/// on the right. Keeps alignment and spacing consistent across sections.
struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: 110, alignment: .trailing)
                .foregroundStyle(.secondary)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
