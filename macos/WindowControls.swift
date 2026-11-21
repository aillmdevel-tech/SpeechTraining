import AppKit
import Carbon
import SwiftUI

private enum GlobalAction: UInt32 {
    case listen = 1
    case window
}

private struct HotKey {
    let key: Int
    let modifiers: Int
    let label: String
}

@MainActor
final class WindowControls: ObservableObject {
    @Published var ghost = true {
        didSet { applyGhost() }
    }
    @Published private(set) var listeningKey: String?
    @Published private(set) var windowKey: String?
    @Published private(set) var shortcutStatus: String?

    private weak var window: NSWindow?
    private var listen: (() -> Void)?
    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var pressed: Set<UInt32> = []
    private var localMonitor: Any?

    private static let signature: OSType = 0x55574354 // UWCT
    private static let controlShift = controlKey | shiftKey
    private static let commandOptionShift = cmdKey | optionKey | shiftKey

    func attach(_ window: NSWindow) {
        self.window = window
        applyGhost()
    }

    private func applyGhost() {
        window?.sharingType = ghost ? .none : .readOnly
    }

    func toggleWindow() {
        guard let window else { return }
        if !NSApp.isHidden && window.isVisible && !window.isMiniaturized {
            NSApp.hide(nil)
        } else {
            showWindow()
        }
    }

    func showWindow() {
        guard let window else { return }
        applyGhost()
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func installShortcuts(listen: @escaping () -> Void) {
        self.listen = listen
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let windowNumber = event.windowNumber
            let plain = event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty
            let grave = Int(event.keyCode) == kVK_ANSI_Grave || event.charactersIgnoringModifiers == "`"
            let repeated = event.isARepeat
            let consumed = MainActor.assumeIsolated {
                self?.handleLocalKey(windowNumber: windowNumber, plain: plain, grave: grave, repeated: repeated) == true
            }
            return consumed ? nil : event
        }
        let events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let target = GetApplicationEventTarget()
        let status = events.withUnsafeBufferPointer { events in
            InstallEventHandler(target, Self.onHotKey, events.count, events.baseAddress,
                                Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        guard status == noErr else {
            shortcutStatus = "macOS не подключила системные горячие клавиши."
            return
        }
        listeningKey = register(.listen, candidates: [
            HotKey(key: kVK_ANSI_Grave, modifiers: Self.controlShift, label: "⌃⇧`"),
            HotKey(key: kVK_ANSI_Grave, modifiers: Self.commandOptionShift, label: "⌥⇧⌘`"),
        ])
        windowKey = register(.window, candidates: [
            HotKey(key: kVK_Space, modifiers: Self.controlShift, label: "⌃⇧Пробел"),
            HotKey(key: kVK_Space, modifiers: Self.commandOptionShift, label: "⌥⇧⌘Пробел"),
        ])
        if listeningKey == nil || windowKey == nil {
            shortcutStatus = "Одна из системных горячих клавиш недоступна."
        }
    }

    private func register(_ action: GlobalAction, candidates: [HotKey]) -> String? {
        for candidate in candidates {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let status = RegisterEventHotKey(UInt32(candidate.key), UInt32(candidate.modifiers), identifier,
                                             GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
            if status == noErr, let reference {
                hotKeys.append(reference)
                return candidate.label
            }
        }
        return nil
    }

    private func handleLocalKey(windowNumber: Int, plain: Bool, grave: Bool, repeated: Bool) -> Bool {
        guard let window, windowNumber == window.windowNumber, plain, grave,
              (window.firstResponder as? NSTextView)?.isEditable != true else { return false }
        if !repeated { listen?() }
        return true
    }

    private static let onHotKey: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        let kind = GetEventKind(event)
        guard status == noErr else { return status }
        let controls = Unmanaged<WindowControls>.fromOpaque(context).takeUnretainedValue()
        return MainActor.assumeIsolated {
            guard identifier.signature == WindowControls.signature,
                  let action = GlobalAction(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }
            controls.handle(action, pressed: kind == UInt32(kEventHotKeyPressed))
            return noErr
        }
    }

    private func handle(_ action: GlobalAction, pressed isDown: Bool) {
        guard isDown else {
            pressed.remove(action.rawValue)
            return
        }
        guard pressed.insert(action.rawValue).inserted else { return }
        switch action {
        case .listen: listen?()
        case .window: toggleWindow()
        }
    }

    func uninstallShortcuts() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        pressed.removeAll()
        listen = nil
    }
}

struct WindowAttachment: NSViewRepresentable {
    let controls: WindowControls

    func makeNSView(context: Context) -> Attachment {
        Attachment(controls: controls)
    }

    func updateNSView(_ view: Attachment, context: Context) {}

    final class Attachment: NSView {
        weak var controls: WindowControls?

        init(controls: WindowControls) {
            self.controls = controls
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("WindowAttachment requires WindowControls") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { controls?.attach(window) }
        }
    }
}
