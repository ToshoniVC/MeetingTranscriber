import AppKit
import Foundation

/// Asks the user for meeting metadata to attach to a manually uploaded
/// recording. Mirrors the shape of `MeetingStartPrompting`
/// (`MeetingStartInputs` payload, same validation: trimmed-empty name =
/// cancel) so the rest of the pipeline can treat the two flows
/// identically downstream. Separate protocol so the system prompter can
/// use copy ("Add metadata to your upload") tailored to the upload
/// context, and so test code can inject a fake without touching the
/// `MeetingStartPrompting` machinery.
@MainActor
protocol MeetingUploadPrompting: AnyObject {
    /// Show the prompt for an uploaded file and return the user's
    /// choices, or nil if they cancelled.
    ///
    /// - Parameters:
    ///   - sourceDescription: human-readable summary of what's being
    ///     uploaded — for v0.5.0 single-file it's just the filename;
    ///     for v0.5.1 multi-file it's "<first>.mp3 + N more (one
    ///     meeting)". Shown in the dialog so the user can confirm
    ///     what they're queueing.
    ///   - organizations: full org list to populate the picker.
    ///   - defaultOrgId: pre-selected org id, or `nil` to default to
    ///     the "No Organization" sentinel.
    func askForUpload(
        sourceDescription: String,
        organizations: [Organization],
        defaultOrgId: UUID?
    ) async -> MeetingStartInputs?
}

/// Production prompter for the manual-upload flow. Parallel to
/// `SystemMeetingStartPrompter` — same accessory layout, different copy.
/// We don't share the NSAlert builder between the two because the
/// recording flow hides every other window before showing its modal
/// (the prompt fires from a global hotkey while the user is in another
/// app), whereas the upload flow originates from the Transcripts tab
/// inside Jot's own window and leaves the surrounding UI in place.
@MainActor
final class SystemMeetingUploadPrompter: NSObject, MeetingUploadPrompting, NSTextFieldDelegate {

    /// Sentinel id used in the popup to represent "No Organization".
    /// Lives on the menu item's `representedObject`; never written to
    /// disk.
    private static let noOrgTag = -1

    private weak var saveButton: NSButton?
    private weak var nameField: NSTextField?

    func askForUpload(
        sourceDescription: String,
        organizations: [Organization],
        defaultOrgId: UUID?
    ) async -> MeetingStartInputs? {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Upload — add meeting details"
        alert.informativeText = "Pick a meeting name and organization for \(sourceDescription). Optional notes are sent to the transcription endpoint as context."
        let saveButton = alert.addButton(withTitle: "Upload")
        alert.addButton(withTitle: "Cancel")
        self.saveButton = saveButton

        let width: CGFloat = 380
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 230))

        let nameLabel = NSTextField(labelWithString: "Meeting name")
        nameLabel.frame = NSRect(x: 0, y: 204, width: width, height: 16)
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor
        container.addSubview(nameLabel)

        let nameField = NSTextField(frame: NSRect(x: 0, y: 178, width: width, height: 22))
        nameField.placeholderString = "e.g. Standup, Client Call"
        nameField.delegate = self
        container.addSubview(nameField)
        self.nameField = nameField

        let orgLabel = NSTextField(labelWithString: "Organization")
        orgLabel.frame = NSRect(x: 0, y: 152, width: width, height: 16)
        orgLabel.font = .systemFont(ofSize: 11)
        orgLabel.textColor = .secondaryLabelColor
        container.addSubview(orgLabel)

        let orgPopup = NSPopUpButton(frame: NSRect(x: 0, y: 126, width: width, height: 22))
        orgPopup.addItem(withTitle: "No Organization")
        orgPopup.menu?.items.first?.representedObject = Self.noOrgTag
        for org in organizations {
            let badge = org.isDefault ? "  (default)" : ""
            orgPopup.addItem(withTitle: "\(org.name)\(badge)")
            orgPopup.menu?.items.last?.representedObject = org.id
        }
        if let defaultID = defaultOrgId,
           let idx = organizations.firstIndex(where: { $0.id == defaultID }) {
            orgPopup.selectItem(at: idx + 1)
        }
        container.addSubview(orgPopup)

        let contextLabel = NSTextField(labelWithString: "Meeting-specific context (optional)")
        contextLabel.frame = NSRect(x: 0, y: 100, width: width, height: 16)
        contextLabel.font = .systemFont(ofSize: 11)
        contextLabel.textColor = .secondaryLabelColor
        container.addSubview(contextLabel)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 96))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let contextView = NSTextView(frame: scroll.bounds)
        contextView.isRichText = false
        contextView.font = .systemFont(ofSize: 13)
        contextView.autoresizingMask = [.width]
        contextView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        contextView.textContainer?.widthTracksTextView = true
        scroll.documentView = contextView
        container.addSubview(scroll)

        alert.accessoryView = container
        alert.window.initialFirstResponder = nameField

        saveButton.isEnabled = false

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let trimmedName = nameField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let selectedOrgID: UUID?
        if let item = orgPopup.selectedItem,
           let id = item.representedObject as? UUID {
            selectedOrgID = id
        } else {
            selectedOrgID = nil
        }

        let contextText = contextView.string
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return MeetingStartInputs(
            meetingName: trimmedName,
            organizationId: selectedOrgID,
            meetingSpecificContext: contextText.isEmpty ? nil : contextText
        )
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === nameField else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        saveButton?.isEnabled = !trimmed.isEmpty
    }
}
