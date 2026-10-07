import AppKit
import Carbon
import Foundation
import os

class CursorPaster {
    static let syntheticEventMarker: Int64 = 0x564F494345494E4B
    @MainActor private(set) static var isExecutingAppleScriptPaste = false
    private typealias ClipboardItemSnapshot = [(NSPasteboard.PasteboardType, Data)]
    private typealias ClipboardSnapshot = [ClipboardItemSnapshot]
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CursorPaster")

    enum PasteResult: Equatable {
        case commandPosted
        case commandNotPosted

        var didPostPasteCommand: Bool {
            self == .commandPosted
        }
    }

    struct PasteOutcome {
        let result: PasteResult
        let autoLearnGeneration: UInt64?
    }

    private static let prePasteDelay: TimeInterval = 0.10
    private static let pasteShortcutEventDelay: TimeInterval = 0.01
    private static let minimumClipboardRestoreDelay: TimeInterval = 0.25

    static func pasteAtCursor(_ text: String) {
        Task {
            let pasteTask = await MainActor.run {
                startPasteAtCursor(text)
            }
            _ = await pasteTask.value
        }
    }

    @MainActor
    @discardableResult
    static func startPasteAtCursor(
        _ text: String,
        shouldCancel: @escaping @MainActor () -> Bool = { false }
    ) -> Task<PasteOutcome, Never> {
        Task { @MainActor in
            await performPasteSession(
                text,
                pasteboard: .general,
                postPasteCommand: { await postPasteCommand(shouldCancel: shouldCancel) },
                shouldCancel: shouldCancel
            )
        }
    }

    @MainActor
    static func performPasteSession(
        _ text: String,
        pasteboard: NSPasteboard,
        postPasteCommand: @MainActor () async -> PasteResult,
        shouldCancel: @MainActor () -> Bool
    ) async -> PasteOutcome {
        guard !shouldCancel(), !Task.isCancelled else {
            return PasteOutcome(result: .commandNotPosted, autoLearnGeneration: nil)
        }
        let shouldRestoreClipboard = UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste")
        let savedContents = snapshotClipboard(from: pasteboard)
        let sessionID = UUID().uuidString

        guard
            ClipboardManager.setClipboard(
                text,
                transient: shouldRestoreClipboard,
                sessionID: sessionID,
                on: pasteboard
            )
        else {
            logger.error("Failed to prepare clipboard for paste")
            return PasteOutcome(result: .commandNotPosted, autoLearnGeneration: nil)
        }

        await wait(prePasteDelay)

        if shouldCancel() || Task.isCancelled {
            restoreClipboard(savedContents, expectedText: text, sessionID: sessionID, on: pasteboard)
            return PasteOutcome(result: .commandNotPosted, autoLearnGeneration: nil)
        }

        let pasteResult: PasteResult
        let autoLearnGeneration: UInt64?
        if AutoLearnSettings.isEnabled {
            let targetProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            pasteResult = await postPasteCommand()
            autoLearnGeneration = await AutoLearnService.shared.pasteDidFinish(
                text: text,
                processID: targetProcessID,
                commandPosted: pasteResult.didPostPasteCommand
            )
        } else {
            pasteResult = await postPasteCommand()
            autoLearnGeneration = nil
        }
        if !pasteResult.didPostPasteCommand && (shouldCancel() || Task.isCancelled) {
            restoreClipboard(savedContents, expectedText: text, sessionID: sessionID, on: pasteboard)
        } else if shouldRestoreClipboard {
            scheduleClipboardRestore(
                savedContents,
                expectedText: text,
                sessionID: sessionID,
                on: pasteboard
            )
        }

        return PasteOutcome(result: pasteResult, autoLearnGeneration: autoLearnGeneration)
    }

    private static func snapshotClipboard(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                if let data = item.data(forType: type) {
                    return (type, data)
                }
                return nil
            }
        }
    }

    @MainActor
    private static func postPasteCommand(shouldCancel: @MainActor () -> Bool) async -> PasteResult {
        guard !shouldCancel(), !Task.isCancelled else { return .commandNotPosted }
        if PasteMethod.current() == .appleScript {
            isExecutingAppleScriptPaste = true
            defer { isExecutingAppleScriptPaste = false }
            return pasteUsingAppleScript() ? .commandPosted : .commandNotPosted
        } else {
            return await pasteFromClipboard(shouldCancel: shouldCancel)
        }
    }

    private static func scheduleClipboardRestore(
        _ savedContents: ClipboardSnapshot,
        expectedText: String,
        sessionID: String,
        on pasteboard: NSPasteboard
    ) {
        let delay = max(
            UserDefaults.standard.double(forKey: "clipboardRestoreDelay"),
            minimumClipboardRestoreDelay
        )

        Task { @MainActor in
            await wait(delay)
            restoreClipboard(savedContents, expectedText: expectedText, sessionID: sessionID, on: pasteboard)
        }
    }

    private static func restoreClipboard(
        _ snapshot: ClipboardSnapshot, expectedText: String, sessionID: String, on pasteboard: NSPasteboard
    ) {
        guard pasteboardStillOwnedByPasteSession(pasteboard, expectedText: expectedText, sessionID: sessionID) else { return }
        pasteboard.clearContents()
        if !snapshot.isEmpty { pasteboard.writeObjects(pasteboardItems(from: snapshot)) }
    }

    private static func pasteboardStillOwnedByPasteSession(
        _ pasteboard: NSPasteboard,
        expectedText: String,
        sessionID: String
    ) -> Bool {
        pasteboard.string(forType: .string) == expectedText
            && pasteboard.string(forType: ClipboardManager.pasteSessionType) == sessionID
    }

    private static func pasteboardItems(from snapshot: ClipboardSnapshot) -> [NSPasteboardItem] {
        snapshot.map { itemSnapshot in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: type)
            }
            return item
        }
    }

    // MARK: - AppleScript paste

    // "X – QWERTY ⌘" layouts remap to QWERTY when Command is held, so keystroke "v" resolves
    // the wrong key code. key code 9 (physical V) bypasses layout translation for those layouts.
    private static func makeScript(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }

    private static let pasteScriptKeystroke = makeScript(
        "tell application \"System Events\" to keystroke \"v\" using command down")
    private static let pasteScriptKeyCode = makeScript(
        "tell application \"System Events\" to key code 9 using command down")

    @MainActor
    private static var layoutSwitchesToQWERTYOnCommand: Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let nameRef = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return false }
        return (Unmanaged<CFString>.fromOpaque(nameRef).takeUnretainedValue() as String).hasSuffix("⌘")
    }

    @MainActor
    private static func pasteUsingAppleScript() -> Bool {
        guard let script = layoutSwitchesToQWERTYOnCommand ? pasteScriptKeyCode : pasteScriptKeystroke else {
            logger.error("AppleScript paste script is unavailable")
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript paste failed: \(String(describing: error), privacy: .public)")
        }
        return error == nil
    }

    // MARK: - CGEvent paste

    // Posts Cmd+V via CGEvent without modifying the active input source.
    @MainActor
    private static func pasteFromClipboard(shouldCancel: @MainActor () -> Bool) async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to paste with simulated key events")
            return .commandNotPosted
        }

        let source = CGEventSource(stateID: .privateState)

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else {
            logger.error("Failed to create Cmd+V keyboard events")
            return .commandNotPosted
        }

        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        for event in [cmdDown, vDown, vUp, cmdUp] {
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        }

        guard !shouldCancel(), !Task.isCancelled else { return .commandNotPosted }
        cmdDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        guard !shouldCancel(), !Task.isCancelled else {
            cmdUp.post(tap: .cghidEventTap)
            return .commandNotPosted
        }
        vDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vUp.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        cmdUp.post(tap: .cghidEventTap)

        return .commandPosted
    }

    private static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    // MARK: - Send Key

    static func performSendKey(_ key: FinishAndSendKey) {
        guard key.isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        let source = CGEventSource(stateID: .privateState)
        let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)

        switch key {
        case .none: return
        case .enter: break
        case .shiftEnter:
            enterDown?.flags = .maskShift
            enterUp?.flags = .maskShift
        case .commandEnter:
            enterDown?.flags = .maskCommand
            enterUp?.flags = .maskCommand
        }

        enterDown?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        enterUp?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        enterDown?.post(tap: .cghidEventTap)
        enterUp?.post(tap: .cghidEventTap)
    }
}
