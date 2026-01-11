import Foundation

struct TranscriptionResult {
    let text: String
    let segments: [TranscriptionSegment]
}

struct TranscriptionSegment {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}
