import Foundation

/// Composes the HTTP request + on-disk multipart body for a single
/// transcription call.
///
/// **Why a separate type:** the body is streamed off disk via
/// `URLSession.uploadTask(with:fromFile:)`, so we need to write a
/// `multipart/form-data` envelope to a temporary file once and let
/// URLSession upload it. Splitting "compose the request" from "execute
/// the request" also makes it cheap to unit-test the request shape
/// (headers, boundary, fields) without any networking.
///
/// The output `URLRequest` carries the headers; the temporary `bodyFileURL`
/// holds the assembled body. Callers are responsible for deleting the
/// temp file after the request completes (the client does this in `defer`).
struct TranscriptionRequest {

    let urlRequest: URLRequest
    let bodyFileURL: URL

    /// Build a request for `audio` against the given OpenAI-compatible
    /// endpoint. Fields per OpenAI's `/audio/transcriptions` spec:
    ///   - `file` (audio binary)
    ///   - `model` (string)
    ///   - `response_format` (we force `text` — plain transcript, no JSON)
    ///
    /// Auth is a `Bearer` token in the `Authorization` header.
    ///
    /// - Parameters:
    ///   - audio: file URL of the audio to transcribe. Must exist and be
    ///     a regular file (validated by the caller).
    ///   - baseURL: full endpoint URL (e.g.,
    ///     `https://api.groq.com/openai/v1/audio/transcriptions`).
    ///   - model: model string sent in the `model` form field.
    ///   - apiKey: bearer token. Won't be logged anywhere.
    ///   - timeout: per-request timeout. Plan §4 step 5: 5 minutes.
    ///   - boundary: multipart boundary string. Defaults to a fresh UUID-
    ///     based value; tests inject a deterministic one to make assertions.
    ///   - bodyFileFactory: closure returning the temp URL to assemble the
    ///     body into. Defaults to a tmp-dir UUID file; tests inject a custom
    ///     location to inspect the bytes.
    init(
        audio: URL,
        baseURL: URL,
        model: String,
        apiKey: String,
        timeout: TimeInterval = 300,
        boundary: String = Self.makeBoundary(),
        bodyFileFactory: () -> URL = Self.defaultBodyFile
    ) throws {
        let bodyFile = bodyFileFactory()

        // 1) Assemble the multipart body on disk so URLSession can stream it.
        try Self.writeMultipartBody(
            to: bodyFile,
            boundary: boundary,
            model: model,
            audio: audio
        )

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // OpenAI-compatible servers care about Content-Length for streamed
        // uploads. URLSession sets this when given a fromFile: body, so we
        // don't add it manually here.

        self.urlRequest = request
        self.bodyFileURL = bodyFile
    }

    // MARK: - Multipart body

    /// Writes the multipart body for `audio` + `model` + `response_format=text`
    /// to `bodyFile`. The audio binary is streamed in 64 KiB chunks so we
    /// never load the whole file into memory (a 40 MB recording would balloon
    /// Jot's RSS otherwise).
    private static func writeMultipartBody(
        to bodyFile: URL,
        boundary: String,
        model: String,
        audio: URL
    ) throws {
        FileManager.default.createFile(atPath: bodyFile.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: bodyFile)
        defer { try? handle.close() }

        // Helper: write a UTF-8 string fragment.
        func write(_ string: String) throws {
            try handle.write(contentsOf: Data(string.utf8))
        }

        // --- model field ---
        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        try write("\(model)\r\n")

        // --- response_format field (force plain text) ---
        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        try write("text\r\n")

        // --- file field (streamed) ---
        let filename = audio.lastPathComponent
        let mimeType = mimeType(for: audio.pathExtension.lowercased())
        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        try write("Content-Type: \(mimeType)\r\n\r\n")

        // Stream the audio file in 64 KiB chunks.
        let reader = try FileHandle(forReadingFrom: audio)
        defer { try? reader.close() }
        while true {
            let chunk = try reader.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try handle.write(contentsOf: chunk)
        }

        try write("\r\n")

        // --- closing boundary ---
        try write("--\(boundary)--\r\n")
    }

    private static func mimeType(for ext: String) -> String {
        switch ext {
        case "mp3":  return "audio/mpeg"
        case "m4a":  return "audio/mp4"
        case "wav":  return "audio/wav"
        default:     return "application/octet-stream"
        }
    }

    // MARK: - Defaults

    /// Produces a multipart boundary like `--JotBoundary-<uuid>` — long enough
    /// that it can't appear inside a real audio file by accident.
    static func makeBoundary() -> String {
        "JotBoundary-" + UUID().uuidString
    }

    /// Returns a fresh, unique tmp-dir URL to write the multipart body to.
    static func defaultBodyFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-multipart-\(UUID().uuidString).bin")
    }
}
