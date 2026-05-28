import Testing
import Foundation
@testable import Jot

/// Unit tests for `TranscriptionRequest` — verifies the URLRequest shape and
/// the on-disk multipart body bytes. No networking.
struct TranscriptionRequestTests {

    // MARK: - Helpers

    private static func makeAudio(content: String = "AUDIO_BYTES") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-req-test-audio-\(UUID().uuidString).mp3")
        try? content.data(using: .utf8)!.write(to: url)
        return url
    }

    private static func makeBodyFileFactory() -> () -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-req-test-body-\(UUID().uuidString).bin")
        return { url }
    }

    private static let baseURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    // MARK: - URLRequest shape

    @Test
    func request_usesPOST() throws {
        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let request = try TranscriptionRequest(
            audio: audio, baseURL: Self.baseURL,
            model: "whisper-large-v3", apiKey: "sk-test"
        )
        defer { try? FileManager.default.removeItem(at: request.bodyFileURL) }

        #expect(request.urlRequest.httpMethod == "POST")
    }

    @Test
    func request_includesBearerAuthHeader() throws {
        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let request = try TranscriptionRequest(
            audio: audio, baseURL: Self.baseURL,
            model: "whisper-large-v3", apiKey: "sk-test-abc"
        )
        defer { try? FileManager.default.removeItem(at: request.bodyFileURL) }

        #expect(request.urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-abc")
    }

    @Test
    func request_setsMultipartContentTypeWithBoundary() throws {
        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let request = try TranscriptionRequest(
            audio: audio, baseURL: Self.baseURL,
            model: "whisper-large-v3", apiKey: "sk-test",
            boundary: "TestBoundary123"
        )
        defer { try? FileManager.default.removeItem(at: request.bodyFileURL) }

        let contentType = request.urlRequest.value(forHTTPHeaderField: "Content-Type")
        #expect(contentType == "multipart/form-data; boundary=TestBoundary123")
    }

    @Test
    func request_pointsAtSuppliedURL() throws {
        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let custom = URL(string: "https://localhost:9000/whisper")!
        let request = try TranscriptionRequest(
            audio: audio, baseURL: custom,
            model: "whisper-1", apiKey: "sk-test"
        )
        defer { try? FileManager.default.removeItem(at: request.bodyFileURL) }

        #expect(request.urlRequest.url == custom)
    }

    @Test
    func request_appliesTimeout() throws {
        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let request = try TranscriptionRequest(
            audio: audio, baseURL: Self.baseURL,
            model: "whisper-large-v3", apiKey: "sk-test",
            timeout: 42
        )
        defer { try? FileManager.default.removeItem(at: request.bodyFileURL) }

        #expect(request.urlRequest.timeoutInterval == 42)
    }

    // MARK: - Multipart body bytes

    @Test
    func body_containsModelField() throws {
        let audio = Self.makeAudio(content: "X")
        defer { try? FileManager.default.removeItem(at: audio) }

        let request = try TranscriptionRequest(
            audio: audio, baseURL: Self.baseURL,
            model: "whisper-large-v3", apiKey: "sk",
            boundary: "B"
        )
        defer { try? FileManager.default.removeItem(at: request.bodyFileURL) }

        let body = try Data(contentsOf: request.bodyFileURL)
        let text = String(data: body, encoding: .utf8) ?? ""
        #expect(text.contains("Content-Disposition: form-data; name=\"model\""))
        #expect(text.contains("whisper-large-v3"))
    }

    @Test
    func body_containsResponseFormatTextField() throws {
        let audio = Self.makeAudio(content: "X")
        defer { try? FileManager.default.removeItem(at: audio) }

        let request = try TranscriptionRequest(
            audio: audio, baseURL: Self.baseURL,
            model: "m", apiKey: "sk", boundary: "B"
        )
        defer { try? FileManager.default.removeItem(at: request.bodyFileURL) }

        let body = try Data(contentsOf: request.bodyFileURL)
        let text = String(data: body, encoding: .utf8) ?? ""
        #expect(text.contains("Content-Disposition: form-data; name=\"response_format\""))
        // The literal "text" appears as the field VALUE on its own line; we
        // can't just substring-match "text" because the body contains the
        // word in headers too. Look for the value line specifically.
        #expect(text.range(of: "name=\"response_format\"\r\n\r\ntext\r\n") != nil)
    }

    @Test
    func body_containsFileFieldWithFilenameAndMimeType() throws {
        let audio = Self.makeAudio(content: "AUDIO")
        defer { try? FileManager.default.removeItem(at: audio) }

        let request = try TranscriptionRequest(
            audio: audio, baseURL: Self.baseURL,
            model: "m", apiKey: "sk", boundary: "B"
        )
        defer { try? FileManager.default.removeItem(at: request.bodyFileURL) }

        let body = try Data(contentsOf: request.bodyFileURL)
        let text = String(data: body, encoding: .utf8) ?? ""
        #expect(text.contains("Content-Disposition: form-data; name=\"file\""))
        #expect(text.contains("filename=\"\(audio.lastPathComponent)\""))
        #expect(text.contains("Content-Type: audio/mpeg"))
    }

    @Test
    func body_includesAudioBytesAndClosingBoundary() throws {
        let payload = "HELLO_AUDIO_PAYLOAD"
        let audio = Self.makeAudio(content: payload)
        defer { try? FileManager.default.removeItem(at: audio) }

        let request = try TranscriptionRequest(
            audio: audio, baseURL: Self.baseURL,
            model: "m", apiKey: "sk", boundary: "BBOUND"
        )
        defer { try? FileManager.default.removeItem(at: request.bodyFileURL) }

        let body = try Data(contentsOf: request.bodyFileURL)
        let text = String(data: body, encoding: .utf8) ?? ""
        #expect(text.contains(payload))
        #expect(text.hasSuffix("--BBOUND--\r\n"))
    }

    // MARK: - MIME type selection

    @Test
    func m4aFile_getsAudioMp4MimeType() throws {
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-mime-\(UUID().uuidString).m4a")
        try "x".data(using: .utf8)!.write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        let request = try TranscriptionRequest(
            audio: audio, baseURL: Self.baseURL,
            model: "m", apiKey: "sk", boundary: "B"
        )
        defer { try? FileManager.default.removeItem(at: request.bodyFileURL) }

        let text = String(data: try Data(contentsOf: request.bodyFileURL), encoding: .utf8) ?? ""
        #expect(text.contains("Content-Type: audio/mp4"))
    }

    // MARK: - Prompt field (Phase F)

    @Test
    func prompt_omitted_whenNil() throws {
        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let request = try TranscriptionRequest(
            audio: audio, baseURL: Self.baseURL,
            model: "m", apiKey: "sk",
            prompt: nil,
            boundary: "BBOUND"
        )
        defer { try? FileManager.default.removeItem(at: request.bodyFileURL) }

        let text = String(data: try Data(contentsOf: request.bodyFileURL), encoding: .utf8) ?? ""
        #expect(!text.contains("name=\"prompt\""))
    }

    @Test
    func prompt_omitted_whenEmpty() throws {
        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let request = try TranscriptionRequest(
            audio: audio, baseURL: Self.baseURL,
            model: "m", apiKey: "sk",
            prompt: "",
            boundary: "BBOUND"
        )
        defer { try? FileManager.default.removeItem(at: request.bodyFileURL) }

        let text = String(data: try Data(contentsOf: request.bodyFileURL), encoding: .utf8) ?? ""
        #expect(!text.contains("name=\"prompt\""))
    }

    @Test
    func prompt_includedAsMultipartField_whenSet() throws {
        let audio = Self.makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        let prompt = "Organization: Acme\nStaff: Alice, Bob"
        let request = try TranscriptionRequest(
            audio: audio, baseURL: Self.baseURL,
            model: "m", apiKey: "sk",
            prompt: prompt,
            boundary: "BBOUND"
        )
        defer { try? FileManager.default.removeItem(at: request.bodyFileURL) }

        let text = String(data: try Data(contentsOf: request.bodyFileURL), encoding: .utf8) ?? ""
        #expect(text.contains("Content-Disposition: form-data; name=\"prompt\""))
        #expect(text.contains(prompt))
    }

    @Test
    func wavFile_getsAudioWavMimeType() throws {
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-mime-\(UUID().uuidString).wav")
        try "x".data(using: .utf8)!.write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        let request = try TranscriptionRequest(
            audio: audio, baseURL: Self.baseURL,
            model: "m", apiKey: "sk", boundary: "B"
        )
        defer { try? FileManager.default.removeItem(at: request.bodyFileURL) }

        let text = String(data: try Data(contentsOf: request.bodyFileURL), encoding: .utf8) ?? ""
        #expect(text.contains("Content-Type: audio/wav"))
    }
}
