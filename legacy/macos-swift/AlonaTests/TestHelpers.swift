import Combine
import Foundation
import XCTest
@testable import AlonaCore

// MARK: - Test Harness

struct MeetingFileManagerTestHarness {
    let manager: MeetingFileManager
    let baseDirectory: URL
    let userDefaults: UserDefaults
    private let defaultsSuiteName: String

    init() throws {
        self.baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingFileManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.baseDirectory, withIntermediateDirectories: true)

        self.defaultsSuiteName = "MeetingFileManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: self.defaultsSuiteName) else {
            throw NSError(domain: "MeetingFileManagerTests", code: -1)
        }
        defaults.removePersistentDomain(forName: self.defaultsSuiteName)

        self.userDefaults = defaults
        self.manager = MeetingFileManager(fileManager: .default, userDefaults: defaults)
        self.manager.baseDirectory = self.baseDirectory
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.baseDirectory)
        self.userDefaults.removePersistentDomain(forName: self.defaultsSuiteName)
    }
}

// MARK: - Helpers

@MainActor
func waitForJobCompletion(in appState: AppState, timeout: TimeInterval = 2.0) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if case .completed = appState.transcriptionJobs.first?.state {
            return
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Timed out waiting for transcription job completion")
}

// MARK: - Mocks

final class MockAudioRecorder: AudioRecordingController, @unchecked Sendable {
    private let directory: URL
    private let isRecordingSubject = CurrentValueSubject<Bool, Never>(false)
    private let durationSubject = CurrentValueSubject<TimeInterval, Never>(0)
    var captureSystemAudio: Bool = false

    init(directory: URL) {
        self.directory = directory
    }

    var isRecordingPublisher: AnyPublisher<Bool, Never> {
        self.isRecordingSubject.eraseToAnyPublisher()
    }

    var recordingDurationPublisher: AnyPublisher<TimeInterval, Never> {
        self.durationSubject.eraseToAnyPublisher()
    }

    func startRecording(meetingTitle _: String) async throws -> URL {
        self.isRecordingSubject.send(true)
        return self.directory
    }

    func stopRecording() async {
        self.isRecordingSubject.send(false)
    }
}

@MainActor
final class MockMeetingNotificationScheduler: MeetingNotificationScheduling {
    var requests: [String] = []

    var notificationCount: Int {
        self.requests.count
    }

    func scheduleMeetingNotification(appName _: String, meetingTitle _: String, identifier: String) {
        self.requests.append(identifier)
    }
}

final class MockTranscriptionEngine: TranscriptionProcessing, @unchecked Sendable {
    private let subject = PassthroughSubject<Double, Never>()
    private let result: TranscriptionResult

    init(result: TranscriptionResult = TranscriptionResult(text: "", segments: [])) {
        self.result = result
    }

    var progressPublisher: AnyPublisher<Double, Never> {
        self.subject.eraseToAnyPublisher()
    }

    func transcribe(audioURL _: URL) async throws -> TranscriptionResult {
        self.subject.send(0.5)
        self.subject.send(1.0)
        self.subject.send(completion: .finished)
        return self.result
    }

    func unloadModelIfIdle() {
        // No-op for mock
    }
}

struct MockSummaryProvider: SummaryProviding {
    let output: String

    init(output: String = "SUMMARY") {
        self.output = output
    }

    func generateSummary(transcript _: String, notes _: String) async throws -> String {
        self.output
    }
}
