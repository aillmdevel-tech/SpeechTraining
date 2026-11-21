import Foundation

struct SpeechEvent: Decodable {
    let message_type: String
    let text: String?
}

@MainActor
final class LiveSpeech {
    private struct Credentials: Decodable { let elevenlabs: String }
    private struct Chunk: Encodable {
        let message_type = "input_audio_chunk"
        let audio_base_64: String
        let sample_rate = 16_000
        let commit: Bool
    }

    private let socket: URLSessionWebSocketTask
    private let session: URLSession
    let model: String
    private(set) var isClosed = false
    private init(model: String, key: String) {
        self.model = model
        var url = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        let query = [
            "model_id": model, "audio_format": "pcm_16000",
            "commit_strategy": model == "scribe_v3_live" ? "turn_prediction" : "vad",
            "vad_silence_threshold_secs": "1.35", "keepalive_interval_ms": "2000",
            "enable_logging": "false",
        ]
        url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if model == "scribe_v3_live" { url.queryItems?.append(URLQueryItem(name: "multilang_mode", value: "true")) }
        var request = URLRequest(url: url.url!, timeoutInterval: 9)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 512 * 1024
    }

    static func connect(credentials: URL) async throws -> LiveSpeech {
        guard let data = try? Data(contentsOf: credentials),
              let key = try? JSONDecoder().decode(Credentials.self, from: data).elevenlabs,
              !key.isEmpty else { throw TrainerError("Не найдено подключение к ElevenLabs.") }
        for model in ["scribe_v3_live", "scribe_v2_realtime"] {
            let stream = LiveSpeech(model: model, key: key)
            stream.socket.resume()
            do {
                let first = try await stream.receive()
                if first.message_type == "session_started" { return stream }
                stream.close()
                if first.message_type == "invalid_request" && model == "scribe_v3_live" { continue }
                throw problem(first.message_type)
            } catch {
                stream.close()
                if model == "scribe_v3_live", !(error is TrainerError), !Task.isCancelled { continue }
                if error is TrainerError { throw error }
                throw TrainerError("Не удалось подключить живое распознавание ElevenLabs.")
            }
        }
        throw TrainerError("ElevenLabs не запустил живое распознавание.")
    }

    func send(_ pcm: Data, commit: Bool = false) async throws {
        let chunk = Chunk(audio_base_64: pcm.base64EncodedString(), commit: commit)
        let json = try JSONEncoder().encode(chunk)
        try await socket.send(.string(String(decoding: json, as: UTF8.self)))
    }

    func receive() async throws -> SpeechEvent {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: throw TrainerError("ElevenLabs прислал неизвестный тип данных.")
        }
        return try JSONDecoder().decode(SpeechEvent.self, from: data)
    }

    static func problem(_ event: String) -> TrainerError {
        switch event {
        case "auth_error": return TrainerError("ElevenLabs отклонил ключ распознавания.")
        case "quota_exceeded", "rate_limited", "throttled":
            return TrainerError("Достигнут лимит живого распознавания ElevenLabs.")
        case "unaccepted_terms":
            return TrainerError("Подтверди условия распознавания в кабинете ElevenLabs.")
        default: return TrainerError("Живое распознавание прервалось. Нажми «Слушать» ещё раз.")
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
