import Foundation

struct TranscriptionResult {
    let text: String
    let segments: [TranscriptionSegment]

    init(text: String, segments: [TranscriptionSegment]) {
        self.text = text
        self.segments = segments
    }
}

struct TranscriptionSegment {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String

    init(startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}
