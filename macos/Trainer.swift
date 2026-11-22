import AppKit
import Foundation
import SwiftUI

enum ReplyLanguage: String, CaseIterable, Identifiable, Codable {
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

enum ReplyLength: String, CaseIterable, Identifiable, Codable {
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

@MainActor
final class TrainerModel: ObservableObject {
    private struct Request {
        let input: String
        let target: UUID?
        let navigation: UUID
        let mode: TrainerMode
        let choice: AnswerChoice
        let source: String
        var session: UUID? = nil
        var rewrite: QuestionTurn? = nil
    }

    private let persistPreferences: Bool
    @Published var language = ReplyLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .ru {
        didSet { if persistPreferences { UserDefaults.standard.set(language.rawValue, forKey: "language") } }
    }
    @Published var length = ReplyLength(rawValue: UserDefaults.standard.string(forKey: "length") ?? "") ?? .short {
        didSet { if persistPreferences { UserDefaults.standard.set(length.rawValue, forKey: "length") } }
    }
    @Published var mode: TrainerMode = .answer
    @Published var translate = true
    @Published var mic = true
    @Published var system = false
    @Published var voiceFollowUp = false
    @Published var input = ""
    @Published var recording = false
    @Published var busy = false
    @Published var status = ""
    @Published private(set) var error = ""
    @Published private(set) var history: ThreadHistory
    @Published private(set) var pending = 0
    @Published private(set) var revision = 0
    @Published private(set) var rewriting = Set<UUID>()
    @Published private(set) var retryAvailable = false
    let gateway: Gateway

    private let capture = VoiceCapture()
    private var speech: LiveSpeech?
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var replyTask: Task<Void, Never>?
    private var speechGeneration = UUID()
    private var navigation = UUID()
    private var drafts: [UUID?: String] = [:]
    private var failed: Request?
    private var incomplete: (text: String, session: UUID, target: UUID?, navigation: UUID, time: Date)?

    var activeThread: QuestionThread? { history.threads.first { $0.id == history.activeID } }
    var archived: [QuestionThread] { history.threads.reversed().filter { $0.id != history.activeID } }
    var hasActive: Bool { activeThread != nil }
    var canClose: Bool { history.activeID != nil }
    var isReplying: Bool { pending > 0 }
    var canToggleCapture: Bool { !busy && (recording || mic || system) }
    var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mode == .practice }
    var canRewrite: Bool {
        guard let turn = activeThread?.turns.last else { return false }
        return !rewriting.contains(turn.id) && turn.displayed != choice
    }
    private var choice: AnswerChoice { AnswerChoice(language: language, length: length) }

    init(persistPreferences: Bool = true, store: LocalStore = LocalStore(), restoreHistory: Bool = true) {
        self.persistPreferences = persistPreferences
        gateway = Gateway(store: store)
        history = restoreHistory ? store.history : ThreadHistory()
    }

    func closeQuestion() {
        select(nil)
    }

    func select(_ id: UUID?) {
        drafts[history.activeID] = input
        navigation = UUID()
        history.activeID = id
        input = drafts[id] ?? ""
        voiceFollowUp = false
        persistHistory()
    }

    func send() {
        guard canSend else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        if text.isEmpty && mode == .practice { select(nil) }
        if history.activeID == nil {
            history.activeID = UUID()
            navigation = UUID()
        }
        enqueue(Request(input: text.isEmpty ? "Задай новый вопрос для репетиции UWC." : text,
                        target: history.activeID, navigation: navigation, mode: mode, choice: choice, source: "typed"))
    }

    func rewriteAnswer() {
        guard canRewrite, let thread = activeThread, let turn = thread.turns.last, let answer = turn.answer else { return }
        if turn.variants.contains(where: { $0.choice == choice }) {
            updateVariant(in: thread.id, turn: turn.id, variant: nil, choice: choice)
            return
        }
        rewriting.insert(turn.id)
        enqueue(Request(input: answer.question.text, target: thread.id, navigation: navigation,
                        mode: turn.mode, choice: choice, source: "rewrite", rewrite: turn))
    }

    func retry() {
        guard let request = failed else { return }
        if let rewrite = request.rewrite { rewriting.insert(rewrite.id) }
        enqueue(request)
    }

    private func enqueue(_ request: Request) {
        failed = nil
        retryAvailable = false
        error = ""
        pending += 1
        replyTask = Task { [weak self, prior = replyTask] in
            await prior?.value
            guard let self else { return }
            defer {
                self.pending -= 1
                if let turn = request.rewrite { self.rewriting.remove(turn.id) }
            }
            do {
                try await self.deliver(request)
            } catch {
                self.error = error.localizedDescription
                self.failed = request
                self.retryAvailable = true
            }
        }
    }

    private func deliver(_ request: Request) async throws {
        try await gateway.ensureReady()
        let thread = history.threads.first { $0.id == request.target }
        var prior = thread?.turns ?? []
        if let rewrite = request.rewrite, let position = prior.firstIndex(where: { $0.id == rewrite.id }) {
            prior = Array(prior.prefix(position))
        }
        if prior.count > 5 { prior = Array(prior.prefix(1)) + Array(prior.suffix(4)) }
        let context = prior.compactMap { turn -> PriorReply? in
            guard let reply = turn.answer else { return nil }
            return PriorReply(question: reply.question.text,
                              answer: reply.segments.map(\.text).joined(separator: " "))
        }
        let previous = request.rewrite?.answer?.segments.map(\.text).joined(separator: " ") ?? ""
        var carry = ""
        if request.source == "voice", let incomplete, incomplete.session == request.session,
           incomplete.target == request.target, incomplete.navigation == request.navigation,
           Date().timeIntervalSince(incomplete.time) < 15 {
            carry = incomplete.text
        }
        let result = try await gateway.answer(input: request.input, mode: request.mode, choice: request.choice,
                                              source: request.source, history: context,
                                              previous: previous, continuation: carry)
        if request.source == "voice", let session = request.session {
            incomplete = result.incomplete
                ? (String([carry, request.input].joined(separator: " ").suffix(1200)),
                   session, request.target, request.navigation, Date())
                : nil
        }
        if let rewrite = request.rewrite, let target = request.target, let item = result.items.first {
            let question = request.mode == .practice ? item.question : rewrite.answer?.question ?? item.question
            let variant = AnswerVariant(choice: request.choice, question: question, segments: item.segments)
            updateVariant(in: target, turn: rewrite.id, variant: variant, choice: request.choice)
            return
        }
        for item in result.items {
            let active = request.target ?? UUID()
            let answer = AnswerVariant(choice: request.choice, question: item.question, segments: item.segments)
            let turn = QuestionTurn(mode: request.mode, variants: [answer], displayed: request.choice)
            if let index = history.threads.firstIndex(where: { $0.id == active }) {
                history.threads[index].turns.append(turn)
            } else {
                history.threads.append(QuestionThread(id: active, turns: [turn]))
            }
            if request.target == nil && request.navigation == navigation && input.isEmpty && !voiceFollowUp {
                history.activeID = active
            }
        }
        if !result.items.isEmpty {
            revision += 1
            persistHistory()
        }
    }

    private func updateVariant(in thread: UUID, turn: UUID, variant: AnswerVariant?, choice: AnswerChoice) {
        guard let index = history.threads.firstIndex(where: { $0.id == thread }),
              let position = history.threads[index].turns.firstIndex(where: { $0.id == turn }) else { return }
        if let variant { history.threads[index].turns[position].variants.append(variant) }
        history.threads[index].turns[position].displayed = choice
        revision += 1
        persistHistory()
    }

    private func persistHistory() {
        do { try gateway.store.saveHistory(history) }
        catch { self.error = "Не удалось сохранить локальную историю." }
    }

    func finishLiveTest() async {
        await replyTask?.value
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
    }

    private func stopListening(error: String = "") {
        speechGeneration = UUID()
        sender?.cancel()
        receiver?.cancel()
        speech?.close()
        speech = nil
        recording = false
        status = ""
        self.error = error
        busy = true
        Task {
            await capture.stop()
            busy = false
        }
    }

    func ingestSpeech(_ event: SpeechEvent) throws {
        switch event.message_type {
        case "partial_transcript":
            if event.text?.isEmpty == false && recording { status = "Слышу речь…" }
        case "committed_transcript":
            if recording { status = "Слушаю…" }
            guard let text = event.text, text.contains(where: \.isLetter) else { return }
            let isExercise = mode == .practice && activeThread?.turns.first?.mode == .practice
            let target = voiceFollowUp || isExercise ? history.activeID : nil
            enqueue(Request(input: text, target: target, navigation: navigation,
                            mode: mode == .practice ? .review : mode, choice: choice,
                            source: "voice", session: speechGeneration))
        case "session_started", "warning", "committed_transcript_with_timestamps":
            return
        default:
            throw LiveSpeech.problem(event.message_type)
        }
    }
}
