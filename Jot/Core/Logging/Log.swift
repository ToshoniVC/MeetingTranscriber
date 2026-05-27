import Foundation
import os.log

/// Centralized `Logger` factory. Per Claude/coding-instructions.md §5: every
/// component logs via `os.Logger` with the project subsystem and a per-feature
/// category — never `print()`.
///
/// Phase 8 will add a hidden `⌥`-click toggle that flips the log level
/// from `info` to `debug` at runtime. For now `Logger` honors the system
/// default (info).
enum Log {
    static let subsystem = "com.toshonivc.jot"

    /// One category per feature folder under `Features/`. Add new ones as
    /// features land — keep the list flat and matched to folder names so
    /// `log show --predicate 'subsystem == "com.toshonivc.jot" && category == "watcher"'`
    /// always works for the corresponding feature.
    static let app           = Logger(subsystem: subsystem, category: "app")
    static let watcher       = Logger(subsystem: subsystem, category: "watcher")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let pipeline      = Logger(subsystem: subsystem, category: "pipeline")
    static let settings      = Logger(subsystem: subsystem, category: "settings")
}
