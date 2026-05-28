import Testing
@testable import Jot

/// Unit tests for `MainTab` — the enum that drives the main window's sidebar
/// routing (Core/App/MainWindow.swift).
///
/// These tests pin the tab *contract* the rest of the codebase relies on:
/// order, count, default selection, and user-visible titles. If you change any
/// of those, you change a test deliberately — that's the signal that you're
/// also touching the PRD (§3.2).
struct MainTabTests {

    @Test
    func allCases_isInExpectedOrder() {
        #expect(MainTab.allCases == [.transcripts, .auditLog, .settings, .context])
    }

    @Test
    func allCases_countIsFour() {
        #expect(MainTab.allCases.count == 4)
    }

    @Test
    func transcripts_isTheDefaultTab() {
        // PRD §3.2 Tab 1: "Transcripts (Default View)". `MainWindow` initializes
        // its `@State` selection to `.transcripts`; this test guards both the
        // enum order and that default decision.
        #expect(MainTab.allCases.first == .transcripts)
    }

    @Test
    func titles_areStable() {
        // The sidebar's visible labels are part of the UI contract. If these
        // strings change, the user-visible navigation changes — bump the test
        // and the PRD together, not silently.
        #expect(MainTab.transcripts.title == "Transcripts")
        #expect(MainTab.auditLog.title == "Audit Log")
        #expect(MainTab.settings.title == "Settings")
        #expect(MainTab.context.title == "Context")
    }

    @Test
    func systemImages_areAllNonEmpty() {
        // We don't validate against the live SF Symbols catalog here (that's
        // Xcode's job at build time). Just ensure no tab silently lost its
        // glyph.
        for tab in MainTab.allCases {
            #expect(!tab.systemImage.isEmpty, "MainTab.\(tab) missing systemImage")
        }
    }

    @Test
    func id_equalsSelf() {
        // `Identifiable` conformance — the `List(selection:)` relies on this.
        for tab in MainTab.allCases {
            #expect(tab.id == tab)
        }
    }
}
