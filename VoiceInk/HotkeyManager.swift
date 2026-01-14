import Foundation
import KeyboardShortcuts
import Carbon
import AppKit

extension KeyboardShortcuts.Name {
    static let toggleMiniRecorder = Self("toggleMiniRecorder")
    static let toggleMiniRecorder2 = Self("toggleMiniRecorder2")
    static let pasteLastTranscription = Self("pasteLastTranscription")
    static let pasteLastEnhancement = Self("pasteLastEnhancement")
    static let retryLastTranscription = Self("retryLastTranscription")
    static let openHistoryWindow = Self("openHistoryWindow")
}

@MainActor
class HotkeyManager: ObservableObject {
    @Published var selectedHotkey1: HotkeyCombination {
        didSet {
            saveHotkeyCombination(selectedHotkey1, forKey: "selectedHotkey1Data")
            setupHotkeyMonitoring()
        }
    }
    @Published var selectedHotkey2: HotkeyCombination {
        didSet {
            if selectedHotkey2.isNone {
                KeyboardShortcuts.setShortcut(nil, for: .toggleMiniRecorder2)
            }
            saveHotkeyCombination(selectedHotkey2, forKey: "selectedHotkey2Data")
            setupHotkeyMonitoring()
        }
    }
    @Published var isMiddleClickToggleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMiddleClickToggleEnabled, forKey: "isMiddleClickToggleEnabled")
            setupHotkeyMonitoring()
        }
    }
    @Published var middleClickActivationDelay: Int {
        didSet {
            UserDefaults.standard.set(middleClickActivationDelay, forKey: "middleClickActivationDelay")
        }
    }

    private var whisperState: WhisperState
    private var miniRecorderShortcutManager: MiniRecorderShortcutManager
    private var powerModeShortcutManager: PowerModeShortcutManager

    // MARK: - Helper Properties
    private var canProcessHotkeyAction: Bool {
        whisperState.recordingState != .transcribing && whisperState.recordingState != .enhancing && whisperState.recordingState != .busy
    }

    // NSEvent monitoring for modifier keys
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    // Middle-click event monitoring
    private var middleClickMonitors: [Any?] = []
    private var middleClickTask: Task<Void, Never>?

    // Combination key state tracking
    private var heldModifierKeys: Set<HotkeyOption> = []
    private var combinationActive = false
    private var keyPressEventTime: TimeInterval?
    private let briefPressThreshold = 0.5
    private var isHandsFreeMode = false

    // Debounce for Fn key
    private var fnDebounceTask: Task<Void, Never>?

    // Keyboard shortcut state tracking
    private var shortcutKeyPressEventTime: TimeInterval?
    private var isShortcutHandsFreeMode = false
    private var shortcutCurrentKeyState = false
    private var lastShortcutTriggerTime: Date?
    private let shortcutCooldownInterval: TimeInterval = 0.5

    // MARK: - Persistence Helpers
    private func saveHotkeyCombination(_ combination: HotkeyCombination, forKey key: String) {
        if let data = try? JSONEncoder().encode(combination) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadHotkeyCombination(forKey key: String, legacyKey: String, defaultOption: HotkeyOption) -> HotkeyCombination {
        // Try new format first
        if let data = UserDefaults.standard.data(forKey: key),
           let combination = try? JSONDecoder().decode(HotkeyCombination.self, from: data) {
            return combination
        }
        // Migrate from old single-key format
        if let oldValue = UserDefaults.standard.string(forKey: legacyKey),
           let option = HotkeyOption(rawValue: oldValue) {
            return HotkeyCombination(option)
        }
        // Default
        return HotkeyCombination(defaultOption)
    }

    enum HotkeyOption: String, CaseIterable, Codable, Hashable {
        case custom = "custom"
        case fn = "fn"
        case leftControl = "leftControl"
        case leftOption = "leftOption"
        case none = "none"
        case rightCommand = "rightCommand"
        case rightControl = "rightControl"
        case rightOption = "rightOption"
        case rightShift = "rightShift"

        var displayName: String {
            switch self {
            case .custom: return "Custom"
            case .fn: return "Fn"
            case .leftControl: return "Left Control (⌃)"
            case .leftOption: return "Left Option (⌥)"
            case .none: return "None"
            case .rightCommand: return "Right Command (⌘)"
            case .rightControl: return "Right Control (⌃)"
            case .rightOption: return "Right Option (⌥)"
            case .rightShift: return "Right Shift (⇧)"
            }
        }

        var keyCode: CGKeyCode? {
            switch self {
            case .fn: return 0x3F
            case .leftControl: return 0x3B
            case .leftOption: return 0x3A
            case .rightCommand: return 0x36
            case .rightControl: return 0x3E
            case .rightOption: return 0x3D
            case .rightShift: return 0x3C
            case .custom, .none: return nil
            }
        }

        var isModifierKey: Bool {
            return self != .custom && self != .none
        }

        /// Check if this modifier key is currently pressed based on flags
        func isPressed(in flags: NSEvent.ModifierFlags) -> Bool {
            switch self {
            case .fn: return flags.contains(.function)
            case .leftControl, .rightControl: return flags.contains(.control)
            case .leftOption, .rightOption: return flags.contains(.option)
            case .rightCommand: return flags.contains(.command)
            case .rightShift: return flags.contains(.shift)
            case .custom, .none: return false
            }
        }

        /// Create HotkeyOption from a keycode
        static func from(keyCode: CGKeyCode) -> HotkeyOption? {
            for option in HotkeyOption.allCases {
                if option.keyCode == keyCode {
                    return option
                }
            }
            return nil
        }
    }

    struct HotkeyCombination: Codable, Equatable {
        var keys: Set<HotkeyOption>

        init(keys: Set<HotkeyOption>) {
            self.keys = keys
        }

        init(_ singleKey: HotkeyOption) {
            self.keys = [singleKey]
        }

        var displayName: String {
            if keys.isEmpty || keys.contains(.none) {
                return "None"
            }
            if keys.count == 1, let key = keys.first, key == .custom {
                return "Custom"
            }
            return keys.sorted { $0.rawValue < $1.rawValue }
                .filter { $0.isModifierKey }
                .map { $0.displayName }
                .joined(separator: " + ")
        }

        var isNone: Bool {
            keys.isEmpty || (keys.count == 1 && keys.contains(.none))
        }

        var isCustom: Bool {
            keys.count == 1 && keys.contains(.custom)
        }

        var hasModifierKeys: Bool {
            keys.contains { $0.isModifierKey }
        }

        /// Check if all keys in combination are currently pressed
        func allKeysPressed(heldKeys: Set<HotkeyOption>) -> Bool {
            let modifierKeys = keys.filter { $0.isModifierKey }
            return !modifierKeys.isEmpty && modifierKeys.isSubset(of: heldKeys)
        }

        static let none = HotkeyCombination(keys: [.none])

        /// Serialized string representation for export (e.g., "rightOption+rightShift")
        var serialized: String {
            if isNone { return "none" }
            if isCustom { return "custom" }
            return keys.filter { $0.isModifierKey }
                .map { $0.rawValue }
                .sorted()
                .joined(separator: "+")
        }

        /// Initialize from serialized string (handles both old single-key and new combination formats)
        init(serialized: String) {
            if serialized.contains("+") {
                // New combination format: "rightOption+rightShift"
                let keyStrings = serialized.split(separator: "+").map(String.init)
                let options = keyStrings.compactMap { HotkeyOption(rawValue: $0) }
                self.keys = Set(options)
            } else {
                // Old single-key format: "rightOption"
                if let option = HotkeyOption(rawValue: serialized) {
                    self.keys = [option]
                } else {
                    self.keys = [.none]
                }
            }
        }
    }
    
    init(whisperState: WhisperState) {
        self.selectedHotkey1 = Self.loadHotkeyCombination(forKey: "selectedHotkey1Data", legacyKey: "selectedHotkey1", defaultOption: .rightCommand)
        self.selectedHotkey2 = Self.loadHotkeyCombination(forKey: "selectedHotkey2Data", legacyKey: "selectedHotkey2", defaultOption: .none)

        self.isMiddleClickToggleEnabled = UserDefaults.standard.bool(forKey: "isMiddleClickToggleEnabled")
        let storedDelay = UserDefaults.standard.integer(forKey: "middleClickActivationDelay")
        self.middleClickActivationDelay = storedDelay > 0 ? storedDelay : 200

        self.whisperState = whisperState
        self.miniRecorderShortcutManager = MiniRecorderShortcutManager(whisperState: whisperState)
        self.powerModeShortcutManager = PowerModeShortcutManager(whisperState: whisperState)

        KeyboardShortcuts.onKeyUp(for: .pasteLastTranscription) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                LastTranscriptionService.pasteLastTranscription(from: self.whisperState.modelContext)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .pasteLastEnhancement) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                LastTranscriptionService.pasteLastEnhancement(from: self.whisperState.modelContext)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .retryLastTranscription) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                LastTranscriptionService.retryLastTranscription(from: self.whisperState.modelContext, whisperState: self.whisperState)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .openHistoryWindow) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                HistoryWindowController.shared.showHistoryWindow(
                    modelContainer: self.whisperState.modelContext.container,
                    whisperState: self.whisperState
                )
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.setupHotkeyMonitoring()
        }
    }
    
    private func setupHotkeyMonitoring() {
        removeAllMonitoring()
        
        setupModifierKeyMonitoring()
        setupCustomShortcutMonitoring()
        setupMiddleClickMonitoring()
    }
    
    private func setupModifierKeyMonitoring() {
        // Only set up if at least one hotkey has modifier keys
        guard selectedHotkey1.hasModifierKeys || selectedHotkey2.hasModifierKeys else { return }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleModifierKeyEvent(event)
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return event }
            Task { @MainActor in
                self.handleModifierKeyEvent(event)
            }
            return event
        }
    }
    
    private func setupMiddleClickMonitoring() {
        guard isMiddleClickToggleEnabled else { return }

        // Mouse Down
        let downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }

            self.middleClickTask?.cancel()
            self.middleClickTask = Task {
                do {
                    let delay = UInt64(self.middleClickActivationDelay) * 1_000_000 // ms to ns
                    try await Task.sleep(nanoseconds: delay)
                    
                    guard self.isMiddleClickToggleEnabled, !Task.isCancelled else { return }
                    
                    Task { @MainActor in
                        guard self.canProcessHotkeyAction else { return }
                        self.whisperState.handleToggleMiniRecorder()
                    }
                } catch {
                    // Cancelled
                }
            }
        }

        // Mouse Up
        let upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }
            self.middleClickTask?.cancel()
        }

        middleClickMonitors = [downMonitor, upMonitor]
    }
    
    private func setupCustomShortcutMonitoring() {
        if selectedHotkey1.isCustom {
            KeyboardShortcuts.onKeyDown(for: .toggleMiniRecorder) { [weak self] in
                let eventTime = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in self?.handleCustomShortcutKeyDown(eventTime: eventTime) }
            }
            KeyboardShortcuts.onKeyUp(for: .toggleMiniRecorder) { [weak self] in
                let eventTime = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in self?.handleCustomShortcutKeyUp(eventTime: eventTime) }
            }
        }
        if selectedHotkey2.isCustom {
            KeyboardShortcuts.onKeyDown(for: .toggleMiniRecorder2) { [weak self] in
                let eventTime = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in self?.handleCustomShortcutKeyDown(eventTime: eventTime) }
            }
            KeyboardShortcuts.onKeyUp(for: .toggleMiniRecorder2) { [weak self] in
                let eventTime = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in self?.handleCustomShortcutKeyUp(eventTime: eventTime) }
            }
        }
    }
    
    private func removeAllMonitoring() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        
        for monitor in middleClickMonitors {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        middleClickMonitors = []
        middleClickTask?.cancel()
        
        resetKeyStates()
    }
    
    private func resetKeyStates() {
        heldModifierKeys.removeAll()
        combinationActive = false
        keyPressEventTime = nil
        isHandsFreeMode = false
        shortcutCurrentKeyState = false
        shortcutKeyPressEventTime = nil
        isShortcutHandsFreeMode = false
    }
    
    private func handleModifierKeyEvent(_ event: NSEvent) {
        let keycode = event.keyCode
        let flags = event.modifierFlags
        let eventTime = event.timestamp

        // Identify which key changed based on keycode
        guard let changedKey = HotkeyOption.from(keyCode: keycode) else { return }

        // Check if this key is part of any configured combination
        let isRelevantKey = selectedHotkey1.keys.contains(changedKey) || selectedHotkey2.keys.contains(changedKey)
        guard isRelevantKey else { return }

        // Determine if this key is now pressed or released
        let isKeyPressed = changedKey.isPressed(in: flags)

        // Handle Fn key debouncing (Fn fires spuriously on some keyboards)
        if changedKey == .fn {
            fnDebounceTask?.cancel()
            fnDebounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 75_000_000) // 75ms
                guard let self = self else { return }
                self.updateHeldKeys(key: changedKey, isPressed: isKeyPressed, eventTime: eventTime)
            }
            return
        }

        updateHeldKeys(key: changedKey, isPressed: isKeyPressed, eventTime: eventTime)
    }

    private func updateHeldKeys(key: HotkeyOption, isPressed: Bool, eventTime: TimeInterval) {
        // Update the set of held keys
        if isPressed {
            heldModifierKeys.insert(key)
        } else {
            heldModifierKeys.remove(key)
        }

        // Check if either combination is now complete
        let combo1Complete = selectedHotkey1.allKeysPressed(heldKeys: heldModifierKeys)
        let combo2Complete = selectedHotkey2.allKeysPressed(heldKeys: heldModifierKeys)
        let anyCombinationComplete = combo1Complete || combo2Complete

        // Detect transitions
        let wasActive = combinationActive
        combinationActive = anyCombinationComplete

        if anyCombinationComplete && !wasActive {
            // Combination just became complete - key down
            processCombinationDown(eventTime: eventTime)
        } else if !anyCombinationComplete && wasActive {
            // Combination just broke - key up (any key released)
            processCombinationUp(eventTime: eventTime)
        }
    }

    private func processCombinationDown(eventTime: TimeInterval) {
        keyPressEventTime = eventTime

        if isHandsFreeMode {
            // In hands-free mode, pressing again stops recording
            isHandsFreeMode = false
            guard canProcessHotkeyAction else { return }
            whisperState.handleToggleMiniRecorder()
            return
        }

        // Start recording if not already visible
        if !whisperState.isMiniRecorderVisible {
            guard canProcessHotkeyAction else { return }
            whisperState.handleToggleMiniRecorder()
        }
    }

    private func processCombinationUp(eventTime: TimeInterval) {
        guard let startTime = keyPressEventTime else { return }
        let pressDuration = eventTime - startTime

        if pressDuration < briefPressThreshold {
            // Brief press - enter hands-free mode
            isHandsFreeMode = true
        } else {
            // Long press - stop recording
            guard canProcessHotkeyAction else { return }
            whisperState.handleToggleMiniRecorder()
        }

        keyPressEventTime = nil
    }

    private func handleCustomShortcutKeyDown(eventTime: TimeInterval) {
        if let lastTrigger = lastShortcutTriggerTime,
           Date().timeIntervalSince(lastTrigger) < shortcutCooldownInterval {
            return
        }

        guard !shortcutCurrentKeyState else { return }
        shortcutCurrentKeyState = true
        lastShortcutTriggerTime = Date()
        shortcutKeyPressEventTime = eventTime

        if isShortcutHandsFreeMode {
            isShortcutHandsFreeMode = false
            guard canProcessHotkeyAction else { return }
            whisperState.handleToggleMiniRecorder()
            return
        }

        if !whisperState.isMiniRecorderVisible {
            guard canProcessHotkeyAction else { return }
            whisperState.handleToggleMiniRecorder()
        }
    }

    private func handleCustomShortcutKeyUp(eventTime: TimeInterval) {
        guard shortcutCurrentKeyState else { return }
        shortcutCurrentKeyState = false

        if let startTime = shortcutKeyPressEventTime {
            let pressDuration = eventTime - startTime

            if pressDuration < briefPressThreshold {
                isShortcutHandsFreeMode = true
            } else {
                guard canProcessHotkeyAction else { return }
                whisperState.handleToggleMiniRecorder()
            }
        }

        shortcutKeyPressEventTime = nil
    }
    
    // Computed property for backward compatibility with UI
    var isShortcutConfigured: Bool {
        let isHotkey1Configured = selectedHotkey1.isCustom ? (KeyboardShortcuts.getShortcut(for: .toggleMiniRecorder) != nil) : true
        let isHotkey2Configured = selectedHotkey2.isCustom ? (KeyboardShortcuts.getShortcut(for: .toggleMiniRecorder2) != nil) : true
        return isHotkey1Configured && isHotkey2Configured
    }

    func updateShortcutStatus() {
        // Called when a custom shortcut changes
        if selectedHotkey1.isCustom || selectedHotkey2.isCustom {
            setupHotkeyMonitoring()
        }
    }
    
    deinit {
        Task { @MainActor in
            removeAllMonitoring()
        }
    }
}
