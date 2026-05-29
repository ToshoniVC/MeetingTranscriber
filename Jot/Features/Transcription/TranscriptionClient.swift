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
    /// - Returns: a `TranscriptionResult` carrying the transcript text,
    ///   the model-reported duration, the per-segment metadata, and the
    ///   verbatim JSON body the server returned (so callers can persist
    ///   the canonical response on disk).
    /// - Throws: a `TranscriptionError` describing what went wrong.
    func transcribe(
        audio: URL,
        baseURL: URL,
        model: String,
        apiKey: String,
        prompt: String? = nil
    ) async throws -> TranscriptionResult {
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
    ) async throws -> TranscriptionResult {
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

        let bodyString = String(data: data, encoding: .utf8) ?? ""
        if let typed = TranscriptionErrorMapper.error(
            forStatus: http.statusCode,
            bodyHint: bodyString
        ) {
            // v0.5.2: log the verbatim server body at error level so
            // Console.app captures it even when the rotating
            // transcriber swallows individual provider failures while
            // falling through. The user-facing error already includes
            // a truncated snippet (`TranscriptionError.userFacingMessage`)
            // — this log is the full unfiltered version for debugging.
            Log.transcription.error("HTTP \(http.statusCode, privacy: .public) from \(request.urlRequest.url?.absoluteString ?? "<unknown URL>", privacy: .public): \(bodyString, privacy: .public)")
            throw typed
        }

        let decoded: VerboseTranscriptionResponse
        do {
            decoded = try JSONDecoder().decode(VerboseTranscriptionResponse.self, from: data)
        } catch {
            throw TranscriptionError.malformedResponse
        }

        // Diagnostic: when Whisper truncates a long meeting it reports the
        // full audio duration but the last segment's `end` falls well short
        // of it. Log both so the gap shows up in Console.app on every run —
        // no code change needed to debug a short transcript next time.
        let duration = decoded.duration ?? -1
        let lastEnd = decoded.segments?.last?.end ?? -1
        let gap = (duration >= 0 && lastEnd >= 0) ? duration - lastEnd : -1
        Log.transcription.info("Transcribed: duration=\(duration, privacy: .public)s lastSegmentEnd=\(lastEnd, privacy: .public)s gap=\(gap, privacy: .public)s textChars=\(decoded.text.count, privacy: .public)")

        let segments: [TranscriptionResult.Segment] = (decoded.segments ?? []).compactMap { raw in
            guard let start = raw.start, let end = raw.end, let text = raw.text else { return nil }
            return TranscriptionResult.Segment(start: start, end: end, text: text)
        }

        return TranscriptionResult(
            text: decoded.text.trimmingCharacters(in: CharacterSet.newlines),
            duration: decoded.duration,
            segments: segments,
            rawJSON: data
        )
    }

    // MARK: - Decoding

    /// Subset of the `verbose_json` response we decode. The full payload
    /// has more fields (`task`, `language`, per-segment metadata like
    /// `tokens`, `avg_logprob`, etc.); we keep the model narrow so a future
    /// server-side addition doesn't break decoding. The unmodeled fields
    /// still survive the round-trip on disk because `FileOrganizer` writes
    /// the verbatim `rawJSON` bytes, not a re-encoded form of this struct.
    private struct VerboseTranscriptionResponse: Decodable {
        let text: String
        let duration: Double?
        let segments: [Segment]?

        struct Segment: Decodable {
            let start: Double?
            let end: Double?
            let text: String?
        }
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
