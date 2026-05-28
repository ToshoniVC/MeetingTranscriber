import Testing
import Foundation
@testable import Jot

/// Phase G tests: `FileOrganizer.organize(...)` writes (or skips)
/// `context.md` alongside the transcript depending on whether a non-empty
/// `context` is provided.
struct FileOrganizerContextTests {

    private static func makeFolders() throws -> (watch: URL, output: URL) {
        let watch = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-org-ctx-watch-\(UUID().uuidString)")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-org-ctx-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return (watch, output)
    }

    private static func putAudio(in folder: URL, name: String = "demo.mp3") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: 64).write(to: url)
        return url
    }

    /// Tiny verbose_json stand-in — FileOrganizer only needs it to parse.
    private static func fakeTranscriptJSON() -> Data {
        let payload: [String: Any] = [
            "text": "T", "duration": 1.0,
            "segments": [["id": 0, "start": 0.0, "end": 1.0, "text": "T"]]
        ]
        return try! JSONSerialization.data(withJSONObject: payload, options: [])
    }

    @Test
    func organize_withContext_writesContextMD() async throws {
        let (watch, output) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let audio = try Self.putAudio(in: watch)

        let folder = try await FileOrganizer().organize(
            audio: audio,
            transcriptText: "T",
            transcriptJSON: Self.fakeTranscriptJSON(),
            context: "Organization: Acme\nStaff: Alice",
            outputRoot: output
        )

        let contextURL = folder.appendingPathComponent("context.md")
        #expect(FileManager.default.fileExists(atPath: contextURL.path(percentEncoded: false)))

        let body = try String(contentsOf: contextURL, encoding: .utf8)
        #expect(body.contains("# Transcription context"))
        #expect(body.contains("Organization: Acme"))
        #expect(body.contains("Staff: Alice"))
    }

    @Test
    func organize_withNilContext_omitsContextMD() async throws {
        let (watch, output) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let audio = try Self.putAudio(in: watch)

        let folder = try await FileOrganizer().organize(
            audio: audio,
            transcriptText: "T",
            transcriptJSON: Self.fakeTranscriptJSON(),
            context: nil,
            outputRoot: output
        )

        let contextURL = folder.appendingPathComponent("context.md")
        #expect(!FileManager.default.fileExists(atPath: contextURL.path(percentEncoded: false)))
    }

    @Test
    func organize_withEmptyContext_omitsContextMD() async throws {
        let (watch, output) = try Self.makeFolders()
        defer {
            try? FileManager.default.removeItem(at: watch)
            try? FileManager.default.removeItem(at: output)
        }
        let audio = try Self.putAudio(in: watch)

        let folder = try await FileOrganizer().organize(
            audio: audio,
            transcriptText: "T",
            transcriptJSON: Self.fakeTranscriptJSON(),
            context: "",
            outputRoot: output
        )

        let contextURL = folder.appendingPathComponent("context.md")
        #expect(!FileManager.default.fileExists(atPath: contextURL.path(percentEncoded: false)))
    }
}
