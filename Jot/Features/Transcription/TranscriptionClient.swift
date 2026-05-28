import Foundation

/// Generic OpenAI-compatible transcription client. Works against Groq, OpenAI,
/// or any other service exposing `/audio/transcriptions` with the same
/// multipart contract — the user picks the endpoint, model, and key in
/// Settings.
///
/// **Why an actor:** keeps per-instance state (the injected `URLSession`,
/// any in-flight tasks) main-thread-isolated-enough without needing locks,
/// and lets callers `await transcribe(...)` from anywhere.
///
/// **Streaming upload:** `URLSession.uploadTask(with:fromFile:)` streams the
/// pre-assembled multipart body off disk, so even a 40 MB recording costs us
/// ~64 KiB of resident memory at a time.
actor TranscriptionClient {

    private let session: URLSession

    /// - Parameter session: URLSession used for the upload. Production passes
    ///   `.shared`; tests inject a session configured with a `URLProtocol`
    ///   subclass so no actual network traffic happens.
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Transcribe `audio` using the given OpenAI-compatible endpoint.
    ///
    /// Retries **once** on `transientNetwork` / `timeout` (per plan §4
    /// step 5). 4xx errors surface immediately — they're not the kind of
    /// failure that goes away on retry.
    ///
    /// - Parameters:
    ///   - audio: file URL of the audio. Must exist and be a regular file.
    ///   - baseURL: full endpoint URL (e.g.,
    ///     `https://api.groq.com/openai/v1/audio/transcriptions`).
    ///   - model: model string (e.g., `whisper-large-v3` for Groq,
    ///     `whisper-1` for OpenAI).
    ///   - apiKey: bearer token. Never logged.
    /// - Returns: the transcript text on success.
    /// - Throws: a `TranscriptionError` describing what went wrong.
    func transcribe(
        audio: URL,
        baseURL: URL,
        model: String,
        apiKey: String,
        prompt: String? = nil
    ) async throws -> String {
        try validate(audio: audio, baseURL: baseURL, model: model, apiKey: apiKey)

        do {
            return try await performTranscription(
                audio: audio, baseURL: baseURL, model: model, apiKey: apiKey, prompt: prompt
            )
        } catch let error as TranscriptionError where TranscriptionErrorMapper.isRetryable(error) {
            Log.transcription.warning("Transcription transient failure, retrying once: \(error.userFacingMessage, privacy: .public)")
            return try await performTranscription(
                audio: audio, baseURL: baseURL, model: model, apiKey: apiKey, prompt: prompt
            )
        }
    }

    // MARK: - Private

    private func validate(audio: URL, baseURL: URL, model: String, apiKey: String) throws {
        if baseURL.scheme == nil {
            throw TranscriptionError.invalidEndpoint(rawURL: baseURL.absoluteString)
        }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TranscriptionError.internalInconsistency("model string is empty")
        }
        if apiKey.isEmpty {
            throw TranscriptionError.invalidAPIKey
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: audio.path(percentEncoded: false), isDirectory: &isDir),
              !isDir.boolValue
        else {
            throw TranscriptionError.internalInconsistency("audio file not found at \(audio.path(percentEncoded: false))")
        }
    }

    private func performTranscription(
        audio: URL,
        baseURL: URL,
        model: String,
        apiKey: String,
        prompt: String?
    ) async throws -> String {
        let request = try TranscriptionRequest(
            audio: audio,
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            prompt: prompt
        )
        defer {
            // Clean up the on-disk multipart body whether the request
            // succeeded or threw.
            try? FileManager.default.removeItem(at: request.bodyFileURL)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request.urlRequest, fromFile: request.bodyFileURL)
        } catch let error as URLError {
            throw map(urlError: error)
        } catch {
            throw TranscriptionError.transientNetwork(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.malformedResponse
        }

        if let typed = TranscriptionErrorMapper.error(
            forStatus: http.statusCode,
            bodyHint: String(data: data, encoding: .utf8) ?? ""
        ) {
            throw typed
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw TranscriptionError.malformedResponse
        }

        // The server returns plain text per `response_format=text`. Trim a
        // trailing newline some endpoints add so downstream consumers don't
        // have to.
        return text.trimmingCharacters(in: CharacterSet.newlines)
    }

    private func map(urlError: URLError) -> TranscriptionError {
        switch urlError.code {
        case .timedOut:
            return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .resourceUnavailable:
            return .transientNetwork(message: urlError.localizedDescription)
        case .badURL, .unsupportedURL:
            return .invalidEndpoint(rawURL: urlError.failingURL?.absoluteString ?? "")
        case .userAuthenticationRequired:
            return .invalidAPIKey
        default:
            return .transientNetwork(message: urlError.localizedDescription)
        }
    }
}
