import Foundation
import Observation

#if !DEBUG
import Sparkle
#endif

/// Test-substitutable protocol for "ask the updater to do a thing". Lets
/// `SystemSection` and tests bind to behavior, not the Sparkle framework.
@MainActor
protocol UpdateChecking: AnyObject {
    /// `true` when the updater is in a state where `checkForUpdates()` will
    /// actually do something (no check currently in flight, network thinks
    /// it can reach the appcast, etc.). The Settings button disables when
    /// this is `false`.
    var canCheckForUpdates: Bool { get }

    /// Display string for the version of a pending update found by the
    /// background check, or `nil` if Jot is up to date. The sidebar footer
    /// renders an "Update available: vX.Y" row when this is non-nil.
    /// Populated by Sparkle's `updater(_:didFindValidUpdate:)` delegate
    /// call and cleared on `updaterDidNotFindUpdate(_:)`. Always `nil` in
    /// Debug.
    var pendingUpdateVersion: String? { get }

    /// Show the standard Sparkle "Check for Updates" panel. In Debug this
    /// is a no-op log line so the dev build never tries to replace itself.
    func checkForUpdates()
}

#if DEBUG

/// Debug stub. The whole point of the two-install model is that `Jot Dev`
/// is updated by ⌘R in Xcode, not by Sparkle downloading new binaries on
/// top of itself. We compile Sparkle's call sites out entirely so a missing
/// or wrong `SUPublicEDKey` in Debug doesn't matter and there's zero
/// chance of cross-contamination with the Release auto-update path.
@MainActor
@Observable
final class SparkleUpdater: UpdateChecking {
    var canCheckForUpdates: Bool { false }
    var pendingUpdateVersion: String? { nil }

    init() {}

    func checkForUpdates() {
        Log.app.info("SparkleUpdater (Debug stub): manual update check requested — no-op in Debug build")
    }
}

#else

/// Production wrapper. Thin shell around `SPUStandardUpdaterController` so
/// the rest of the app never imports Sparkle directly.
///
/// The controller is created with `startingUpdater: true`, which:
///   1. Schedules the launch-time check (subject to SUEnableAutomaticChecks).
///   2. Starts the SUScheduledCheckInterval background timer.
///
/// `Info.plist` carries SUFeedURL + SUPublicEDKey + the auto-check flags.
@MainActor
@Observable
final class SparkleUpdater: NSObject, UpdateChecking {

    /// Mirrors `controller.updater.canCheckForUpdates` so SwiftUI can bind
    /// disabled state to it. Observed via KVO inside `init`.
    private(set) var canCheckForUpdates: Bool = false

    /// Set when `updater(_:didFindValidUpdate:)` fires on a background
    /// check, cleared when `updaterDidNotFindUpdate(_:)` fires. Used by
    /// `MainWindow`'s sidebar footer to surface "Update available: vX.Y"
    /// without waiting for Sparkle's modal dialog.
    private(set) var pendingUpdateVersion: String?

    /// IUO because `SPUStandardUpdaterController` wants the delegate at
    /// construction time, and we can only pass `self` after `super.init()`.
    /// Set in `init` and never replaced — effectively `let` from any
    /// caller's perspective.
    private var controller: SPUStandardUpdaterController!
    /// Held to keep the KVO observation alive for the wrapper's lifetime.
    /// `NSKeyValueObservation` auto-invalidates on dealloc, so we don't
    /// need a `deinit` cleanup — which would be awkward across the
    /// MainActor boundary anyway.
    private var canCheckObserver: NSKeyValueObservation?

    override init() {
        super.init()
        // Now `self` is available — Sparkle holds the delegate weakly, so
        // a strong-reference cycle is impossible.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.canCheckForUpdates = controller.updater.canCheckForUpdates
        // Sparkle's `canCheckForUpdates` flips while a check is in flight.
        // Mirror it onto our @Observable so SwiftUI re-renders the button.
        self.canCheckObserver = controller.updater.observe(
            \.canCheckForUpdates,
             options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

extension SparkleUpdater: SPUUpdaterDelegate {
    /// Called by Sparkle after a successful appcast check that turned up
    /// a newer version. Fires for both automatic launch/scheduled checks
    /// and manual ones triggered by the Settings button. We hop to
    /// `@MainActor` before mutating our `@Observable` state.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor [weak self] in
            self?.pendingUpdateVersion = version
        }
    }

    /// Called by Sparkle when a check completes and there's nothing newer
    /// than the running build. Clears any stale "update available" badge.
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor [weak self] in
            self?.pendingUpdateVersion = nil
        }
    }
}

#endif
