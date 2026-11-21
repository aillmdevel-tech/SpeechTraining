import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let gateway: Gateway
    @State private var draft = ProviderSettings()
    @State private var failure = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Настройки").font(.title2)
            SecureField("Ключ Gemini", text: $draft.gemini)
                .textFieldStyle(.roundedBorder)
            SecureField("Ключ ElevenLabs", text: $draft.elevenlabs)
                .textFieldStyle(.roundedBorder)
            Text("Контекст для тренировки").font(.headline)
            TextEditor(text: $draft.profile)
                .font(.system(size: 14))
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            if !failure.isEmpty { Text(failure).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { draft = gateway.store.settings }
    }

    private func save() {
        draft.gemini = draft.gemini.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.elevenlabs = draft.elevenlabs.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try gateway.store.saveSettings(draft)
            gateway.shutdown()
            dismiss()
        } catch {
            failure = "Не удалось сохранить настройки."
        }
    }
}
