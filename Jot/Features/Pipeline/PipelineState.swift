import Foundation

/// The pipeline's current high-level state, broadcast to `MenuBarController`
/// (icon) and any UI surface that wants to react.
///
/// PRD §3.1 defines three icon states (Idle / Processing / Error). We add
/// `notConfigured` for the "user hasn't filled in Settings yet" case so the
/// menu bar can hint at that without lying about the state.
enum PipelineState: Equatable, Sendable {
    /// Settings are incomplete — there's no pipeline running.
    case notConfigured

    /// Pipeline is running but isn't currently working on a file.
    case idle

    /// Pipeline is actively transcribing / organizing `audioURL`.
    case processing(URL)

    /// Last attempt failed. `audioURL` is the file the user can retry from
    /// the Audit Log row; `message` is a one-line user-facing reason.
    case error(URL, String)
}
