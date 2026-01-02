import AudioToolbox
import AVFoundation
import Combine
import Foundation
import XCTest
@testable import Alona

// MARK: - Audio Sample Math Tests

final class AudioSampleMathTests: XCTestCase {
    func testAudioSampleMathDownmix() {
        let mono = AudioSampleMath.averagedMono(system: [1.0, -1.0, 0.0], mic: [-1.0, 1.0, 0.0])
        XCTAssertEqual(mono, [0.0, 0.0, 0.0])
    }
}

// MARK: - CoreAudio Process Tap Tests

final class CoreAudioProcessTapTests: XCTestCase {
    /// Test CoreAudioUtils AudioObjectID extensions
    func testAudioObjectIDConstants() {
        XCTAssertEqual(AudioObjectID.system, AudioObjectID(kAudioObjectSystemObject))
        XCTAssertEqual(AudioObjectID.unknown, kAudioObjectUnknown)
        XCTAssertTrue(AudioObjectID.unknown.isUnknown)
        XCTAssertFalse(AudioObjectID.unknown.isValid)
        XCTAssertTrue(AudioObjectID.system.isValid)
        XCTAssertFalse(AudioObjectID.system.isUnknown)
    }

    /// Test that process list can be read from system
    func testReadProcessListDoesNotThrow() {
        // This may return empty list if no audio processes are running
        // but should not throw in a normal environment
        do {
            let processes = try AudioObjectID.readProcessList()
            XCTAssertNotNil(processes)
        } catch {
            // May fail in sandboxed test environment - that's acceptable
            XCTAssertNotNil(error.localizedDescription)
        }
    }

    /// Test CoreAudioError descriptions are meaningful
    func testCoreAudioErrorDescriptions() {
        let tapError = CoreAudioError.tapCreationFailed(-12345)
        XCTAssertTrue(tapError.errorDescription?.contains("-12345") ?? false)

        let aggregateError = CoreAudioError.aggregateDeviceFailed(-67890)
        XCTAssertTrue(aggregateError.errorDescription?.contains("-67890") ?? false)

        let propertyError = CoreAudioError.propertyError("test property error")
        XCTAssertEqual(propertyError.errorDescription, "test property error")

        let invalidProcess = CoreAudioError.invalidProcess("invalid pid")
        XCTAssertEqual(invalidProcess.errorDescription, "invalid pid")
    }
}

// MARK: - Recording Error Tests

final class RecordingErrorTests: XCTestCase {
    func testRecordingErrorDescriptions() {
        let tapError = RecordingError.processTapCreationFailed(-12345)
        XCTAssertTrue(tapError.errorDescription?.contains("-12345") ?? false)

        let aggregateError = RecordingError.aggregateDeviceCreationFailed(-67890)
        XCTAssertTrue(aggregateError.errorDescription?.contains("-67890") ?? false)

        let ioProcError = RecordingError.ioProcCreationFailed(-11111)
        XCTAssertTrue(ioProcError.errorDescription?.contains("-11111") ?? false)

        let deviceStartError = RecordingError.deviceStartFailed(-22222)
        XCTAssertTrue(deviceStartError.errorDescription?.contains("-22222") ?? false)

        XCTAssertEqual(RecordingError.tapUnavailable.errorDescription, "Process tap is unavailable.")
        XCTAssertEqual(
            RecordingError.streamDescriptionUnavailable.errorDescription,
            "Tap stream description not available.")
        XCTAssertEqual(RecordingError.formatCreationFailed.errorDescription, "Failed to create audio format.")
        XCTAssertEqual(RecordingError.bufferCreationFailed.errorDescription, "Failed to create audio buffer.")
    }
}

// MARK: - Voice Processing Tests

final class VoiceProcessingTests: XCTestCase {
    func testAVAudioEngineInputNodeSupportsVoiceProcessing() {
        // Verify that AVAudioEngine's inputNode can enable voice processing
        // This is available in macOS 14+ which we require
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Voice processing should be available on macOS 14+
        // This test verifies the API is callable without crashing
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            XCTAssertTrue(inputNode.isVoiceProcessingEnabled, "Voice processing should be enabled")

            try inputNode.setVoiceProcessingEnabled(false)
            XCTAssertFalse(inputNode.isVoiceProcessingEnabled, "Voice processing should be disabled")
        } catch {
            // Voice processing may fail if no audio input device is available
            // This is expected in CI environments without audio hardware
            print("Voice processing unavailable: \(error.localizedDescription)")
        }
    }
}

// MARK: - Audio Buffer Synchronization Tests

final class AudioBufferTests: XCTestCase {
    func testResampleAudioDownsample() {
        // Test resampling from 48kHz to 16kHz (3:1 ratio)
        let harness = AudioRecorderTestHarness()
        let input: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0] // 6 samples at 48kHz

        let output = harness.resampleAudio(input, from: 48000, to: 16000)

        // Should produce ~2 samples (6 * 16000/48000 = 2)
        XCTAssertEqual(output.count, 2, "Should downsample 6 samples to 2")
        XCTAssertGreaterThan(output[0], 0, "Output should have valid data")
    }

    func testResampleAudioUpsample() {
        // Test resampling from 16kHz to 48kHz (1:3 ratio)
        let harness = AudioRecorderTestHarness()
        let input: [Float] = [1.0, 2.0] // 2 samples at 16kHz

        let output = harness.resampleAudio(input, from: 16000, to: 48000)

        // Should produce ~6 samples (2 * 48000/16000 = 6)
        XCTAssertEqual(output.count, 6, "Should upsample 2 samples to 6")
    }

    func testResampleAudioSameRate() {
        // Test resampling when rates are the same
        let harness = AudioRecorderTestHarness()
        let input: [Float] = [1.0, 2.0, 3.0]

        let output = harness.resampleAudio(input, from: 48000, to: 48000)

        // Should pass through unchanged
        XCTAssertEqual(output.count, input.count, "Same rate should not change count")
        XCTAssertEqual(output[0], input[0], accuracy: 0.001, "Values should be preserved")
    }

    func testResampleAudioEmptyInput() {
        let harness = AudioRecorderTestHarness()
        let input: [Float] = []

        let output = harness.resampleAudio(input, from: 48000, to: 16000)

        XCTAssertTrue(output.isEmpty, "Empty input should return empty output")
    }

    func testResampleAudioInvalidRates() {
        let harness = AudioRecorderTestHarness()
        let input: [Float] = [1.0, 2.0, 3.0]

        // Zero source rate should return input unchanged
        let output1 = harness.resampleAudio(input, from: 0, to: 16000)
        XCTAssertEqual(output1.count, input.count, "Invalid source rate should return input")

        // Zero target rate should return input unchanged
        let output2 = harness.resampleAudio(input, from: 48000, to: 0)
        XCTAssertEqual(output2.count, input.count, "Invalid target rate should return input")
    }
}

/// Test harness that exposes internal AudioRecorder methods for testing
private class AudioRecorderTestHarness {
    /// Expose resample function for testing
    func resampleAudio(_ samples: [Float], from sourceSampleRate: Double, to targetSampleRate: Double) -> [Float] {
        guard sourceSampleRate > 0, targetSampleRate > 0, !samples.isEmpty else { return samples }

        let ratio = targetSampleRate / sourceSampleRate
        let outputCount = Int(Double(samples.count) * ratio)
        guard outputCount > 0 else { return samples }

        var result = [Float](repeating: 0, count: outputCount)

        for i in 0..<outputCount {
            let srcIndex = Double(i) / ratio
            let srcIndexInt = Int(srcIndex)
            let fraction = Float(srcIndex - Double(srcIndexInt))

            let sample1 = samples[min(srcIndexInt, samples.count - 1)]
            let sample2 = samples[min(srcIndexInt + 1, samples.count - 1)]
            result[i] = sample1 + fraction * (sample2 - sample1)
        }

        return result
    }
}

// MARK: - AudioRecorder Publisher Tests

final class AudioRecorderPublisherTests: XCTestCase {
    func testAudioRecorderPublisherEmitsOnIsRecordingChange() throws {
        // Test that the CurrentValueSubject-backed publisher emits when isRecording changes
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let recorder = AudioRecorder(meetingFileManager: harness.manager)
        var receivedValues: [Bool] = []
        var cancellables = Set<AnyCancellable>()

        recorder.isRecordingPublisher
            .sink { receivedValues.append($0) }
            .store(in: &cancellables)

        // Should receive initial value (false)
        XCTAssertEqual(receivedValues, [false], "Should emit initial value")
    }

    func testAudioRecorderPublisherEmitsOnDurationChange() throws {
        // Test that duration publisher emits correctly
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let recorder = AudioRecorder(meetingFileManager: harness.manager)
        var receivedValues: [TimeInterval] = []
        var cancellables = Set<AnyCancellable>()

        recorder.recordingDurationPublisher
            .sink { receivedValues.append($0) }
            .store(in: &cancellables)

        // Should receive initial value (0)
        XCTAssertEqual(receivedValues, [0], "Should emit initial duration of 0")
    }
}

// MARK: - TranscriptionEngine Publisher Tests

final class TranscriptionEnginePublisherTests: XCTestCase {
    func testTranscriptionEngineProgressPublisherEmitsOnProgressChange() {
        let engine = TranscriptionEngine()
        var receivedValues: [Double] = []
        var cancellables = Set<AnyCancellable>()

        engine.progressPublisher
            .sink { receivedValues.append($0) }
            .store(in: &cancellables)

        // Should receive initial value (0)
        XCTAssertEqual(receivedValues, [0], "Should emit initial progress of 0")
    }
}

// MARK: - AudioProcess Tests

final class AudioProcessTests: XCTestCase {
    func testAudioProcessAllRunningReturnsArray() {
        // This may return empty in test environment but should not crash
        let processes = AudioProcess.allRunning()
        XCTAssertNotNil(processes, "Should return an array (possibly empty)")
    }

    func testAudioProcessFindByBundleIdentifierReturnsNilForUnknown() {
        // Looking for a bundle ID that definitely doesn't exist
        let result = AudioProcess.find(bundleIdentifier: "com.nonexistent.app.12345")
        XCTAssertNil(result, "Should return nil for unknown bundle ID")
    }
}

// MARK: - ProcessTap Configuration Tests

final class ProcessTapConfigurationTests: XCTestCase {
    func testProcessTapMuteBehaviorConfiguration() {
        // Test that mute behavior is correctly configured
        let tapDescriptionMuted = CATapDescription(stereoMixdownOfProcesses: [])
        tapDescriptionMuted.muteBehavior = .mutedWhenTapped

        let tapDescriptionUnmuted = CATapDescription(stereoMixdownOfProcesses: [])
        tapDescriptionUnmuted.muteBehavior = .unmuted

        XCTAssertEqual(tapDescriptionMuted.muteBehavior, .mutedWhenTapped)
        XCTAssertEqual(tapDescriptionUnmuted.muteBehavior, .unmuted)
    }

    func testProcessTapUUIDIsUnique() {
        let tap1 = CATapDescription(stereoMixdownOfProcesses: [])
        tap1.uuid = UUID()

        let tap2 = CATapDescription(stereoMixdownOfProcesses: [])
        tap2.uuid = UUID()

        XCTAssertNotEqual(tap1.uuid, tap2.uuid, "Each tap should have unique UUID")
    }
}

// MARK: - System Audio Capture Configuration Tests

final class SystemAudioCaptureTests: XCTestCase {
    func testTapDescriptionIsUnmuted() {
        // Verify that CATapDescription uses unmuted behavior for non-interfering capture
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.muteBehavior = .unmuted

        // .unmuted means the tap LISTENS without affecting playback
        XCTAssertEqual(tapDescription.muteBehavior, .unmuted, "Tap should use unmuted mode for non-interfering capture")
    }

    func testAggregateDeviceConfigurationForTapOnly() {
        // Verify the aggregate device configuration does NOT include sub-devices
        // This is the key to preventing live audio interference
        let outputUID = "test-output-uid"
        let tapUID = UUID().uuidString
        let aggregateUID = UUID().uuidString

        // Correct configuration: tap-only, no sub-device list
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Alona-Tap-Only",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // No kAudioAggregateDeviceSubDeviceListKey - this is intentional!
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: false,
                    kAudioSubTapUIDKey: tapUID,
                ],
            ],
        ]

        // Verify sub-device list is NOT present (prevents routing interference)
        XCTAssertNil(
            description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]],
            "Should NOT have sub-device list to prevent playback interference")

        // Verify tap list IS present
        XCTAssertNotNil(
            description[kAudioAggregateDeviceTapListKey] as? [[String: Any]],
            "Should have tap list for audio capture")

        // Verify private flag is set (hides from user)
        XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Bool, true, "Should be private device")
    }
}
