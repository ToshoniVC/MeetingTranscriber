import Foundation
import Accelerate
@preconcurrency import AVFoundation

/// Cuts leading and trailing silence off a recording part before upload.
///
/// **Why.** Whisper decodes 30-second windows; a window with no speech
/// yields a hallucination — the prompt echoed back, or YouTube boilerplate.
/// Jot's recorder regularly runs before the meeting starts and after it
/// ends (two minutes early and fifteen late on one tape, an unattended
/// 25-minute tail on another), so the head and tail of a part are the
/// densest source of junk. Removing them means there is nothing to
/// hallucinate over, and it shrinks the upload.
///
/// **Scope.** Head and tail only, never internal pauses: a single constant
/// offset per part is trivially invertible, and the Backlog's clock
/// invariant requires every public timestamp to stay on the *original
/// recording clock*. The pipeline adds `headSeconds` back to every segment
/// and restores `originalDuration` before merging, so downstream timing
/// (Notion `[HH:MM:SS]`, multi-part offsets, future screenshot alignment)
/// is unaffected.
///
/// **Conservative by design.** Nothing is ever skipped: when no speech run
/// is found at all, or less than `minimumTrim` would be removed, the
/// original file uploads untouched. Only when a trim actually happens is
/// the part re-encoded — to 16 kHz mono AAC, which is what the endpoints
/// downsample to anyway, so quality is unchanged and the upload is three to
/// four times smaller.
struct SilenceTrimmer: Sendable {

    struct Settings: Sendable, Equatable {
        /// Analysis window.
        var frameDuration: Double = 0.1
        /// Absolute floor/ceiling for the adaptive speech threshold (dBFS RMS).
        var minimumThresholdDBFS: Float = -55
        var maximumThresholdDBFS: Float = -35
        /// The threshold sits this far above the recording's noise floor
        /// (its 20th-percentile frame level), clamped to the bounds above.
        var thresholdAboveNoiseFloorDB: Float = 15
        /// Frames above threshold must persist this long to count as speech
        /// (filters clicks and single-frame blips).
        var minimumSpeechRun: Double = 0.3
        /// Audio kept on either side of the detected speech.
        var padding: Double = 1.0
        /// Trim only when at least this much would be removed in total.
        var minimumTrim: Double = 5.0
        /// Output encoding.
        var outputSampleRate: Double = 16_000
        var outputBitRate: Int = 48_000

        static let `default` = Settings()
    }

    /// A trimmed copy plus what the pipeline needs to put timestamps back on
    /// the recording clock. The caller removes `directory` when done.
    struct Trimmed: Sendable, Equatable {
        let url: URL
        let directory: URL
        /// Seconds removed from the head. Add to every segment timestamp.
        let headSeconds: Double
        /// Seconds removed from the tail. Informational.
        let tailSeconds: Double
        /// The untrimmed part's duration; restored as the result's duration.
        let originalDuration: Double
    }

    enum TrimError: Error, Equatable {
        case unreadable(String)
        case encodingFailed(String)
    }

    /// Where the speech sits in a part, in seconds on the original clock.
    struct Plan: Equatable, Sendable {
        let start: Double
        let end: Double
        let totalDuration: Double

        var headSeconds: Double { start }
        var tailSeconds: Double { totalDuration - end }
    }

    // MARK: - Entry point

    /// Analyse `url` and, when its head/tail silence is worth removing,
    /// write a trimmed 16 kHz mono AAC copy and describe the cut. Returns
    /// `nil` when the file should upload unchanged.
    ///
    /// The decode + encode is CPU work of a second or two per part, so it
    /// runs on a detached utility task rather than on the caller's actor —
    /// the pipeline keeps routing watcher events while a part is analysed.
    /// (A detached task does not inherit cancellation; at worst a trim
    /// finishes for a pipeline that has already stopped, and its temp
    /// directory is removed by the caller's `defer`.)
    func trimIfNeeded(_ url: URL, settings: Settings = .default) async throws -> Trimmed? {
        try await Task.detached(priority: .utility) {
            try Self.trimSynchronously(url, settings: settings)
        }.value
    }

    /// The whole trim on the calling thread. Split out so the async wrapper
    /// stays trivially small and the work is testable without an executor.
    static func trimSynchronously(_ url: URL, settings: Settings = .default) throws -> Trimmed? {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw TrimError.unreadable(error.localizedDescription)
        }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else {
            throw TrimError.unreadable("empty or indeterminate audio")
        }
        let totalDuration = Double(file.length) / sampleRate

        let levels = try frameLevels(file, settings: settings)
        guard let plan = plan(frameLevelsDBFS: levels, totalDuration: totalDuration, settings: settings) else {
            return nil
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-trim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent(
            url.deletingPathExtension().lastPathComponent + ".m4a"
        )
        do {
            try export(file, range: plan, to: outputURL, settings: settings)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw TrimError.encodingFailed(error.localizedDescription)
        }
        return Trimmed(
            url: outputURL,
            directory: directory,
            headSeconds: plan.headSeconds,
            tailSeconds: plan.tailSeconds,
            originalDuration: totalDuration
        )
    }

    // MARK: - Pure planning (unit-tested without audio)

    /// Adaptive threshold: noise floor (20th percentile) + margin, clamped.
    static func speechThreshold(frameLevelsDBFS: [Float], settings: Settings = .default) -> Float {
        guard !frameLevelsDBFS.isEmpty else { return settings.maximumThresholdDBFS }
        let sorted = frameLevelsDBFS.sorted()
        let floor = sorted[min(sorted.count - 1, sorted.count / 5)]
        return min(settings.maximumThresholdDBFS,
                   max(settings.minimumThresholdDBFS, floor + settings.thresholdAboveNoiseFloorDB))
    }

    /// First and last frame index of a qualifying speech run, or `nil` when
    /// no run of `minimumSpeechRun` consecutive frames clears the threshold.
    static func speechBounds(
        frameLevelsDBFS: [Float],
        settings: Settings = .default
    ) -> (first: Int, last: Int)? {
        let threshold = speechThreshold(frameLevelsDBFS: frameLevelsDBFS, settings: settings)
        let run = max(1, Int((settings.minimumSpeechRun / settings.frameDuration).rounded(.up)))
        let loud = frameLevelsDBFS.map { $0 >= threshold }
        guard loud.count >= run else { return nil }

        var first: Int?
        var last: Int?
        var streak = 0
        for (index, isLoud) in loud.enumerated() {
            streak = isLoud ? streak + 1 : 0
            if streak >= run {
                if first == nil { first = index - run + 1 }
                last = index
            }
        }
        guard let first, let last else { return nil }
        return (first, last)
    }

    /// Where to cut, or `nil` when the part should upload unchanged (no
    /// speech found, or less than `minimumTrim` removable).
    static func plan(
        frameLevelsDBFS: [Float],
        totalDuration: Double,
        settings: Settings = .default
    ) -> Plan? {
        guard let bounds = speechBounds(frameLevelsDBFS: frameLevelsDBFS, settings: settings) else {
            return nil
        }
        let start = max(0, Double(bounds.first) * settings.frameDuration - settings.padding)
        let end = min(totalDuration, Double(bounds.last + 1) * settings.frameDuration + settings.padding)
        guard end > start else { return nil }
        let removed = start + (totalDuration - end)
        guard removed >= settings.minimumTrim else { return nil }
        return Plan(start: start, end: end, totalDuration: totalDuration)
    }

    // MARK: - Audio I/O

    /// RMS level in dBFS per analysis frame, mixed across channels.
    static func frameLevels(_ file: AVAudioFile, settings: Settings) throws -> [Float] {
        let format = file.processingFormat
        let framesPerWindow = AVAudioFrameCount(max(1, format.sampleRate * settings.frameDuration))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerWindow) else {
            throw TrimError.unreadable("could not allocate analysis buffer")
        }
        var levels: [Float] = []
        levels.reserveCapacity(Int(file.length / AVAudioFramePosition(framesPerWindow)) + 1)
        file.framePosition = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: framesPerWindow)
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }
            levels.append(rmsDBFS(buffer, frames: frames))
        }
        return levels
    }

    private static func rmsDBFS(_ buffer: AVAudioPCMBuffer, frames: Int) -> Float {
        let channels = Int(buffer.format.channelCount)
        var sumSquares: Float = 0
        if let floatData = buffer.floatChannelData {
            for channel in 0..<channels {
                var meanSquare: Float = 0
                vDSP_measqv(floatData[channel], 1, &meanSquare, vDSP_Length(frames))
                sumSquares += meanSquare
            }
        } else if let int16Data = buffer.int16ChannelData {
            for channel in 0..<channels {
                var acc: Float = 0
                for i in 0..<frames {
                    let sample = Float(int16Data[channel][i]) / Float(Int16.max)
                    acc += sample * sample
                }
                sumSquares += acc / Float(frames)
            }
        } else {
            return -160
        }
        let rms = (sumSquares / Float(max(1, channels))).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }

    /// Write `range` of `file` to `outputURL` as 16 kHz mono AAC, converting
    /// from the source format with `AVAudioConverter`.
    private static func export(
        _ file: AVAudioFile,
        range: Plan,
        to outputURL: URL,
        settings: Settings
    ) throws {
        let source = file.processingFormat
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: settings.outputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TrimError.encodingFailed("could not describe the 16 kHz mono target format")
        }
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw TrimError.encodingFailed("no converter from \(source) to 16 kHz mono")
        }
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: settings.outputSampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: settings.outputBitRate,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let startFrame = AVAudioFramePosition(range.start * source.sampleRate)
        let endFrame = min(file.length, AVAudioFramePosition(range.end * source.sampleRate))
        file.framePosition = startFrame

        let inputCapacity = AVAudioFrameCount(source.sampleRate) // one second
        let outputCapacity = AVAudioFrameCount(target.sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else {
            throw TrimError.encodingFailed("could not allocate output buffer")
        }

        var readError: Error?
        let inputBlock: AVAudioConverterInputBlock = { requested, status in
            guard file.framePosition < endFrame else {
                status.pointee = .endOfStream
                return nil
            }
            let remaining = AVAudioFrameCount(endFrame - file.framePosition)
            let toRead = min(remaining, min(requested, inputCapacity))
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: toRead) else {
                status.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: inputBuffer, frameCount: toRead)
            } catch {
                readError = error
                status.pointee = .endOfStream
                return nil
            }
            guard inputBuffer.frameLength > 0 else {
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return inputBuffer
        }

        conversion: while true {
            var error: NSError?
            outputBuffer.frameLength = 0
            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            if let readError { throw readError }
            if outputBuffer.frameLength > 0 {
                try output.write(from: outputBuffer)
            }
            switch status {
            case .haveData:
                continue
            case .endOfStream, .inputRanDry:
                break conversion
            case .error:
                throw TrimError.encodingFailed(error?.localizedDescription ?? "conversion failed")
            @unknown default:
                break conversion
            }
        }
    }
}
