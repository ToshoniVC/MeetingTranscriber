import Testing
import Foundation
@testable import Jot

/// Tests for `ProcessingPipeline.folderTimestamp(for:)` — the date format
/// that prefixes meeting folder names so they sort chronologically.
struct MeetingFolderTimestampTests {

    @Test
    func format_isYearMonthDayHourMinute() {
        // 2026-05-28 14:23:45 local time → "2026.05.28 - 14.23"
        var components = DateComponents()
        components.timeZone = .current
        components.year = 2026
        components.month = 5
        components.day = 28
        components.hour = 14
        components.minute = 23
        components.second = 45
        let date = Calendar.current.date(from: components)!
        #expect(ProcessingPipeline.folderTimestamp(for: date) == "2026.05.28 - 14.23")
    }

    @Test
    func format_padsSingleDigits() {
        var components = DateComponents()
        components.timeZone = .current
        components.year = 2026
        components.month = 1
        components.day = 3
        components.hour = 7
        components.minute = 5
        let date = Calendar.current.date(from: components)!
        #expect(ProcessingPipeline.folderTimestamp(for: date) == "2026.01.03 - 07.05")
    }

    @Test
    func format_uses24HourClock() {
        // 23:59 should render as 23.59, not 11.59 PM or similar.
        var components = DateComponents()
        components.timeZone = .current
        components.year = 2026
        components.month = 12
        components.day = 31
        components.hour = 23
        components.minute = 59
        let date = Calendar.current.date(from: components)!
        #expect(ProcessingPipeline.folderTimestamp(for: date) == "2026.12.31 - 23.59")
    }
}
