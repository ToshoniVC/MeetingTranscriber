import Foundation

/// Errors `ShortcutInvoker` throws.
enum ShortcutError: Error, Equatable {
    /// `/usr/bin/shortcuts` exited non-zero. `code` is the exit status and
    /// `stderr` is its captured stderr (truncated to a few hundred chars).
    case nonZeroExit(code: Int32, stderr: String)

    /// Underlying `Process.run()` failed before the shortcut could start.
    case launchFailed(String)

    /// User-facing message suitable for inline display or audit-log row.
    var userFacingMessage: String {
        switch self {
        case .nonZeroExit(let code, let stderr):
            let extra = stderr.isEmpty ? "" : " — \(stderr.prefix(200))"
            return "Shortcut failed (exit \(code))\(extra)"
        case .launchFailed(let message):
            return "Couldn't launch shortcuts: \(message)"
        }
    }
}

/// What we capture from a process run. Compact enough that tests can build
/// these without an actual Process.
struct ProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Abstraction so tests can run shortcuts without spawning real processes.
protocol ProcessRunner: Sendable {
    /// Run `executable` with `arguments`. If `stdin` is non-nil, that string
    /// is written to the process's stdin before it starts (used to pipe the
    /// meeting name into `shortcuts run --input-path -`).
    func run(executable: URL, arguments: [String], stdin: String?) async throws -> ProcessResult
}

/// Production runner — actually spawns `Process`. Captures stdout/stderr.
struct SystemProcessRunner: ProcessRunner {
    func run(executable: URL, arguments: [String], stdin: String?) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            let stdinPipe: Pipe?
            if stdin != nil {
                let pipe = Pipe()
                process.standardInput = pipe
                stdinPipe = pipe
            } else {
                stdinPipe = nil
            }
            process.terminationHandler = { proc in
                let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: ProcessResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? ""
                ))
            }
            do {
                try process.run()
                if let stdinPipe, let stdin {
                    let handle = stdinPipe.fileHandleForWriting
                    try? handle.write(contentsOf: Data(stdin.utf8))
                    try? handle.close()
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Invokes a user-defined Apple Shortcut by name.
///
/// Per PRD §5: pressing the recording hotkey should trigger an Apple
/// Shortcut that asks the user for a meeting name and tells Audio Hijack
/// to start recording. Jot just kicks the shortcut off; the shortcut itself
/// is user-authored (we document creating it in the README).
///
/// `actor` so concurrent triggers serialize and we don't fork two shortcuts
/// in a race.
actor ShortcutInvoker {
    /// Path to the macOS `shortcuts` CLI. Set in `init` so tests can point
    /// it elsewhere if they ever need to.
    private let executable: URL
    private let runner: ProcessRunner

    init(
        executable: URL = URL(fileURLWithPath: "/usr/bin/shortcuts"),
        runner: ProcessRunner = SystemProcessRunner()
    ) {
        self.executable = executable
        self.runner = runner
    }

    /// Run the shortcut with the given name. When `input` is non-nil, it is
    /// piped to the shortcut on stdin via `--input-path -`, so the Shortcut
    /// can read it as "Shortcut Input" — useful for passing the meeting name
    /// the user just typed in Jot's prompter. Throws `ShortcutError` on
    /// non-zero exit or launch failure.
    func run(shortcutName: String, input: String? = nil) async throws {
        var args = ["run", shortcutName]
        if input != nil {
            args.append(contentsOf: ["--input-path", "-"])
        }
        let result: ProcessResult
        do {
            result = try await runner.run(
                executable: executable,
                arguments: args,
                stdin: input
            )
        } catch {
            throw ShortcutError.launchFailed(error.localizedDescription)
        }
        if result.exitCode != 0 {
            throw ShortcutError.nonZeroExit(code: result.exitCode, stderr: result.stderr)
        }
    }
}
