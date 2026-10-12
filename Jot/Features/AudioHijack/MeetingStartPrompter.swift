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
/// a name field, an organization popup, a language popup, and a freeform
/// context box.
///
/// Validation is enforced via the "Start" button's enabled state — flipped
/// off whenever the trimmed meeting name is empty. Org and language always
/// have a selection (a real value or their "default" sentinel) so they
/// can't fail validation.
@MainActor
final class SystemMeetingStartPrompter: NSObject, MeetingStartPrompting, NSTextFieldDelegate {

    /// Sentinel id used in the popup to represent "No Organization".
    /// Lives on the menu item's `representedObject`; never written to
    /// disk.
    private static let noOrgTag = -1

    /// Sentinel for the language popup's "Default" entry (inherit the
    /// organization / app-wide language). Maps to `languageCode == nil`.
    private static let inheritLanguageTag = -2

    private weak var startButton: NSButton?
    private weak var nameField: NSTextField?

    func ask(
        organizations: [Organization],
        defaultOrgId: UUID?
    ) async -> MeetingStartInputs? {
        // Hide any visible regular windows (typically the main app window
        // left open from earlier Settings / Context tab use) BEFORE we
        // activate the app. `NSApp.activate(ignoringOtherApps:)` re-fronts
        // whichever window the app last had visible — without this guard
        // the main window pops up alongside the prompt, which is
        // distracting at "start meeting" time (user feedback, v0.2.0).
        for window in NSApp.windows
            where window.isVisible && window.level == .normal {
            window.orderOut(nil)
        }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Recording in progress — add meeting details"
        alert.informativeText = "Audio Hijack is already capturing. Pick a meeting name and organization to attach as metadata; optional notes are sent to the transcription endpoint as context. You can also skip this — the recording continues either way."
        let startButton = alert.addButton(withTitle: "Save details")
        alert.addButton(withTitle: "Skip")
        self.startButton = startButton

        // Accessory layout: vertical stack of (name field) (org popup)
        // (language popup) (context label) (scrollable context box).
        // Width 380, total 282. Rows are 52 pt apart: 16 pt label, 22 pt
        // control, 14 pt gap.
        let width: CGFloat = 380
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 282))

        // Name field
        let nameLabel = NSTextField(labelWithString: "Meeting name")
        nameLabel.frame = NSRect(x: 0, y: 256, width: width, height: 16)
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor
        container.addSubview(nameLabel)

        let nameField = NSTextField(frame: NSRect(x: 0, y: 230, width: width, height: 22))
        nameField.placeholderString = "e.g. Standup, Client Call"
        nameField.delegate = self
        container.addSubview(nameField)
        self.nameField = nameField

        // Org popup
        let orgLabel = NSTextField(labelWithString: "Organization")
        orgLabel.frame = NSRect(x: 0, y: 204, width: width, height: 16)
        orgLabel.font = .systemFont(ofSize: 11)
        orgLabel.textColor = .secondaryLabelColor
        container.addSubview(orgLabel)

        let orgPopup = NSPopUpButton(frame: NSRect(x: 0, y: 178, width: width, height: 22))
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

        // Language popup. "Default" inherits the organization's language,
        // then the app-wide default (Context → General). Pinning the
        // language stops Whisper drifting into another language over
        // silence and translating the speech.
        let languageLabel = NSTextField(labelWithString: "Language")
        languageLabel.frame = NSRect(x: 0, y: 152, width: width, height: 16)
        languageLabel.font = .systemFont(ofSize: 11)
        languageLabel.textColor = .secondaryLabelColor
        container.addSubview(languageLabel)

        let languagePopup = NSPopUpButton(frame: NSRect(x: 0, y: 126, width: width, height: 22))
        languagePopup.addItem(withTitle: "Default (organization / app setting)")
        languagePopup.menu?.items.last?.representedObject = Self.inheritLanguageTag
        languagePopup.addItem(withTitle: TranscriptionLanguage.displayName(for: TranscriptionLanguage.autoDetectCode))
        languagePopup.menu?.items.last?.representedObject = TranscriptionLanguage.autoDetectCode
        for code in TranscriptionLanguage.pickerCodes {
            languagePopup.addItem(withTitle: "\(TranscriptionLanguage.displayName(for: code)) (\(code))")
            languagePopup.menu?.items.last?.representedObject = code
        }
        container.addSubview(languagePopup)

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

        let selectedLanguage = languagePopup.selectedItem?.representedObject as? String

        let contextText = contextView.string
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return MeetingStartInputs(
            meetingName: trimmedName,
            organizationId: selectedOrgID,
            meetingSpecificContext: contextText.isEmpty ? nil : contextText,
            languageCode: selectedLanguage
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
