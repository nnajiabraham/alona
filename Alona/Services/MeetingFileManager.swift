import Foundation

struct TranscriptSegmentRecord: Codable {
    let start: Double
    let end: Double
    let text: String
}

struct MeetingEntry: Identifiable, Equatable, Hashable {
    let directory: URL
    var title: String
    let createdAt: Date

    var id: URL { directory }

    static func == (lhs: MeetingEntry, rhs: MeetingEntry) -> Bool {
        lhs.directory == rhs.directory
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(directory)
    }
}

final class MeetingFileManager {
    private enum Constants {
        static let saveDirectoryKey = "meetingSaveDirectory"
        static let titleFileName = "title.txt"
    }

    static var defaultBaseDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alona", isDirectory: true)
    }

    private let fileManager: FileManager
    private let userDefaults: UserDefaults

    init(fileManager: FileManager = .default, userDefaults: UserDefaults = .standard) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
    }

    var baseDirectory: URL {
        get {
            if let path = userDefaults.string(forKey: Constants.saveDirectoryKey), !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            return Self.defaultBaseDirectory
        }
        set {
            userDefaults.set(newValue.path, forKey: Constants.saveDirectoryKey)
        }
    }

    func createMeetingDirectory(title: String, date: Date = Date()) throws -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmm"

        let slug = sanitizedSlug(from: title)
        let folderName = "\(dateFormatter.string(from: date))_\(timeFormatter.string(from: date))_\(slug)"

        var meetingDir = baseDirectory.appendingPathComponent(folderName, isDirectory: true)
        var suffix = 1
        while fileManager.fileExists(atPath: meetingDir.path) {
            meetingDir = baseDirectory.appendingPathComponent("\(folderName)-\(suffix)", isDirectory: true)
            suffix += 1
        }

        try fileManager.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        try saveTitle(title, to: meetingDir)
        return meetingDir
    }

    func saveNotes(_ notes: String, to directory: URL) throws {
        let notesURL = directory.appendingPathComponent("notes.md")
        try notes.write(to: notesURL, atomically: true, encoding: .utf8)
        try? fileManager.removeItem(at: directory.appendingPathComponent("notes.tmp"))
    }

    func saveTranscript(_ result: TranscriptionResult, to directory: URL) throws {
        let textURL = directory.appendingPathComponent("transcript.txt")
        try result.text.write(to: textURL, atomically: true, encoding: .utf8)

        let jsonURL = directory.appendingPathComponent("transcript.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let records = result.segments.map { segment in
            TranscriptSegmentRecord(start: segment.startTime, end: segment.endTime, text: segment.text)
        }

        let data = try encoder.encode(records)
        try data.write(to: jsonURL, options: .atomic)
    }

    func saveSummary(_ summary: String, to directory: URL) throws {
        let summaryURL = directory.appendingPathComponent("summary.md")
        try summary.write(to: summaryURL, atomically: true, encoding: .utf8)
    }

    func saveNotesDraft(_ notes: String, to directory: URL) throws {
        let tempURL = directory.appendingPathComponent("notes.tmp")
        try notes.write(to: tempURL, atomically: true, encoding: .utf8)
    }

    func recoverNotesFromTemp(in directory: URL) -> String? {
        let tempURL = directory.appendingPathComponent("notes.tmp")
        return try? String(contentsOf: tempURL, encoding: .utf8)
    }

    func loadNotes(from directory: URL) -> String? {
        let notesURL = directory.appendingPathComponent("notes.md")
        return try? String(contentsOf: notesURL, encoding: .utf8)
    }

    func loadTranscript(from directory: URL) -> String? {
        let transcriptURL = directory.appendingPathComponent("transcript.txt")
        return try? String(contentsOf: transcriptURL, encoding: .utf8)
    }

    func meetingEntries() -> [MeetingEntry] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let directories = contents.compactMap { url -> MeetingEntry? in
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey])
            let createdAt = resourceValues?.creationDate ?? Date.distantPast
            let title = loadTitle(from: url) ?? url.lastPathComponent
            return MeetingEntry(directory: url, title: title, createdAt: createdAt)
        }

        return directories.sorted { $0.createdAt > $1.createdAt }
    }

    func loadTitle(from directory: URL) -> String? {
        let titleURL = directory.appendingPathComponent(Constants.titleFileName)
        return try? String(contentsOf: titleURL, encoding: .utf8)
    }

    func saveTitle(_ title: String, to directory: URL) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? "Untitled meeting" : trimmed
        let titleURL = directory.appendingPathComponent(Constants.titleFileName)
        try final.write(to: titleURL, atomically: true, encoding: .utf8)
    }

    func recordingAudioURL(in directory: URL) -> URL? {
        let preferred = directory.appendingPathComponent("recording.wav")
        if fileManager.fileExists(atPath: preferred.path) {
            return preferred
        }
        let fallback = directory.appendingPathComponent("recording-mono.wav")
        if fileManager.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    private func sanitizedSlug(from rawTitle: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "Meeting" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))

        let transformed = source.unicodeScalars.map { scalar -> Character in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return "-"
            }
            if allowed.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }

        var slug = String(transformed)
        slug = slug.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty {
            slug = "Meeting"
        }
        if slug.count > 50 {
            slug = String(slug.prefix(50))
        }
        return slug
    }
}
