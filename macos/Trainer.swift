import AppKit
import Foundation
import SwiftUI

enum ReplyLanguage: String, CaseIterable, Identifiable {
    case ru, uk, en
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ru: return "Русский"
        case .uk: return "Українська"
        case .en: return "English"
        }
    }
}

enum ReplyLength: String, CaseIterable, Identifiable {
    case short, medium, long
    var id: String { rawValue }
    var label: String {
        switch self {
        case .short: return "Кратко"
        case .medium: return "Средне"
        case .long: return "Подробно"
        }
    }
}

enum TrainerMode: String, CaseIterable, Identifiable, Codable {
    case answer, review, practice
    var id: String { rawValue }
    var label: String {
        switch self {
        case .answer: return "Ответ"
        case .review: return "Разбор"
        case .practice: return "Тренировка"
        }
    }
    var placeholder: String {
        switch self {
        case .answer: return "Вставь вопрос или запиши его"
        case .review: return "Напиши вопрос и свой ответ или запиши его"
        case .practice: return "Укажи тему или нажми «Новый вопрос»"
        }
    }
}

struct Segment: Codable {
    let text: String
    let ru: String
}

struct CoachReply: Decodable {
    let segments: [Segment]
}

@MainActor
final class TrainerModel: ObservableObject {
    private var persistPreferences = true
    @Published var language: ReplyLanguage = ReplyLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .ru {
        didSet { if persistPreferences { UserDefaults.standard.set(language.rawValue, forKey: "language") } }
    }
    @Published var length: ReplyLength = ReplyLength(rawValue: UserDefaults.standard.string(forKey: "length") ?? "") ?? .short {
        didSet { if persistPreferences { UserDefaults.standard.set(length.rawValue, forKey: "length") } }
    }
    @Published var mode: TrainerMode = .answer
    @Published var translate = true
    @Published var mic = true
    @Published var system = false
    @Published var input = ""
    @Published var segments: [Segment] = []
    @Published private(set) var responseMode: TrainerMode?
    @Published var recording = false
    @Published var busy = false
    @Published private(set) var liveChat: [LiveChatItem] = []
    @Published private(set) var liveDraft = ""
    @Published private(set) var livePending = 0
    @Published private(set) var finishingTurns = 0
    @Published var status = ""
    @Published var error = ""
    private let capture = VoiceCapture()
    let gateway: Gateway
    private var speech: LiveSpeech?
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var boundaryCheck: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?
    private var replyTask: Task<Void, Never>?
    private var turns = LiveTurns()
    private var conversation = UUID()
    private var speechGeneration = UUID()
    private var lastQuestion = ""
    var isReplying: Bool { livePending > 0 || finishingTurns > 0 }
    var canToggleCapture: Bool { !busy && (recording || (!isReplying && (mic || system))) }
    var canSend: Bool { !busy && !recording && !isReplying && (mode == .practice || !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }

    init(persistPreferences: Bool = true, store: LocalStore = LocalStore(), restoreHistory: Bool = true) {
        self.persistPreferences = persistPreferences
        gateway = Gateway(store: store)
        if restoreHistory { liveChat = store.history }
    }

    func toggleCapture() {
        guard canToggleCapture else { return }
        if recording {
            stopListening()
            return
        }
        busy = true
        error = ""
        status = "Подключаю звук…"
        Task {
            defer { busy = false }
            do {
                startLiveChat()
                let session = speechGeneration
                try await capture.start(microphone: mic, system: system) { [weak self] _ in
                    Task { @MainActor in
                        guard self?.speechGeneration == session else { return }
                        self?.stopListening(error: "Захват звука Mac прервался. Включи прослушивание ещё раз.")
                    }
                }
                try await gateway.ensureReady()
                let stream = try await LiveSpeech.connect(credentials: gateway.speechCredentials)
                guard speechGeneration == session else {
                    stream.close()
                    return
                }
                speech = stream
                recording = true
                status = "Слушаю. Ответ появится автоматически."
                runSpeech(stream, session: session)
            } catch {
                speech?.close()
                speech = nil
                await capture.stop()
                status = ""
                self.error = error.localizedDescription
            }
        }
    }

    private func runSpeech(_ stream: LiveSpeech, session: UUID) {
        sender = Task { [weak self] in
            let clock = ContinuousClock()
            var next = clock.now
            do {
                while !Task.isCancelled {
                    next = max(next.advanced(by: .milliseconds(80)), clock.now)
                    try await clock.sleep(until: next)
                    guard let self, self.speechGeneration == session else { return }
                    try await stream.send(self.capture.chunk(frames: 1280))
                }
            } catch {
                guard !Task.isCancelled, self?.speechGeneration == session else { return }
                self?.stopListening(error: LiveSpeech.problem("").reason)
            }
        }
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let event = try await stream.receive()
                    guard let self, self.speechGeneration == session else { return }
                    try self.ingestSpeech(event)
                }
            } catch {
                guard !Task.isCancelled, self?.speechGeneration == session else { return }
                let message = (error as? TrainerError)?.reason ?? LiveSpeech.problem("").reason
                self?.stopListening(error: message)
            }
        }
    }

    func startLiveChat() {
        speechGeneration = UUID()
        turns = LiveTurns()
        liveDraft = ""
    }

    private func stopListening(error: String = "") {
        speechGeneration = UUID()
        sender?.cancel()
        receiver?.cancel()
        boundaryCheck?.cancel()
        boundaryCheck = nil
        speech?.close()
        speech = nil
        recording = false
        status = ""
        self.error = error
        if !liveDraft.isEmpty {
            input = [input, liveDraft].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        liveDraft = ""
        turns = LiveTurns()
        busy = true
        Task {
            await capture.stop()
            busy = false
        }
    }

    func ingestSpeech(_ event: SpeechEvent) throws {
        switch event.message_type {
        case "partial_transcript":
            guard let text = event.text, !text.isEmpty else { return }
            turns.update(text)
            liveDraft = turns.draft
            checkBoundary()
        case "committed_transcript":
            guard let text = event.text, !text.isEmpty else { return }
            let interruptedCheck = boundaryCheck != nil
            boundaryCheck?.cancel()
            boundaryCheck = nil
            turns.update(text)
            let unresolved = turns.candidate.flatMap { candidate in
                interruptedCheck || turns.alreadyChecked != candidate ? candidate : nil
            }
            let finished = turns.finish(text)
            liveDraft = ""
            commitSpeech(finished, at: unresolved)
        case "session_started", "warning", "committed_transcript_with_timestamps":
            return
        default: throw LiveSpeech.problem(event.message_type)
        }
    }

    private func checkBoundary() {
        guard boundaryCheck == nil, let candidate = turns.candidate,
              candidate.spoken != turns.alreadyChecked?.spoken else { return }
        turns.checked(candidate)
        let session = speechGeneration
        boundaryCheck = Task { [weak self] in
            guard let self else { return }
            let separate = await self.gateway.isNewTopic(candidate)
            guard !Task.isCancelled, self.speechGeneration == session else { return }
            self.boundaryCheck = nil
            if separate, let finished = self.turns.split(at: candidate) {
                self.commitSpeech(finished)
                self.liveDraft = self.turns.draft
            }
        }
    }

    private func commitSpeech(_ text: String, at boundary: TurnBoundary? = nil) {
        guard !text.isEmpty else { return }
        if boundary == nil && finishingTurns == 0 {
            queueSpeech(text)
            return
        }
        finishingTurns += 1
        commitTask = Task { [weak self, prior = commitTask] in
            await prior?.value
            guard let self else { return }
            defer { self.finishingTurns -= 1 }
            if let boundary, await self.gateway.isNewTopic(boundary) {
                self.queueSpeech(boundary.spoken)
                self.queueSpeech(boundary.opening)
            } else {
                self.queueSpeech(text)
            }
        }
    }

    private func queueSpeech(_ text: String) {
        guard text.contains(where: \.isLetter) else { return }
        let mode: TrainerMode = self.mode == .practice ? .review : self.mode
        let language = self.language
        let length = self.length
        let translate = self.translate
        let item = LiveChatItem(text: text, mode: mode)
        liveChat.append(item)
        persistHistory()
        livePending += 1
        replyTask = Task { [weak self, prior = replyTask] in
            await prior?.value
            guard let self else { return }
            defer { self.livePending -= 1 }
            do {
                let prompt = mode == .review && !self.lastQuestion.isEmpty
                    ? "Последний тренировочный вопрос: \(self.lastQuestion)\n\nТекст кандидата: \(text)" : text
                let segments = try await self.gateway.answer(input: prompt, mode: mode, language: language, length: length, translate: translate)
                self.showReply(segments, on: item.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func showReply(_ segments: [Segment], on item: UUID) {
        if let index = liveChat.firstIndex(where: { $0.id == item }) {
            liveChat[index].segments = segments
            persistHistory()
        }
    }

    private func persistHistory() {
        do { try gateway.store.saveHistory(liveChat) }
        catch { self.error = "Не удалось сохранить локальную историю." }
    }

    func finishLiveTest() async {
        await commitTask?.value
        await replyTask?.value
    }

    func send() {
        guard canSend else { return }
        error = ""
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = typed.isEmpty ? "Следующий тренировочный вопрос" : typed
        let request: String
        if mode == .review && !lastQuestion.isEmpty {
            request = "Последний тренировочный вопрос: \(lastQuestion)\n\nТекст кандидата: \(visible)"
        } else if mode == .practice && !lastQuestion.isEmpty {
            request = visible + "\nПредыдущий вопрос, который не нужно повторять: \(lastQuestion)"
        } else {
            request = visible
        }
        busy = true
        status = "Готовлю ответ…"
        let selection = (mode, language, length, translate)
        let item = LiveChatItem(text: visible, mode: selection.0)
        liveChat.append(item)
        persistHistory()
        Task {
            defer { busy = false }
            do {
                try await gateway.ensureReady()
                let answer = try await gateway.answer(input: request, mode: selection.0, language: selection.1, length: selection.2, translate: selection.3)
                segments = answer
                showReply(answer, on: item.id)
                responseMode = selection.0
                if selection.0 == .practice { lastQuestion = answer.map(\.text).joined(separator: " ") }
                status = "Ответ готов"
            } catch {
                status = ""
                self.error = error.localizedDescription
            }
        }
    }
}
