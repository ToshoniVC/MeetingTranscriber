import Testing
import Foundation
import AVFoundation
@testable import Jot

/// Integration tests for `SilenceTrimmer` against real audio files written
/// with AVFoundation: a WAV with silent head/tail is trimmed to a 16 kHz mono
/// AAC copy and the reported offsets put the result back on the recording
/// clock; files without worthwhile silence upload untouched.
struct SilenceTrimmerIntegrationTests {

    /// Write a 16 kHz mono PCM WAV: `head` s of digital silence, `tone` s of
    /// a -12 dBFS sine, `tail` s of silence.
    private static func makeWAV(head: Double, tone: Double, tail: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-trim-\(UUID().uuidString).wav")
        let sampleRate = 16_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let total = head + tone + tail
        let frames = AVAudioFrameCount(total * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        let toneStart = Int(head * sampleRate)
        let toneEnd = Int((head + tone) * sampleRate)
        let amplitude: Float = 0.25 // ≈ -12 dBFS peak
        for i in 0..<Int(frames) {
            if i >= toneStart && i < toneEnd {
                samples[i] = amplitude * sin(Float(i) * 2 * .pi * 440 / Float(sampleRate))
            } else {
                samples[i] = 0
            }
        }
        try file.write(from: buffer)
        return url
    }

    private static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    @Test
    func trimIfNeeded_cutsSilentHeadAndTail_andReportsOffsets() async throws {
        let wav = try Self.makeWAV(head: 8, tone: 3, tail: 8)
        defer { try? FileManager.default.removeItem(at: wav) }

        let trimmed = try await SilenceTrimmer().trimIfNeeded(wav)
        let result = try #require(trimmed, "8 s of silence either side must be trimmed")
        defer { try? FileManager.default.removeItem(at: result.directory) }

        #expect(abs(result.headSeconds - 7.0) < 0.3, "head cut ≈ 8 s − 1 s pad, got \(result.headSeconds)")
        #expect(abs(result.tailSeconds - 7.0) < 0.3, "tail cut ≈ 8 s − 1 s pad, got \(result.tailSeconds)")
        #expect(abs(result.originalDuration - 19.0) < 0.05)
        #expect(result.url.pathExtension == "m4a")
        #expect(FileManager.default.fileExists(atPath: result.url.path(percentEncoded: false)))

        // The trimmed copy holds the tone plus padding (~5 s). AAC adds a
        // little priming, so allow slack.
        let trimmedDuration = try Self.duration(of: result.url)
        #expect(trimmedDuration > 4.5 && trimmedDuration < 6.0, "trimmed duration \(trimmedDuration)")

        // Output is 16 kHz mono as the endpoints expect.
        let file = try AVAudioFile(forReading: result.url)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.sampleRate == 16_000)
    }

    @Test
    func trimIfNeeded_returnsNilWhenLittleSilence() async throws {
        let wav = try Self.makeWAV(head: 1, tone: 3, tail: 1)
        defer { try? FileManager.default.removeItem(at: wav) }
        let trimmed = try await SilenceTrimmer().trimIfNeeded(wav)
        #expect(trimmed == nil, "1 s either side is under the 5 s minimum trim")
    }

    @Test
    func trimIfNeeded_returnsNilWhenNoSpeechAtAll() async throws {
        // Conservative by design: an all-silent part uploads untouched rather
        // than being skipped on the strength of a threshold.
        let wav = try Self.makeWAV(head: 10, tone: 0, tail: 10)
        defer { try? FileManager.default.removeItem(at: wav) }
        let trimmed = try await SilenceTrimmer().trimIfNeeded(wav)
        #expect(trimmed == nil)
    }

    @Test
    func trimIfNeeded_throwsUnreadableForGarbage() async throws {
        let junk = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-trim-junk-\(UUID().uuidString).mp3")
        try Data(repeating: 0xCD, count: 2_048).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        do {
            _ = try await SilenceTrimmer().trimIfNeeded(junk)
            Issue.record("Expected an unreadable error")
        } catch let error as SilenceTrimmer.TrimError {
            if case .unreadable = error { /* ok */ } else { Issue.record("Expected .unreadable, got \(error)") }
        }
    }

    @Test
    func restoringRecordingClock_shiftsSegmentsAndRestoresDuration() {
        let trimmedResult = TranscriptionResult(
            text: "hello",
            duration: 5,
            segments: [.init(start: 1.0, end: 2.0, text: " hello", avgLogprob: -0.2, noSpeechProb: 0.1, compressionRatio: 1.1)],
            rawJSON: Data("{}".utf8),
            providerName: "Groq",
            language: "dutch",
            droppedSegmentCount: 3
        )
        let restored = trimmedResult.restoringRecordingClock(headOffset: 7, originalDuration: 19)
        #expect(restored.segments.map(\.start) == [8.0])
        #expect(restored.segments.map(\.end) == [9.0])
        #expect(restored.segments.first?.avgLogprob == -0.2)
        #expect(restored.duration == 19)
        #expect(restored.text == "hello")
        #expect(restored.providerName == "Groq")
        #expect(restored.language == "dutch")
        #expect(restored.droppedSegmentCount == 3)
        let json = try? JSONSerialization.jsonObject(with: restored.rawJSON) as? [String: Any]
        #expect(json?["trimmed_head_seconds"] as? Double == 7)
        #expect(json?["duration"] as? Double == 19)
        let segs = json?["segments"] as? [[String: Any]]
        #expect(segs?.first?["start"] as? Double == 8.0)
        #expect(segs?.first?["no_speech_prob"] as? Double == 0.1)
    }
}
