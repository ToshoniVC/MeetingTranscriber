import Foundation

/// Public surface the Pipeline depends on. Concrete impl:
/// `ClaudeCodeRoutineClient`. Tests substitute a fake to drive the
/// pipeline's failure / success paths without standing up a `URLProtocol`
/// mock.
protocol ClaudeCodeRoutineFiring: Sendable {

    /// Fire the configured Claude Code routine once. Returns on success
    /// (the API echoes a routine run identifier we don't currently need);
    /// throws a `ClaudeCodeRoutineError` on any non-2xx outcome.
    ///
    /// - Parameter text: full body text. Already composed by the caller —
    ///   typically the user's configured extra text plus an appended
    ///   line referencing the Notion page that was just created.
    func fire(config: ClaudeCodeRoutineConfig, text: String) async throws
}

/// Concrete `ClaudeCodeRoutineFiring` that talks to the Anthropic Claude
/// Code routine fire endpoint via `URLSession`. Mirrors `NotionClient`
/// in shape: an `actor` for in-flight task isolation, hand-rolled
/// request assembly (no SDK dependency per `coding-instructions.md` §5).
///
/// Retry posture: one retry on transport errors only (PRD §6 — "at most
/// one retry on transient network failure"). 4xx / 5xx responses
/// surface immediately.
actor ClaudeCodeRoutineClient: ClaudeCodeRoutineFiring {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fire(config: ClaudeCodeRoutineConfig, text: String) async throws {
        do {
            try await performFire(config: config, text: text)
        } catch ClaudeCodeRoutineError.transport {
            // One retry on transient transport failure. Status-coded
            // errors are not retried — they're not the kind of failure
            // that goes away by trying again.
            try await performFire(config: config, text: text)
        }
    }

    // MARK: - Private

    private func performFire(config: ClaudeCodeRoutineConfig, text: String) async throws {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(config.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(ClaudeCodeRoutineRequest(text: text))
        } catch {
            throw ClaudeCodeRoutineError.internalInconsistency("Failed to encode request body: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ClaudeCodeRoutineErrorMapper.transport(error)
        } catch {
            throw ClaudeCodeRoutineError.transport(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeCodeRoutineError.decoding(message: "Response was not HTTP.")
        }

        let bodyString = String(data: data, encoding: .utf8) ?? ""
        let retryAfter: TimeInterval? = http.value(forHTTPHeaderField: "Retry-After")
            .flatMap { TimeInterval($0) }

        if let mapped = ClaudeCodeRoutineErrorMapper.error(
            forStatus: http.statusCode,
            bodyHint: bodyString,
            retryAfter: retryAfter
        ) {
            throw mapped
        }
        // 2xx — done. We deliberately ignore the response body; the
        // routine run identifier isn't useful inside Jot.
    }
}
