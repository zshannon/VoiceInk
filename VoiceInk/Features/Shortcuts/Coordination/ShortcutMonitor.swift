import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit.hidsystem
import os

final class ShortcutMonitor {
    enum EventKind {
        case keyDown
        case keyUp
        case flagsChanged
        case mouseDown
        case mouseDragged
        case mouseUp
    }

    struct KeyboardInput {
        let inputCode: UInt16
        let isRepeat: Bool
        let kind: EventKind
        let modifierFlags: NSEvent.ModifierFlags
        let pressedShortcutActions: Set<ShortcutAction>

        var isKeyPress: Bool {
            if kind == .keyDown { return true }
            guard kind == .flagsChanged else { return false }
            if inputCode == UInt16(kVK_CapsLock) { return true }
            guard let mask = Self.modifierKeyMasks[inputCode] else { return false }
            return modifierFlags.rawValue & mask != 0
        }

        // Device-specific masks distinguish opposite-side modifier releases.
        private static let modifierKeyMasks: [UInt16: UInt] = [
            UInt16(kVK_Command): UInt(NX_DEVICELCMDKEYMASK),
            UInt16(kVK_Control): UInt(NX_DEVICELCTLKEYMASK),
            UInt16(kVK_Function): UInt(NX_SECONDARYFNMASK),
            UInt16(kVK_Option): UInt(NX_DEVICELALTKEYMASK),
            UInt16(kVK_RightCommand): UInt(NX_DEVICERCMDKEYMASK),
            UInt16(kVK_RightControl): UInt(NX_DEVICERCTLKEYMASK),
            UInt16(kVK_RightOption): UInt(NX_DEVICERALTKEYMASK),
            UInt16(kVK_RightShift): UInt(NX_DEVICERSHIFTKEYMASK),
            UInt16(kVK_Shift): UInt(NX_DEVICELSHIFTKEYMASK),
        ]
    }

    private struct ShortcutState {
        var shortcut: Shortcut
        var isDown = false
        var pressedAt: TimeInterval?
        var isInterrupted = false
        var requiresStandaloneRelease = false
    }

    private var shortcuts: [ShortcutAction: ShortcutState] = [:]
    private var pressedKeyCodes = Set<UInt16>()
    private var suppressedMouseButtons = Set<UInt16>()
    private var interruptibleActions: Set<ShortcutAction> = []
    private var standaloneModifierActions: Set<ShortcutAction> = []
    private var onKeyboardInput: ((KeyboardInput) -> Bool)?
    private var onShortcutDown: ((ShortcutAction, TimeInterval) -> Void)?
    private var onShortcutUp: ((ShortcutAction, TimeInterval) -> Void)?
    private var onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)?
    private var onStandaloneModifierChord: ((ShortcutAction) -> Void)?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ShortcutMonitor")

    private static let shortcutInterruptionWindow: TimeInterval = 1.0

    deinit {
        stop()
    }

    @discardableResult
    func start(
        shortcuts: [ShortcutAction: Shortcut],
        interruptibleActions: Set<ShortcutAction> = [],
        standaloneModifierActions: Set<ShortcutAction> = [],
        onShortcutDown: @escaping (ShortcutAction, TimeInterval) -> Void,
        onShortcutUp: @escaping (ShortcutAction, TimeInterval) -> Void,
        onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)? = nil,
        onStandaloneModifierChord: ((ShortcutAction) -> Void)? = nil,
        onKeyboardInput: ((KeyboardInput) -> Bool)? = nil
    ) -> Bool {
        configure(
            shortcuts: shortcuts,
            interruptibleActions: interruptibleActions,
            standaloneModifierActions: standaloneModifierActions,
            onShortcutDown: onShortcutDown,
            onShortcutUp: onShortcutUp,
            onShortcutInterrupted: onShortcutInterrupted,
            onStandaloneModifierChord: onStandaloneModifierChord,
            onKeyboardInput: onKeyboardInput
        )
        guard !self.shortcuts.isEmpty || onKeyboardInput != nil else { return true }
        return installEventTap()
    }

    func configure(
        shortcuts: [ShortcutAction: Shortcut],
        interruptibleActions: Set<ShortcutAction> = [],
        standaloneModifierActions: Set<ShortcutAction> = [],
        onShortcutDown: @escaping (ShortcutAction, TimeInterval) -> Void,
        onShortcutUp: @escaping (ShortcutAction, TimeInterval) -> Void,
        onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)? = nil,
        onStandaloneModifierChord: ((ShortcutAction) -> Void)? = nil,
        onKeyboardInput: ((KeyboardInput) -> Bool)? = nil
    ) {
        stop()

        for (action, shortcut) in shortcuts {
            self.shortcuts[action] = ShortcutState(shortcut: shortcut)
        }

        self.interruptibleActions = interruptibleActions
        self.standaloneModifierActions = standaloneModifierActions
        self.onShortcutDown = onShortcutDown
        self.onShortcutUp = onShortcutUp
        self.onShortcutInterrupted = onShortcutInterrupted
        self.onStandaloneModifierChord = onStandaloneModifierChord
        self.onKeyboardInput = onKeyboardInput
    }

    func updateStandaloneModifierActions(_ actions: Set<ShortcutAction>) {
        standaloneModifierActions = actions
    }

    func stop() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        shortcuts = [:]
        pressedKeyCodes = []
        suppressedMouseButtons = []
        interruptibleActions = []
        standaloneModifierActions = []
        onShortcutDown = nil
        onShortcutUp = nil
        onShortcutInterrupted = nil
        onStandaloneModifierChord = nil
        onKeyboardInput = nil
    }

    private func installEventTap() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.resetPressedShortcutsAfterTapInterruption()
                if let eventTap = monitor.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let shouldSuppress = monitor.handleCGEvent(type: type, event: event)
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: Self.eventMask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            logger.error("Failed to install global shortcut event tap")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            logger.error("Failed to create global shortcut event tap run loop source")
            return false
        }

        self.eventTap = eventTap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == CursorPaster.syntheticEventMarker {
            return false
        }
        let isAppleScriptPasteEvent = MainActor.assumeIsolated {
            guard CursorPaster.isExecutingAppleScriptPaste,
                let processID = pid_t(exactly: event.getIntegerValueField(.eventSourceUnixProcessID)),
                processID != 0
            else { return false }
            return NSRunningApplication(processIdentifier: processID)?.bundleIdentifier == "com.apple.systemevents"
        }
        if isAppleScriptPasteEvent { return false }
        guard UserSessionInputPolicy.allowsShortcutHandling else {
            clearPressedShortcutState()
            return false
        }

        guard let eventKind = EventKind(type) else {
            return false
        }

        let inputCode: UInt16
        switch eventKind {
        case .keyDown, .keyUp, .flagsChanged:
            inputCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        case .mouseDown, .mouseDragged, .mouseUp:
            inputCode = UInt16(clamping: event.getIntegerValueField(.mouseEventButtonNumber))
        }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        return handleEvent(
            kind: eventKind,
            inputCode: inputCode,
            modifierFlags: modifierFlags,
            eventTime: ProcessInfo.processInfo.systemUptime,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
    }

    private func resetPressedShortcutsAfterTapInterruption() {
        releasePressedShortcuts(eventTime: ProcessInfo.processInfo.systemUptime)
    }

    private func clearPressedShortcutState() {
        releasePressedShortcuts(eventTime: ProcessInfo.processInfo.systemUptime)
        suppressedMouseButtons.removeAll()
    }

    private func releasePressedShortcuts(eventTime: TimeInterval) {
        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action] else { continue }
            let shouldDispatchUp = state.isDown && !state.requiresStandaloneRelease
            state.isDown = false
            state.pressedAt = nil
            state.isInterrupted = false
            state.requiresStandaloneRelease = false
            shortcuts[action] = state
            if shouldDispatchUp {
                dispatchShortcutUp(for: action, eventTime: eventTime)
            }
        }
        pressedKeyCodes.removeAll()
    }

    func handleEvent(
        kind: EventKind,
        inputCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval,
        isRepeat: Bool = false
    ) -> Bool {
        let pressedRecordingActions = Set(shortcuts.compactMap { action, state in
            state.isDown && !state.requiresStandaloneRelease && interruptibleActions.contains(action) ? action : nil
        })
        let input = KeyboardInput(
            inputCode: inputCode,
            isRepeat: isRepeat,
            kind: kind,
            modifierFlags: modifierFlags,
            pressedShortcutActions: pressedRecordingActions
        )
        // All existing taps share this gate. Run it before any tap can consume
        // Escape, Return, or another shortcut, and preserve the user's input.
        if onKeyboardInput?(input) == true {
            updatePressedKeyCodes(kind: kind, inputCode: inputCode)
            invalidateStandaloneModifierCandidateForKeyboardEvent(
                kind: kind, inputCode: inputCode, modifierFlags: modifierFlags
            )
            return false
        }
        var shouldSuppress: Bool
        switch kind {
        case .mouseDragged:
            shouldSuppress = suppressedMouseButtons.contains(inputCode)
        case .mouseUp:
            shouldSuppress = suppressedMouseButtons.remove(inputCode) != nil
        case .keyDown, .keyUp, .flagsChanged, .mouseDown:
            shouldSuppress = false
        }

        updatePressedKeyCodes(kind: kind, inputCode: inputCode)
        invalidateStandaloneModifierCandidateForKeyboardEvent(
            kind: kind,
            inputCode: inputCode,
            modifierFlags: modifierFlags
        )

        if kind == .keyDown {
            handleShortcutInterruptions(keyCode: inputCode, eventTime: eventTime)
        }

        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action] else {
                continue
            }

            if state.shortcut.isModifierOnly {
                handleModifierOnlyShortcut(
                    action: action,
                    state: state,
                    kind: kind,
                    keyCode: inputCode,
                    modifierFlags: modifierFlags,
                    eventTime: eventTime
                )
                continue
            }

            let transition: ShortcutTransition
            switch state.shortcut.kind {
            case .key:
                transition = transitionForKeyShortcut(
                    state.shortcut,
                    isDown: state.isDown,
                    kind: kind,
                    keyCode: inputCode,
                    modifierFlags: modifierFlags
                )
            case .mouseButton:
                transition = transitionForMouseShortcut(
                    state.shortcut,
                    isDown: state.isDown,
                    kind: kind,
                    buttonNumber: inputCode,
                    modifierFlags: modifierFlags
                )
            case .modifierOnly:
                transition = .none
            }

            switch transition {
            case .none:
                break
            case .suppress:
                if kind != .flagsChanged {
                    shouldSuppress = true
                }
            case .keyDown:
                state.isDown = true
                state.pressedAt = eventTime
                state.isInterrupted = false
                shortcuts[action] = state
                if state.shortcut.kind == .mouseButton {
                    suppressedMouseButtons.insert(inputCode)
                }
                shouldSuppress = true
                dispatchShortcutDown(for: action, eventTime: eventTime)
            case .keyUp:
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
                if kind != .flagsChanged {
                    shouldSuppress = true
                }
                dispatchShortcutUp(for: action, eventTime: eventTime)
            }
        }

        return shouldSuppress
    }

    private enum ShortcutTransition {
        case none
        case suppress
        case keyDown
        case keyUp
    }

    private func transitionForKeyShortcut(
        _ shortcut: Shortcut,
        isDown: Bool,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        switch kind {
        case .keyDown:
            guard shortcut.matchesKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags) else {
                return .none
            }

            return isDown ? .suppress : .keyDown
        case .keyUp:
            return isDown && keyCode == shortcut.keyCode ? .keyUp : .none
        case .flagsChanged:
            guard isDown else {
                return .none
            }

            let currentFlags = Shortcut.normalizedModifierFlags(
                modifierFlags,
                forKeyCode: shortcut.keyCode
            )
            return currentFlags.isSuperset(of: shortcut.modifierFlags) ? .suppress : .keyUp
        case .mouseDown, .mouseDragged, .mouseUp:
            return .none
        }
    }

    private func transitionForMouseShortcut(
        _ shortcut: Shortcut,
        isDown: Bool,
        kind: EventKind,
        buttonNumber: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        switch kind {
        case .mouseDown:
            guard shortcut.matchesMouseEvent(
                buttonNumber: buttonNumber,
                modifierFlags: modifierFlags
            ) else {
                return .none
            }

            return isDown ? .suppress : .keyDown
        case .mouseUp:
            return isDown && buttonNumber == shortcut.keyCode ? .keyUp : .none
        case .flagsChanged:
            guard isDown else {
                return .none
            }

            let currentFlags = Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: nil)
            return currentFlags.isSuperset(of: shortcut.modifierFlags) ? .suppress : .keyUp
        case .keyDown, .keyUp, .mouseDragged:
            return .none
        }
    }

    private func handleModifierOnlyShortcut(
        action: ShortcutAction,
        state: ShortcutState,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval
    ) {
        var state = state

        guard kind == .flagsChanged else {
            return
        }

        if state.isDown {
            if state.shortcut.shouldReleaseModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) {
                let shouldTrigger =
                    state.requiresStandaloneRelease
                    && !state.isInterrupted
                let shouldDispatchUp = !state.requiresStandaloneRelease
                let pressedAt = state.pressedAt
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                state.requiresStandaloneRelease = false
                shortcuts[action] = state
                if shouldTrigger, let pressedAt {
                    dispatchShortcutDown(for: action, eventTime: pressedAt)
                    dispatchShortcutUp(for: action, eventTime: eventTime)
                } else if shouldDispatchUp {
                    dispatchShortcutUp(for: action, eventTime: eventTime)
                }
            }

            return
        }

        if state.shortcut.matchesModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) {
            state.isDown = true
            state.pressedAt = eventTime
            state.requiresStandaloneRelease = standaloneModifierActions.contains(action)
            state.isInterrupted = state.requiresStandaloneRelease && !pressedKeyCodes.isEmpty
            shortcuts[action] = state
            if !state.requiresStandaloneRelease {
                dispatchShortcutDown(for: action, eventTime: eventTime)
            }
        }
    }

    private func updatePressedKeyCodes(kind: EventKind, inputCode: UInt16) {
        switch kind {
        case .keyDown:
            pressedKeyCodes.insert(inputCode)
        case .keyUp:
            pressedKeyCodes.remove(inputCode)
        case .flagsChanged, .mouseDown, .mouseDragged, .mouseUp:
            break
        }
    }

    private func invalidateStandaloneModifierCandidateForKeyboardEvent(
        kind: EventKind,
        inputCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard kind == .keyDown || kind == .keyUp || kind == .flagsChanged else {
            return
        }

        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action],
                state.isDown,
                state.requiresStandaloneRelease,
                !state.isInterrupted
            else {
                continue
            }

            let isReleaseEvent = kind == .flagsChanged
                && state.shortcut.shouldReleaseModifierEvent(
                    keyCode: inputCode,
                    modifierFlags: modifierFlags
                )
            if !isReleaseEvent {
                state.isInterrupted = true
                shortcuts[action] = state
            }
        }
    }

    private func handleShortcutInterruptions(keyCode: UInt16, eventTime: TimeInterval) {
        guard !Shortcut.isModifierKeyCode(keyCode) else {
            return
        }

        for action in standaloneModifierActions {
            guard shortcuts[action]?.shortcut.isModifierOnly == true else { continue }
            onStandaloneModifierChord?(action)
        }

        // The shared input gate owns cancellation when installed. Exempt
        // invocation keys must not be canceled by the old one-second heuristic.
        guard onKeyboardInput == nil else { return }

        for action in interruptibleActions {
            guard var state = shortcuts[action],
                state.isDown,
                !state.isInterrupted,
                let pressedAt = state.pressedAt,
                eventTime - pressedAt <= Self.shortcutInterruptionWindow,
                state.shortcut.isInterruptedByAdditionalKeyDown(keyCode: keyCode)
            else {
                continue
            }

            state.isInterrupted = true
            shortcuts[action] = state
            dispatchShortcutInterrupted(for: action, eventTime: eventTime)
        }
    }

    private func dispatchShortcutDown(for action: ShortcutAction, eventTime: TimeInterval) {
        // Arm pending invocation ownership before later physical input arrives.
        // Clients still run the recording workflow in a MainActor task.
        onShortcutDown?(action, eventTime)
    }

    private func dispatchShortcutUp(for action: ShortcutAction, eventTime: TimeInterval) {
        onShortcutUp?(action, eventTime)
    }

    private func dispatchShortcutInterrupted(for action: ShortcutAction, eventTime: TimeInterval) {
        DispatchQueue.main.async { [onShortcutInterrupted] in
            onShortcutInterrupted?(action, eventTime)
        }
    }

    private static let eventMask: CGEventMask = [
        CGEventType.keyDown,
        CGEventType.keyUp,
        CGEventType.flagsChanged,
        CGEventType.otherMouseDown,
        CGEventType.otherMouseDragged,
        CGEventType.otherMouseUp,
    ].reduce(CGEventMask(0)) { mask, type in
        mask | (CGEventMask(1) << Int(type.rawValue))
    }
}

private extension ShortcutMonitor.EventKind {
    init?(_ type: CGEventType) {
        switch type {
        case .keyDown:
            self = .keyDown
        case .keyUp:
            self = .keyUp
        case .flagsChanged:
            self = .flagsChanged
        case .otherMouseDown:
            self = .mouseDown
        case .otherMouseDragged:
            self = .mouseDragged
        case .otherMouseUp:
            self = .mouseUp
        default:
            return nil
        }
    }
}
