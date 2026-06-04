import SwiftUI

/// Floating editor for the *currently active* recording's metadata (Phase E).
/// Reached from the menu-bar dropdown's "Edit current meeting…" entry —
/// the main window is typically not open while a meeting is in progress,
/// which is why this surface is its own `Window` scene.
///
/// Edits flow into `MeetingContextStore.pending.snapshot`; the compiled
/// prompt is recomputed on every commit so the value is fresh when the
/// pipeline consumes it at file-arrival time.
///
/// Auto-closes when `pending` becomes nil — that's the signal that the
/// audio file landed and the pipeline consumed the snapshot (last write
/// wins for any pending edits, as documented in `MeetingContextStore`).
struct CurrentMeetingEditorView: View {
    @Environment(MeetingContextStore.self) private var contextStore
    @Environment(OrganizationStore.self) private var organizations
    @Environment(GeneralContextStore.self) private var generalContext
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var draftName: String = ""
    @State private var draftOrgId: UUID? = nil
    @State private var draftContext: String = ""

    /// Identity of the recording whose values are currently loaded into the
    /// draft fields. `startedAt` is unique per recording, so when a new
    /// recording begins this no longer matches `pending.startedAt` and the
    /// draft is reloaded. This window is a singleton `Window` scene whose
    /// `@State` survives being dismissed and reopened — without keying the
    /// load on the recording identity (a one-shot `loaded` flag did this
    /// before), the editor kept showing the *previous* meeting's name/org/
    /// context, and any edit committed that stale name onto the new active
    /// recording.
    @State private var loadedStartedAt: Date?

    /// Sentinel for the "No Organization" picker entry. Driven through
    /// `draftOrgId` as a sentinel UUID so the SwiftUI Picker can bind to
    /// a single optional-free value.
    private static let noOrgID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var body: some View {
        Group {
            if contextStore.pending != nil {
                form
            } else {
                ContentUnavailableView(
                    "No active recording",
                    systemImage: "waveform.slash",
                    description: Text("Start a recording from the hotkey to edit its context here.")
                )
                .frame(minWidth: 360, minHeight: 200)
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 360)
        .navigationTitle("Current meeting")
        .onAppear(perform: loadDraftIfNeeded)
        .onChange(of: contextStore.pending?.startedAt) { _, _ in
            // A new recording (different `startedAt`) replaced the pending
            // slot while this singleton window was alive — reload so we edit
            // the active meeting, not the one that was here before.
            loadDraftIfNeeded()
        }
        .onChange(of: contextStore.pending == nil) { _, becameNil in
            if becameNil {
                dismissWindow()
            }
        }
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section("Meeting") {
                TextField("Meeting name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draftName) { _, new in
                        commit(name: new)
                    }
            }
            Section("Organization") {
                Picker("Organization", selection: orgPickerBinding) {
                    Text("No Organization").tag(Self.noOrgID)
                    ForEach(organizations.organizations) { org in
                        Text(org.isDefault ? "\(org.name) (default)" : org.name).tag(org.id)
                    }
                }
                .pickerStyle(.menu)
            }
            Section("Meeting-specific context") {
                TextEditor(text: $draftContext)
                    .frame(minHeight: 120)
                    .border(Color.secondary.opacity(0.2))
                    .onChange(of: draftContext) { _, new in
                        commit(context: new)
                    }
                Text("Sent to the transcription endpoint as part of the prompt when the file lands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Done") { dismissWindow() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
    }

    private var orgPickerBinding: Binding<UUID> {
        Binding(
            get: { draftOrgId ?? Self.noOrgID },
            set: { new in
                let resolved = (new == Self.noOrgID) ? nil : new
                draftOrgId = resolved
                commit(org: resolved)
            }
        )
    }

    // MARK: - Sync helpers

    private func loadDraftIfNeeded() {
        guard let pending = contextStore.pending else { return }
        // Already showing this recording — don't clobber in-progress edits.
        // `update(...)` bumps `lastEditedAt` but never `startedAt`, so a
        // commit from this very editor won't trigger a reload.
        guard loadedStartedAt != pending.startedAt else { return }
        let snapshot = pending.snapshot
        draftName = snapshot.meetingName
        draftOrgId = snapshot.organizationId
        draftContext = snapshot.meetingSpecificContext ?? ""
        loadedStartedAt = pending.startedAt
    }

    /// Commit changes to the store and recompile the prompt. Each editor
    /// field calls this with just its own slice; we pull the rest from the
    /// current draft state.
    private func commit(name: String? = nil, org: UUID?? = nil, context: String? = nil) {
        guard contextStore.pending != nil else { return }
        let effectiveName = name ?? draftName
        let effectiveOrgID: UUID? = {
            if let org { return org }
            return draftOrgId
        }()
        let effectiveContext = context ?? draftContext
        let org = effectiveOrgID.flatMap { organizations.organization(id: $0) }
        let general = generalContext.current
        let compiled = ContextCompiler.compile(
            meetingName: effectiveName,
            meetingSpecificContext: effectiveContext.isEmpty ? nil : effectiveContext,
            organization: org,
            wrapperPrefix: general.wrapperPrefix,
            generalContext: general.generalContext
        )
        contextStore.update(
            meetingName: effectiveName,
            organizationId: .some(effectiveOrgID),
            organizationName: .some(org?.name),
            meetingSpecificContext: .some(effectiveContext.isEmpty ? nil : effectiveContext),
            resolvedCompiledContext: compiled
        )
    }
}
