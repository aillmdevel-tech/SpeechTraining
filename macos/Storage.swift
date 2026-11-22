import Foundation
import NaturalLanguage

struct ProviderSettings: Codable {
    var gemini = ""
    var elevenlabs = ""
    var profile = ""

    var isConfigured: Bool { !gemini.isEmpty && !elevenlabs.isEmpty }
}

struct LocalStore: Sendable {
    let root: URL

    init(root: URL? = nil) {
        let folder = Bundle.main.object(forInfoDictionaryKey: "SpeechTrainingDataFolder") as? String ?? "SpeechTraining"
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
    }

    var credentials: URL { root.appendingPathComponent("settings.json") }
    private var historyFile: URL { root.appendingPathComponent("threads.json") }

    var settings: ProviderSettings {
        guard let data = try? Data(contentsOf: credentials),
              let settings = try? JSONDecoder().decode(ProviderSettings.self, from: data) else { return ProviderSettings() }
        return settings
    }

    func saveSettings(_ value: ProviderSettings) throws {
        try write(value, to: credentials)
    }

    var history: ThreadHistory {
        if let data = try? Data(contentsOf: historyFile) {
            return (try? JSONDecoder().decode(ThreadHistory.self, from: data)) ?? ThreadHistory()
        }
        let legacy = root.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: legacy),
              let entries = try? JSONDecoder().decode([LegacyChatItem].self, from: data) else { return ThreadHistory() }
        let threads = entries.map { entry in
            let recognized = NLLanguageRecognizer.dominantLanguage(for: entry.segments.map(\.text).joined(separator: " "))
            let language = recognized.flatMap { ReplyLanguage(rawValue: $0.rawValue) } ?? .ru
            let choice = AnswerChoice(language: language, length: .short)
            let variant = AnswerVariant(choice: choice, question: Segment(text: entry.text, ru: ""), segments: entry.segments)
            let turn = QuestionTurn(mode: entry.mode, variants: [variant], displayed: choice)
            return QuestionThread(id: entry.id, turns: [turn])
        }
        return ThreadHistory(threads: threads)
    }

    func saveHistory(_ history: ThreadHistory) throws {
        try write(history, to: historyFile)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private struct LegacyChatItem: Decodable {
    let id: UUID
    let text: String
    let segments: [Segment]
    let mode: TrainerMode
}
