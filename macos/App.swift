import AppKit
import AVFoundation
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
    private let accent = Color(red: 0.15, green: 0.37, blue: 0.63)

    var body: some View {
        VSplitView {
            composer.frame(minHeight: model.recording ? 214 : 312, idealHeight: model.recording ? 230 : 345,
                           maxHeight: model.recording ? 275 : 390)
            response
                .frame(minHeight: 170, maxHeight: .infinity)
        }
        .frame(minWidth: 520, idealWidth: 720, minHeight: 530, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .sheet(isPresented: $settingsShown) { SettingsView(gateway: model.gateway) }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("SpeechTraining")
                    .font(.system(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Настройки") { settingsShown = true }
                    .disabled(model.busy || model.recording || model.isReplying)
                Toggle("Ghost", isOn: $windowControls.ghost)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Ограничить захват окна там, где это поддерживает macOS")
            }

            VStack(spacing: 8) {
                control("Режим") {
                    Picker("Режим", selection: $model.mode) {
                        ForEach(TrainerMode.allCases) { item in Text(item.label).tag(item) }
                    }
                    .labelsHidden()
                }
                control("Длина") {
                    Picker("Длина", selection: $model.length) {
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
                        Toggle("Микрофон", isOn: $model.mic).disabled(model.recording)
                        Toggle("Звук Mac", isOn: $model.system).disabled(model.recording)
                        Spacer(minLength: 0)
                        Toggle("Перевод на русский", isOn: $model.translate)
                            .disabled(model.language == .ru)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .disabled(model.busy)

            if !model.recording {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.input)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 14))
                        .padding(7)
                        .disabled(model.busy)
                        .accessibilityLabel("Вопрос или ответ кандидата")
                    if model.input.isEmpty {
                        Text(model.mode.placeholder)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 69)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            }

            HStack(spacing: 10) {
                Button {
                    model.toggleCapture()
                } label: {
                    Label(model.recording ? "Остановить" : "Слушать", systemImage: model.recording ? "stop.fill" : "mic")
                }
                .disabled(!model.canToggleCapture)
                .help(windowControls.listeningKey.map { "Прослушивание · \($0)" } ?? "Прослушивание")
                Spacer(minLength: 4)
                if !model.recording {
                    Button { model.send() } label: {
                        Text(model.mode == .practice ? "Новый вопрос" : "Отправить")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .foregroundStyle(model.canSend ? Color.white : Color.secondary)
                            .background(model.canSend ? accent : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.canSend)
                }
            }
            .controlSize(.large)

            if !model.error.isEmpty || !model.status.isEmpty {
                HStack(spacing: 6) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.error.isEmpty ? model.status : model.error)
                        .font(.callout)
                        .foregroundStyle(model.error.isEmpty ? Color.secondary : Color(nsColor: .systemRed))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let shortcutStatus = windowControls.shortcutStatus {
                Text(shortcutStatus).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func control<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            content()
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder private var response: some View {
        if model.recording || !model.liveChat.isEmpty || model.isReplying {
            liveChatPane
        } else {
            writtenResponse
        }
    }

    private var liveChatPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Чат")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.liveChat) { item in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(item.text)
                                    .font(.system(size: 15))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                if !item.segments.isEmpty {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(title(for: item.mode))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        replyText(item.segments)
                                    }
                                    .padding(.horizontal, 10)
                                }
                            }
                        }
                        if !model.liveDraft.isEmpty {
                            Text(model.liveDraft)
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .italic()
                                .padding(.horizontal, 10)
                        }
                        if model.isReplying {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("Готовлю ответ…").foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                        } else if model.liveChat.isEmpty && model.liveDraft.isEmpty {
                            Text("Речь появится здесь.").foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("live-bottom")
                    }
                }
                .onChange(of: model.liveDraft) { _, _ in scroll.scrollTo("live-bottom", anchor: .bottom) }
                .onChange(of: model.liveChat.count) { _, _ in scroll.scrollTo("live-bottom", anchor: .bottom) }
                .onChange(of: model.livePending) { _, _ in scroll.scrollTo("live-bottom", anchor: .bottom) }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func replyText(_ segments: [Segment]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                VStack(alignment: .leading, spacing: 5) {
                    Text(segment.text).font(.system(size: 15)).lineSpacing(3)
                    if model.translate && !segment.ru.isEmpty {
                        Text(segment.ru)
                            .font(.system(size: 13).italic())
                            .lineSpacing(2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.trailing, 6)
        .textSelection(.enabled)
    }

    private var writtenResponse: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(responseTitle)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !model.segments.isEmpty {
                    Button {
                        let text = model.segments.map { segment in
                            !model.translate || segment.ru.isEmpty ? segment.text : "\(segment.text)\n\(segment.ru)"
                        }.joined(separator: "\n\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .accessibilityLabel("Скопировать ответ")
                    .help("Скопировать ответ")
                }
            }
            if model.segments.isEmpty {
                Spacer()
                Text("Здесь появится ответ.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    replyText(model.segments)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var responseTitle: String {
        title(for: model.responseMode ?? model.mode)
    }

    private func title(for mode: TrainerMode) -> String {
        switch mode {
        case .answer: return "Ответ"
        case .review: return "Разбор ответа"
        case .practice: return "Вопрос"
        }
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
        UWCApp.main()
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
        let userCount = model.liveChat.count
        let answerCount = model.liveChat.filter { !$0.segments.isEmpty }.count
        let expected = Int(ProcessInfo.processInfo.environment["UWC_TEST_EXPECTED_TURNS"] ?? "") ?? takes.count
        guard partials > 0, userCount == expected, answerCount == expected, model.error.isEmpty else {
            throw TrainerError("Unexpected live result: \(partials) partials, \(userCount) turns, \(answerCount) answers. \(model.error)")
        }
        print("Live: \(partials) partials, \(userCount) turns, \(answerCount) automatic answers")
        let changed = await gateway.isNewTopic(TurnBoundary(spoken: "How should we welcome a new student?", opening: "What do you think about taxing carbon emissions"))
        let continued = await gateway.isNewTopic(TurnBoundary(spoken: "How should we welcome a new student?", opening: "For example, during the first lunch break"))
        guard changed && !continued else { throw TrainerError("Turn boundary test failed.") }
        print("Topic change separated; example joined.")
        guard store.history.count == expected else { throw TrainerError("History was not saved.") }
        if let path = ProcessInfo.processInfo.environment["UWC_TEST_PREVIEW"] {
            model.recording = true
            model.status = "Слушаю. Ответ появится автоматически."
            try render(model: model, to: path)
        }
    }

    @MainActor private static func renderPreview(to path: String) throws {
        let model = TrainerModel(persistPreferences: false, restoreHistory: false)
        model.language = .en
        model.input = "How can a team make a fair decision when time is limited?"
        model.segments = [
            Segment(text: "I would ask the group to agree on one clear criterion first.", ru: "Я бы предложил группе сначала согласовать один понятный критерий."),
            Segment(text: "Then we could hear one point from each person and choose the option that meets it best.", ru: "Затем можно выслушать по одному аргументу от каждого и выбрать вариант, который лучше всего подходит.")
        ]
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
