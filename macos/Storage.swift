import Foundation

struct ProviderSettings: Codable {
    var gemini = ""
    var elevenlabs = ""
    var profile = ""

    var isConfigured: Bool { !gemini.isEmpty && !elevenlabs.isEmpty }
}

struct LocalStore: Sendable {
    let root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SpeechTraining", isDirectory: true)) {
        self.root = root
    }

    var credentials: URL { root.appendingPathComponent("settings.json") }
    private var historyFile: URL { root.appendingPathComponent("history.json") }

    var settings: ProviderSettings {
        guard let data = try? Data(contentsOf: credentials),
              let settings = try? JSONDecoder().decode(ProviderSettings.self, from: data) else { return ProviderSettings() }
        return settings
    }

    func saveSettings(_ value: ProviderSettings) throws {
        try write(value, to: credentials)
    }

    var history: [LiveChatItem] {
        guard let data = try? Data(contentsOf: historyFile) else { return [] }
        return (try? JSONDecoder().decode([LiveChatItem].self, from: data)) ?? []
    }

    func saveHistory(_ turns: [LiveChatItem]) throws {
        try write(Array(turns.suffix(200)), to: historyFile)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
