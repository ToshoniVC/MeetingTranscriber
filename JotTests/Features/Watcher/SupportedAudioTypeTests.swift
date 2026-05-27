import Testing
import Foundation
@testable import Jot

/// Unit tests for the candidate-file filter. These also document the formats
/// the Watcher will and won't pick up.
struct SupportedAudioTypeTests {

    @Test
    func mp3_isCandidate() {
        let url = URL(fileURLWithPath: "/tmp/meeting.mp3")
        #expect(SupportedAudioType.isCandidate(url))
    }

    @Test
    func m4a_isCandidate() {
        let url = URL(fileURLWithPath: "/tmp/meeting.m4a")
        #expect(SupportedAudioType.isCandidate(url))
    }

    @Test
    func wav_isCandidate() {
        let url = URL(fileURLWithPath: "/tmp/meeting.wav")
        #expect(SupportedAudioType.isCandidate(url))
    }

    @Test
    func uppercaseExtension_isCandidate() {
        let url = URL(fileURLWithPath: "/tmp/meeting.MP3")
        #expect(SupportedAudioType.isCandidate(url))
    }

    @Test
    func unsupportedExtension_isNotCandidate() {
        let url = URL(fileURLWithPath: "/tmp/meeting.aiff")
        #expect(!SupportedAudioType.isCandidate(url))
    }

    @Test
    func extensionMissing_isNotCandidate() {
        let url = URL(fileURLWithPath: "/tmp/meeting")
        #expect(!SupportedAudioType.isCandidate(url))
    }

    @Test
    func hiddenFile_isNotCandidate() {
        let url = URL(fileURLWithPath: "/tmp/.meeting.mp3")
        #expect(!SupportedAudioType.isCandidate(url))
    }

    @Test
    func dotDS_Store_isNotCandidate() {
        let url = URL(fileURLWithPath: "/tmp/.DS_Store")
        #expect(!SupportedAudioType.isCandidate(url))
    }

    @Test
    func tempPartialExtension_isNotCandidate() {
        let url = URL(fileURLWithPath: "/tmp/meeting.mp3.tmp")
        // Last extension is "tmp", not in the set → false.
        #expect(!SupportedAudioType.isCandidate(url))
    }
}
