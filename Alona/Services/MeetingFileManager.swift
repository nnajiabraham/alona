import Foundation

enum MeetingFileManager {
    static var defaultBaseDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alona", isDirectory: true)
    }
}
