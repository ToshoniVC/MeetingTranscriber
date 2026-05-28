import Testing
import Foundation
import AVFoundation
@testable import Jot

/// Integration tests for `MediaConversionService`. We can't ship a
/// fixture `.mp4` in the test bundle without dragging in an Xcode
/// Resources phase, so each test synthesizes a tiny MP4 in tmpdir
/// using `AVAssetWriter` (silent audio + a 1×1 video stream). The
/// service then has a real asset to chew on.
struct MediaConversionServiceTests {

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cleanUp(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// Synthesize a tiny MP4 with one PCM audio track (silence) and one
    /// trivial video frame. Uses CMSampleBuffer / AVAssetWriter directly
    /// so AVAssetExportSession sees a real audio track on read.
    private static func writeFixtureMP4(at url: URL, durationSeconds: Double = 0.2) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let sampleRate: Double = 44_100
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: 64_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 16,
            AVVideoHeightKey: 16
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16
            ]
        )
        writer.add(videoInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Append one PCM silence buffer covering the whole clip. The
        // writer's AAC encoder transcodes our PCM into the configured
        // output format.
        let frames = Int(sampleRate * durationSeconds)
        try appendSilencePCMBuffer(to: audioInput, sampleRate: sampleRate, frames: frames)
        audioInput.markAsFinished()

        // Single 16×16 black frame so the video track exists.
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        if let pb = pixelBuffer {
            pixelAdaptor.append(pb, withPresentationTime: .zero)
        }
        videoInput.markAsFinished()

        await writer.finishWriting()
        if writer.status == .failed {
            throw writer.error ?? NSError(domain: "TestFixture", code: -1)
        }
    }

    /// Build a CMSampleBuffer of `frames` zero-valued 16-bit mono PCM
    /// samples at `sampleRate` Hz and feed it to `input`.
    private static func appendSilencePCMBuffer(
        to input: AVAssetWriterInput,
        sampleRate: Double,
        frames: Int
    ) throws {
        let bytesPerFrame = 2
        let blockSize = frames * bytesPerFrame
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: blockSize)
        buffer.initialize(repeating: 0, count: blockSize)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw NSError(domain: "TestFixture", code: Int(formatStatus))
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: buffer,
            blockLength: blockSize,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: blockSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let blockBuffer else {
            buffer.deallocate()
            throw NSError(domain: "TestFixture", code: Int(blockStatus))
        }

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frames),
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            buffer.deallocate()
            throw NSError(domain: "TestFixture", code: Int(sampleStatus))
        }

        // Wait until the input is ready to accept the buffer. With
        // expectsMediaDataInRealTime=false the writer transcodes
        // synchronously and is ready immediately, but we spin briefly
        // just in case.
        var spinCount = 0
        while !input.isReadyForMoreMediaData && spinCount < 100 {
            Thread.sleep(forTimeInterval: 0.005)
            spinCount += 1
        }
        input.append(sampleBuffer)
        buffer.deallocate()
    }

    // MARK: - Tests

    @Test
    func extractAudio_writesM4AOutput() async throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanUp(dir) }
        let input = dir.appendingPathComponent("fixture.mp4")
        try await Self.writeFixtureMP4(at: input)

        let output = dir.appendingPathComponent("out.m4a")
        let service = MediaConversionService()

        try await service.extractAudio(from: input, to: output)

        #expect(FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path(percentEncoded: false))[.size] as? Int) ?? 0
        #expect(size > 0, "Extracted audio file should be non-empty.")

        let outAsset = AVURLAsset(url: output)
        let outTracks = try await outAsset.loadTracks(withMediaType: .audio)
        #expect(!outTracks.isEmpty)
    }

    @Test
    func extractAudio_missingInput_throwsConversionFailed() async throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanUp(dir) }
        let ghost = dir.appendingPathComponent("nope.mp4")
        let output = dir.appendingPathComponent("out.m4a")
        let service = MediaConversionService()

        await #expect(throws: ManualUploadError.self) {
            try await service.extractAudio(from: ghost, to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)),
                "Failed conversion must not leave a partial output behind.")
    }
}
