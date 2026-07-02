import Foundation

struct Script: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var title: String
    var body: String
    var createdAt = Date()
    var updatedAt = Date()

    /// Word count of the spoken text — markup stripped, speaker cues not
    /// counted (they're stage directions, not read aloud).
    var wordCount: Int {
        ScriptFormatter.parse(body).spokenWordCount
    }

    /// Rough on-camera read time at ~150 words per minute.
    var estimatedDuration: TimeInterval {
        Double(wordCount) / 150.0 * 60.0
    }

    var estimatedDurationText: String {
        let total = Int(estimatedDuration.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}
