import AppKit
import AVFoundation
import NaturalLanguage
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var gateway: Gateway?
    static weak var windowControls: WindowControls?

    func applicationWillTerminate(_ notification: Notification) {
        Self.windowControls?.uninstallShortcuts()
        Self.gateway?.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let controls = Self.windowControls else { return true }
        controls.showWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
struct TrainerView: View {
    @ObservedObject var model: TrainerModel
    @ObservedObject var windowControls: WindowControls
    @State private var settingsShown = false
    @State private var historyShown = false
    private let accent = Color(red: 0.15, green: 0.37, blue: 0.63)

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            threadBar
            threadContent
            Divider()
            composer
        }
        .frame(minWidth: 520, idealWidth: 720, minHeight: 555, idealHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .sheet(isPresented: $settingsShown) { SettingsView(gateway: model.gateway) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text("Тренировка UWC").font(.system(size: 22, weight: .semibold))
                Spacer()
                Toggle("Ghost", isOn: $windowControls.ghost).toggleStyle(.switch).controlSize(.small)
                    .help("Ограничить захват окна там, где это поддерживает macOS")
                Button { settingsShown = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Настройки")
                    .help("Настройки")
                    .disabled(model.busy || model.recording || model.isReplying)
            }

            control("Режим") {
                Picker("Режим", selection: $model.mode) {
                    ForEach(TrainerMode.allCases) { item in Text(item.label).tag(item) }
                }
                .labelsHidden()
            }
            control("Длина") {
                Picker("Длина ответа", selection: $model.length) {
                    ForEach(ReplyLength.allCases) { item in Text(item.label).tag(item) }
                }
                .labelsHidden()
                .disabled(model.mode == .practice)
            }
            control("Язык") {
                Picker("Язык ответа", selection: $model.language) {
                    ForEach(ReplyLanguage.allCases) { item in Text(item.label).tag(item) }
                }
                .labelsHidden()
            }
            control("Звук") {
                HStack(spacing: 14) {
                    Toggle("Микрофон", isOn: $model.mic).disabled(model.recording || model.busy)
                    Toggle("Звук Mac", isOn: $model.system).disabled(model.recording || model.busy)
                    Spacer(minLength: 2)
                    Toggle("Русский перевод", isOn: $model.translate)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private func control<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 9) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            content()
        }
        .pickerStyle(.segmented)
    }

    private var threadBar: some View {
        HStack(spacing: 10) {
            Button {
                historyShown.toggle()
            } label: {
                Label("История", systemImage: "clock")
            }
            .disabled(model.archived.isEmpty)
            .popover(isPresented: $historyShown, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.archived) { archived in
                            Button {
                                model.select(archived.id)
                                historyShown = false
                            } label: {
                                Text(archived.title)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 7)
                                    .padding(.horizontal, 9)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().opacity(0.55)
                        }
                    }
                    .padding(8)
                }
                .frame(width: 340, height: CGFloat(min(320, max(65, model.archived.count * 56))))
            }
            Spacer(minLength: 2)
            if model.canRewrite {
                Button("Обновить ответ") { model.rewriteAnswer() }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Ответ на тот же вопрос с выбранным языком и длиной")
            }
            if model.canClose {
                Button("Закрыть вопрос") { model.closeQuestion() }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("Свернуть вопрос в историю")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var threadContent: some View {
        ScrollViewReader { scroll in
            ScrollView {
                if let thread = model.activeThread {
                    LazyVStack(alignment: .leading, spacing: 21) {
                        ForEach(Array(thread.turns.enumerated()), id: \.element.id) { index, turn in
                            turnView(turn, initial: index == 0)
                                .id(turn.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                } else {
                    Text(model.isReplying ? "Готовлю вопрос и ответ…" : "Напиши вопрос или нажми «Слушать».")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 110)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.history.activeID) { _, _ in
                if let first = model.activeThread?.turns.first { scroll.scrollTo(first.id, anchor: .top) }
            }
            .onChange(of: model.revision) { _, _ in
                if let last = model.activeThread?.turns.last { scroll.scrollTo(last.id, anchor: .top) }
            }
        }
    }

    private func turnView(_ turn: QuestionTurn, initial: Bool) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            if !initial { Divider() }
            if let answer = turn.answer {
                VStack(alignment: .leading, spacing: 6) {
                    Text(turn.mode == .practice ? "Вопрос для репетиции" : initial ? "Вопрос" : "Уточнение")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    translatedLine(answer.question, weight: .semibold)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                if !answer.segments.isEmpty {
                    Text(turn.mode == .review ? "Разбор" : "Ответ")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(answer.segments.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1).").monospacedDigit().font(.callout)
                                .foregroundStyle(accent).frame(width: 22, alignment: .leading)
                                .accessibilityHidden(true)
                            translatedLine(line)
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func translatedLine(_ line: Segment, weight: Font.Weight = .regular) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(line.text).font(.system(size: 15, weight: weight)).lineSpacing(2)
            if model.translate && !line.ru.isEmpty {
                Text(line.ru).font(.system(size: 13).italic()).lineSpacing(2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.input)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 14))
                    .padding(5)
                    .accessibilityLabel(model.hasActive ? "Уточнение к открытому вопросу" : "Новый вопрос")
                if model.input.isEmpty {
                    Text(model.hasActive ? "Напиши уточнение к этому вопросу" : model.mode.placeholder)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 52)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))

            HStack(spacing: 12) {
                Button { model.toggleCapture() } label: {
                    Label(model.recording ? "Остановить" : "Слушать", systemImage: model.recording ? "stop.fill" : "mic")
                }
                .disabled(!model.canToggleCapture)
                .help(windowControls.listeningKey.map { "Прослушивание · \($0)" } ?? "Прослушивание")

                if model.hasActive {
                    Toggle("Уточнять голосом", isOn: $model.voiceFollowUp)
                        .toggleStyle(.checkbox)
                        .help("Добавлять продиктованные уточнения к открытому вопросу")
                }
                Spacer(minLength: 2)
                Button(model.mode == .practice && model.input.isEmpty ? "Новый вопрос" : "Отправить") {
                    model.send()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSend)
            }

            if !model.error.isEmpty || !model.status.isEmpty || model.isReplying {
                HStack(spacing: 7) {
                    if model.busy || model.isReplying { ProgressView().controlSize(.small) }
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(model.error.isEmpty ? Color.secondary : Color(nsColor: .systemRed))
                    if model.retryAvailable { Button("Повторить") { model.retry() } }
                }
            }
            if let warning = windowControls.shortcutStatus {
                Text(warning).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var statusText: String {
        if !model.error.isEmpty { return model.error }
        if model.pending > 1 { return "В очереди \(model.pending)" }
        if model.isReplying { return "Готовлю ответ…" }
        return model.status
    }
}

@MainActor
struct UWCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = TrainerModel()
    @StateObject private var windowControls = WindowControls()

    var body: some Scene {
        Window("SpeechTraining", id: "trainer") {
            TrainerView(model: model, windowControls: windowControls)
                .background(WindowAttachment(controls: windowControls).allowsHitTesting(false))
                .task {
                    AppDelegate.gateway = model.gateway
                    AppDelegate.windowControls = windowControls
                    windowControls.installShortcuts { [weak model] in model?.toggleCapture() }
                }
        }
        .defaultSize(width: 720, height: 680)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Показать или скрыть окно") { windowControls.toggleWindow() }
                if let shortcut = windowControls.windowKey {
                    Text("Окно · \(shortcut)")
                }
                if let shortcut = windowControls.listeningKey {
                    Text("Прослушивание · \(shortcut)")
                }
            }
        }
    }
}

@main
struct Launcher {
    @MainActor static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--render-preview" {
            do { try renderPreview(to: arguments[2]) } catch { print(error); exit(1) }
            return
        }
        if arguments.count >= 4, arguments[1] == "--test-live" {
            do { try await testLive(takes: Array(arguments.dropFirst(3)), directory: arguments[2]) }
            catch { print(error.localizedDescription); exit(1) }
            return
        }
        if arguments.count == 3, arguments[1] == "--test-threads" {
            do { try await testThreads(in: arguments[2]) }
            catch { print(error.localizedDescription); exit(1) }
            return
        }
        UWCApp.main()
    }

    @MainActor private static func testThreads(in directory: String) async throws {
        let store = LocalStore(root: URL(fileURLWithPath: directory))
        let model = TrainerModel(persistPreferences: false, store: store, restoreHistory: false)
        defer { model.gateway.shutdown() }
        model.startLiveChat()
        model.language = .uk
        try model.ingestSpeech(SpeechEvent(message_type: "committed_transcript", text:
            "The door is open, leave my coffee there. How would you decide where to spend a limited school budget? Отвечай на русском одну-две минуты, с примерами."))
        try model.ingestSpeech(SpeechEvent(message_type: "committed_transcript", text:
            "Проходите, ребята. Кто оставил кружку на столе? Отвечай на русском, спокойно."))
        try model.ingestSpeech(SpeechEvent(message_type: "committed_transcript", text:
            "Как можно помочь новому ученику освоиться в классе?"))
        await model.finishLiveTest()

        let threads = model.history.threads
        guard threads.count == 2, let first = threads.first, let firstReply = first.turns.first?.answer,
              first.title.localizedCaseInsensitiveContains("budget"),
              !first.title.localizedCaseInsensitiveContains("coffee"),
              !firstReply.question.ru.isEmpty,
              NLLanguageRecognizer.dominantLanguage(for: firstReply.segments.map(\.text).joined(separator: " ")) == .ukrainian,
              firstReply.segments.allSatisfy({ !$0.ru.isEmpty }),
              threads.last?.title.contains("Как можно помочь новому ученику") == true,
              model.activeThread?.id == threads.last?.id else {
            throw TrainerError("Voice filtering, language or isolation check failed. \(model.error)")
        }
        print("Two independent voice questions. Background and spoken language directions ignored.")

        model.closeQuestion()
        guard model.activeThread == nil, model.archived.count == 2 else { throw TrainerError("Cannot archive active question.") }
        model.select(first.id)
        model.language = .en
        model.input = "Can you give a simple example and say why this criterion is fair?"
        model.send()
        await model.finishLiveTest()
        guard let reply = model.activeThread?.turns.last?.answer, model.activeThread?.turns.count == 2,
              NLLanguageRecognizer.dominantLanguage(for: reply.segments.map(\.text).joined(separator: " ")) == .english,
              model.history.threads.count == 2, model.error.isEmpty else {
            throw TrainerError("Cannot append a follow-up to the reopened question. \(model.error)")
        }

        let followUpID = model.activeThread?.turns.last?.id
        model.language = .ru
        model.rewriteAnswer()
        await model.finishLiveTest()
        guard let turn = model.activeThread?.turns.last, turn.id == followUpID,
              turn.variants.count == 2, turn.answer?.choice.language == .ru,
              turn.answer?.segments.allSatisfy({ $0.ru.isEmpty }) == true else {
            throw TrainerError("The Russian variant did not replace the visible answer. \(model.error)")
        }
        model.language = .en
        model.rewriteAnswer()
        guard model.pending == 0, model.activeThread?.turns.last?.answer?.choice.language == .en else {
            throw TrainerError("The previous language variant was not restored from cache.")
        }
        model.input = "Unsent follow-up"
        model.closeQuestion()
        guard model.input.isEmpty, model.activeThread == nil else { throw TrainerError("Draft leaked to a new question.") }
        model.select(first.id)
        guard model.input == "Unsent follow-up", store.history.activeID == first.id,
              store.history.threads.count == 2 else { throw TrainerError("Thread restoration failed.") }
        print("Archived and reopened, added a contextual follow-up, switched language, restored cached variant and saved history.")
    }

    @MainActor private static func testLive(takes: [String], directory: String) async throws {
        let store = LocalStore(root: URL(fileURLWithPath: directory))
        let model = TrainerModel(persistPreferences: false, store: store, restoreHistory: false)
        let gateway = model.gateway
        defer { gateway.shutdown() }
        try await gateway.ensureReady()
        model.language = .en
        model.length = .short
        model.startLiveChat()
        let stream = try await LiveSpeech.connect(credentials: gateway.speechCredentials)
        defer { stream.close() }
        print("Model: \(stream.model)")
        let reader = Task {
            var partials = 0
            while !Task.isCancelled {
                let event: SpeechEvent
                do { event = try await stream.receive() }
                catch {
                    if stream.isClosed { break }
                    throw error
                }
                try model.ingestSpeech(event)
                if event.message_type == "partial_transcript", event.text?.isEmpty == false { partials += 1 }
                if event.message_type == "committed_transcript", let phrase = event.text, !phrase.isEmpty {
                    print("Committed: \(phrase)")
                }
            }
            return partials
        }
        defer { reader.cancel() }
        for path in takes {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let track = AudioTrack()
            let capacity = AVAudioFrameCount(file.processingFormat.sampleRate * 0.08)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                throw TrainerError("Invalid test waveform.")
            }
            let clock = ContinuousClock()
            var next = clock.now
            while file.framePosition < file.length {
                try file.read(into: buffer)
                track.add(buffer)
                let samples = track.take(1280)
                try await stream.send(samples.withUnsafeBytes { Data($0) })
                next = next.advanced(by: .milliseconds(80))
                try await clock.sleep(until: next)
            }
            for _ in 0..<28 {
                try await stream.send(Data(count: 2560))
                next = next.advanced(by: .milliseconds(80))
                try await clock.sleep(until: next)
            }
        }
        try await Task.sleep(for: .seconds(2))
        stream.close()
        let partials = try await reader.value
        await model.finishLiveTest()
        let count = model.history.threads.count
        let expected = Int(ProcessInfo.processInfo.environment["UWC_TEST_EXPECTED_TURNS"] ?? "") ?? takes.count
        guard partials > 0, count == expected, model.error.isEmpty else {
            throw TrainerError("Unexpected live result: \(partials) partials, \(count) threads. \(model.error)")
        }
        guard store.history.threads.count == expected else { throw TrainerError("History was not saved.") }
        print("Live: \(partials) interim events, \(count) separate question threads")
        if let path = ProcessInfo.processInfo.environment["UWC_TEST_PREVIEW"] {
            model.recording = true
            model.status = "Слушаю. Ответ появится автоматически."
            try render(model: model, to: path)
        }
    }

    @MainActor private static func renderPreview(to path: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalStore(root: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let choice = AnswerChoice(language: .en, length: .short)
        let question = Segment(text: "How should a team make a fair decision when time is limited?",
                               ru: "Как команде принять справедливое решение, если времени мало?")
        let segments = [
            Segment(text: "I would start by asking the group to agree on one clear criterion.",
                    ru: "Я бы сначала предложил группе выбрать один понятный критерий."),
            Segment(text: "For example, we could compare which idea helps the most students this week.",
                    ru: "Например, можно сравнить, какая идея поможет большему числу учеников на этой неделе."),
            Segment(text: "This gives everyone a fair way to explain their choice.",
                    ru: "Так у каждого будет возможность объяснить свой выбор."),
        ]
        let answer = AnswerVariant(choice: choice, question: question, segments: segments)
        let earlier = AnswerVariant(choice: choice, question: Segment(text: "How can we help a new student?", ru: ""), segments: [])
        let thread = QuestionThread(id: UUID(), turns: [QuestionTurn(mode: .answer, variants: [answer], displayed: choice)])
        let archived = QuestionThread(id: UUID(), turns: [QuestionTurn(mode: .answer, variants: [earlier], displayed: choice)])
        try store.saveHistory(ThreadHistory(threads: [archived, thread], activeID: thread.id))
        let model = TrainerModel(persistPreferences: false, store: store)
        model.language = .en
        try render(model: model, to: path)
    }

    @MainActor private static func render(model: TrainerModel, to path: String) throws {
        _ = NSApplication.shared
        let preferredWidth: CGFloat = ProcessInfo.processInfo.environment["UWC_PREVIEW_WIDTH"] == "small" ? 520 : 720
        let view = NSHostingView(rootView: TrainerView(model: model, windowControls: WindowControls())
            .frame(width: preferredWidth, height: 670).environment(\.colorScheme, .light))
        view.frame = CGRect(x: 0, y: 0, width: preferredWidth, height: 670)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw TrainerError("Preview failed.") }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { throw TrainerError("Preview failed.") }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
