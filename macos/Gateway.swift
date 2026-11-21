import Foundation

@MainActor
final class Gateway {
    private struct Session: Decodable {
        let port: Int
        let token: String
    }

    let store: LocalStore
    private var process: Process?
    private var input: Pipe?
    private var session: Session?
    var speechCredentials: URL { store.credentials }

    init(store: LocalStore = LocalStore()) {
        self.store = store
    }

    func ensureReady() async throws {
        if process?.isRunning == true, session != nil { return }
        shutdown()
        let credentials = store.settings
        guard credentials.isConfigured else {
            throw TrainerError("Открой «Настройки» и добавь ключи Gemini и ElevenLabs.")
        }
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "speech-gateway") else {
            throw TrainerError("В сборке отсутствует подключение к Gemini.")
        }
        let child = Process()
        let toChild = Pipe()
        let fromChild = Pipe()
        child.executableURL = executable
        child.standardInput = toChild
        child.standardOutput = fromChild
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        input = toChild
        do {
            let keys = ["gemini": credentials.gemini, "elevenlabs": credentials.elevenlabs]
            var data = try JSONEncoder().encode(keys)
            data.append(10)
            try toChild.fileHandleForWriting.write(contentsOf: data)
            let reader = fromChild.fileHandleForReading
            let handshake = try await Task.detached {
                var line = Data()
                while line.count < 512, let byte = try reader.read(upToCount: 1), !byte.isEmpty {
                    if byte[0] == 10 { return try JSONDecoder().decode(Session.self, from: line) }
                    line.append(byte)
                }
                throw TrainerError("Локальное подключение не запустилось.")
            }.value
            guard child.isRunning, (1...65535).contains(handshake.port), handshake.token.count == 64 else {
                throw TrainerError("Локальное подключение не запустилось.")
            }
            session = handshake
        } catch {
            shutdown()
            throw TrainerError("Локальное подключение к Gemini не запустилось.")
        }
    }

    func shutdown() {
        try? input?.fileHandleForWriting.close()
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        session = nil
    }

    private func post(_ path: String, body: Data) async throws -> Data {
        guard let session, let url = URL(string: "http://127.0.0.1:\(session.port)\(path)") else {
            throw TrainerError("Подключение к Gemini недоступно.")
        }
        var request = URLRequest(url: url, timeoutInterval: 35)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(session.token, forHTTPHeaderField: "X-Session-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 200 { return data }
        struct Failure: Decodable {
            struct Detail: Decodable { let message: String }
            let error: Detail
        }
        let problem = try? JSONDecoder().decode(Failure.self, from: data).error.message
        throw TrainerError(problem ?? "Gemini не обработал запрос.")
    }

    func isNewTopic(_ boundary: TurnBoundary) async -> Bool {
        struct Decision: Decodable { let separate: Bool }
        let request = ["spoken": String(boundary.spoken.suffix(2000)), "opening": String(boundary.opening.prefix(650))]
        guard let body = try? JSONEncoder().encode(request),
              let data = try? await post("/boundary", body: body),
              let decision = try? JSONDecoder().decode(Decision.self, from: data) else { return false }
        return decision.separate
    }

    func answer(input: String, mode: TrainerMode, language: ReplyLanguage, length: ReplyLength, translate: Bool) async throws -> [Segment] {
        guard let promptURL = Bundle.main.url(forResource: "CoachPrompt", withExtension: "txt") else {
            throw TrainerError("Профиль тренировки отсутствует.")
        }
        let defaultPrompt = try String(contentsOf: promptURL, encoding: .utf8)
        let extra = store.settings.profile
        let settings: [String: Any] = [
            "input": input, "prompt": defaultPrompt + "\n\n" + extra, "mode": mode.rawValue,
            "language": language.rawValue, "length": length.rawValue, "translate": translate && language != .ru,
        ]
        let data = try await post("/answer", body: JSONSerialization.data(withJSONObject: settings))
        let segments = try JSONDecoder().decode(CoachReply.self, from: data).segments.filter { !$0.text.isEmpty }
        guard !segments.isEmpty else { throw TrainerError("Gemini вернул пустой ответ.") }
        return segments.map { Segment(text: $0.text, ru: translate && language != .ru ? $0.ru : "") }
    }
}
