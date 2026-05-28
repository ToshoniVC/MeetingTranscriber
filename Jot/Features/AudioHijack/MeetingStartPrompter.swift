import AppKit
import Foundation

/// Abstracts the meeting-start prompt so tests can substitute a non-modal
/// fake. Production calls into AppKit on the main actor.
///
/// The prompter is stateless — orgs are passed in at call time so the
/// caller (AudioHijackController) owns the data dependency on
/// `OrganizationStore`.
@MainActor
protocol MeetingStartPrompting: AnyObject {
    /// Show the prompt and return the user's choices. Returns nil if the
    /// user cancelled.
    ///
    /// - Parameters:
    ///   - organizations: full org list to populate the picker. Order is
    ///     used as-is in the dropdown (caller is expected to pre-sort —
    ///     `OrganizationStore.organizations` already sorts default first).
    ///   - defaultOrgId: pre-selected org id, or `nil` to default to
    ///     the "No Organization" sentinel.
    func ask(
        organizations: [Organization],
        defaultOrgId: UUID?
    ) async -> MeetingStartInputs?
}

/// Production prompt: an `NSAlert` with a stacked accessory view holding
/// a name field, an organization popup, and a freeform context box.
///
/// Validation is enforced via the "Start" button's enabled state — flipped
/// off whenever the trimmed meeting name is empty. Org always has a
/// selection (either a real org or the "No Organization" sentinel) so it
/// can't fail validation.
@MainActor
final class SystemMeetingStartPrompter: NSObject, MeetingStartPrompting, NSTextFieldDelegate {

    /// Sentinel id used in the popup to represent "No Organization".
    /// Lives on the menu item's `representedObject`; never written to
    /// disk.
    private static let noOrgTag = -1

    private weak var startButton: NSButton?
    private weak var nameField: NSTextField?

    func ask(
        organizations: [Organization],
        defaultOrgId: UUID?
    ) async -> MeetingStartInputs? {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Start recording"
        alert.informativeText = "Pick a meeting name and an organization. Optional notes are sent to the transcription endpoint as context."
        let startButton = alert.addButton(withTitle: "Start Recording")
        alert.addButton(withTitle: "Cancel")
        self.startButton = startButton

        // Accessory layout: vertical stack of (name field) (org popup)
        // (context label) (scrollable context box). Width 380, total 220.
        let width: CGFloat = 380
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 230))

        // Name field
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

        // Org popup
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
            orgPopup.selectItem(at: idx + 1) // +1 because index 0 is the sentinel
        }
        container.addSubview(orgPopup)

        // Context box
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

        // Disable "Start" until a non-empty name is entered.
        startButton.isEnabled = false

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
            selectedOrgID = nil // "No Organization" sentinel
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
        startButton?.isEnabled = !trimmed.isEmpty
    }
}
