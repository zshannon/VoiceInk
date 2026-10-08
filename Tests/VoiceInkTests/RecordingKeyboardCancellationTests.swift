import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import VoiceInk

@Suite @MainActor
struct RecordingKeyboardCancellationTests {
    @Test(arguments: [kVK_F1, kVK_F6, kVK_F20])
    func fnPrefixForFunctionKeyInvocationDoesNotCancelActiveRecording(keyCode: Int) {
        var policy = RecordingKeyboardCancellationPolicy()
        let trigger = Shortcut.key(keyCode: UInt16(keyCode), modifierFlags: [.command, .function])
        #expect(!trigger.modifierFlags.contains(.function))
        let fnCancels = policy.shouldCancel(input: input(UInt16(kVK_Function), kind: .flagsChanged, flags: [.function]), invocationShortcuts: [trigger], isActive: true)
        #expect(!fnCancels)
        let chordCancels = policy.shouldCancel(input: input(UInt16(keyCode), flags: [.command, .function]), invocationShortcuts: [trigger], isActive: true)
        #expect(!chordCancels)
        let extraModifierCancels = policy.shouldCancel(input: input(UInt16(kVK_Shift), kind: .flagsChanged, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.function.rawValue | NSEvent.ModifierFlags.shift.rawValue | 0x2)), invocationShortcuts: [trigger], isActive: true)
        #expect(extraModifierCancels)
        let unrelatedFnCancels = policy.shouldCancel(input: input(UInt16(kVK_Function), kind: .flagsChanged, flags: [.function]), invocationShortcuts: [.rightCommand], isActive: true)
        #expect(unrelatedFnCancels)
    }

    @Test
    func typingBetweenReleasedDoubleTapsPreventsAccidentalRecording() async {
        let session = ShortcutSession()
        var policy = RecordingKeyboardCancellationPolicy()
        let trigger = Shortcut.key(keyCode: UInt16(kVK_ANSI_R), modifierFlags: [.command])
        let time = ProcessInfo.processInfo.systemUptime
        await session.handler.handleShortcutDown(action: .primaryRecording, eventTime: time - 0.15, mode: .doubleTap)
        await session.handler.handleShortcutUp(action: .primaryRecording, eventTime: time - 0.1, mode: .doubleTap)
        #expect(session.toggles == 0)
        #expect(session.handler.hasPendingInvocation)

        let typingCancels = policy.shouldCancel(input: input(UInt16(kVK_ANSI_A)), invocationShortcuts: [trigger], isActive: session.handler.hasPendingInvocation)
        if typingCancels { session.handler.invalidateForKeyboardCancellation() }
        #expect(typingCancels)
        await session.handler.handleShortcutDown(action: .primaryRecording, eventTime: time + 0.1, mode: .doubleTap)
        await session.handler.handleShortcutUp(action: .primaryRecording, eventTime: time + 0.15, mode: .doubleTap)
        #expect(session.toggles == 0)
        #expect(!session.isVisible)

        await session.handler.handleShortcutDown(action: .primaryRecording, eventTime: time + 0.3, mode: .doubleTap)
        await session.handler.handleShortcutUp(action: .primaryRecording, eventTime: time + 0.35, mode: .doubleTap)
        #expect(session.toggles == 1)
        #expect(session.isVisible)
    }

    @Test
    func typingBeforeQueuedDoubleTapReleaseInvalidatesTheCandidate() async {
        let session = ShortcutSession()
        var policy = RecordingKeyboardCancellationPolicy()
        let downSignals = [TestSignal(), TestSignal()]
        var downCount = 0
        let upSignals = [TestSignal(), TestSignal()]
        var upCount = 0
        var cancellations = 0
        let monitor = ShortcutMonitor()
        let trigger = Shortcut.key(keyCode: UInt16(kVK_ANSI_R), modifierFlags: [.command])
        monitor.configure(
            shortcuts: [.primaryRecording: trigger],
            interruptibleActions: [.primaryRecording],
            onShortcutDown: { action, time in
                let generation = session.handler.registerPendingShortcutDown(action: action)
                let signal = downSignals[downCount]
                downCount += 1
                Task { @MainActor in
                    await session.handler.handleShortcutDown(action: action, eventTime: time, inputGeneration: generation, mode: .doubleTap)
                    signal.finish()
                }
            },
            onShortcutUp: { action, time in
                let generation = session.handler.takeShortcutUpGeneration(action: action)
                let signal = upSignals[upCount]
                upCount += 1
                Task { @MainActor in
                    await session.handler.handleShortcutUp(action: action, eventTime: time, inputGeneration: generation, mode: .doubleTap)
                    signal.finish()
                }
            },
            onKeyboardInput: { input in
                if policy.shouldCancel(input: input, invocationShortcuts: [trigger], isActive: session.handler.hasPendingInvocation || !input.pressedShortcutActions.isEmpty) {
                    cancellations += 1
                    session.handler.invalidateForKeyboardCancellation()
                    return true
                }
                return false
            }
        )
        let time = ProcessInfo.processInfo.systemUptime
        _ = monitor.handleEvent(kind: .keyDown, inputCode: UInt16(kVK_ANSI_R), modifierFlags: [.command], eventTime: time - 0.1)
        await downSignals[0].wait()
        _ = monitor.handleEvent(kind: .keyUp, inputCode: UInt16(kVK_ANSI_R), modifierFlags: [.command], eventTime: time)
        #expect(!monitor.handleEvent(kind: .keyDown, inputCode: UInt16(kVK_ANSI_A), modifierFlags: [], eventTime: time + 0.01))
        _ = monitor.handleEvent(kind: .keyUp, inputCode: UInt16(kVK_ANSI_A), modifierFlags: [], eventTime: time + 0.02)
        await upSignals[0].wait()
        #expect(cancellations == 1)
        _ = monitor.handleEvent(kind: .keyDown, inputCode: UInt16(kVK_ANSI_R), modifierFlags: [.command], eventTime: time + 0.1)
        await downSignals[1].wait()
        _ = monitor.handleEvent(kind: .keyUp, inputCode: UInt16(kVK_ANSI_R), modifierFlags: [.command], eventTime: time + 0.15)
        await upSignals[1].wait()
        #expect(session.toggles == 0)
        #expect(!session.isVisible)
    }

    @Test
    func expiredDoubleTapCandidateDoesNotKeepIdleInputActive() async {
        let session = ShortcutSession()
        let time = ProcessInfo.processInfo.systemUptime
        await session.handler.handleShortcutDown(action: .primaryRecording, eventTime: time - 1.1, mode: .doubleTap)
        await session.handler.handleShortcutUp(action: .primaryRecording, eventTime: time - 1, mode: .doubleTap)
        #expect(!session.handler.hasPendingInvocation)
        #expect(session.toggles == 0)
    }

    @Test
    func typingAfterTriggerReleaseCancelsHandsFreeRecording() async {
        let session = ShortcutSession()
        await session.handler.handleShortcutDown(action: .primaryRecording, eventTime: 1, mode: .toggle)
        await session.handler.handleShortcutUp(action: .primaryRecording, eventTime: 1.1, mode: .toggle)

        await session.handler.handleInterruption(action: .primaryRecording)

        #expect(session.cancellations == 1)
        #expect(!session.isVisible)
        #expect(session.state == .idle)
    }

    @Test
    func typingWhileProcessingCancelsTheVisibleSession() async {
        let session = ShortcutSession()
        session.isVisible = true
        session.state = .transcribing

        await session.handler.handleInterruption(action: .primaryRecording)

        #expect(session.cancellations == 1)
        #expect(!session.isVisible)
        #expect(session.state == .idle)
    }

    @Test
    func triggerReleaseAfterCancellationCannotFinishOrReopenTheSession() async {
        let session = ShortcutSession()
        await session.handler.handleShortcutDown(action: .primaryRecording, eventTime: 1, mode: .hybrid)
        await session.handler.handleInterruption(action: .primaryRecording)
        await session.handler.handleShortcutUp(action: .primaryRecording, eventTime: 5, mode: .hybrid)

        #expect(session.cancellations == 1)
        #expect(session.toggles == 1)
        #expect(!session.isVisible)
        await session.handler.handleShortcutDown(action: .primaryRecording, eventTime: 6, mode: .hybrid)
        #expect(session.isVisible)
        #expect(session.toggles == 2)
    }

    @Test
    func aStaleReleaseCannotStopANewerInvocation() async {
        let session = ShortcutSession()
        let oldGeneration = session.handler.registerPendingShortcutDown(action: .primaryRecording)
        await session.handler.handleShortcutDown(action: .primaryRecording, eventTime: 1, inputGeneration: oldGeneration, mode: .hybrid)
        await session.handler.handleInterruption(action: .primaryRecording)
        let newGeneration = session.handler.registerPendingShortcutDown(action: .primaryRecording)
        await session.handler.handleShortcutDown(action: .primaryRecording, eventTime: 2, inputGeneration: newGeneration, mode: .hybrid)
        await session.handler.handleShortcutUp(action: .primaryRecording, eventTime: 3, inputGeneration: oldGeneration, mode: .hybrid)
        #expect(session.state == .recording)
        #expect(session.toggles == 2)
        #expect(session.isVisible)
    }

    @Test(arguments: [RecordingState.starting, .recording, .transcribing, .enhancing, .busy])
    func keyboardCancellationInvalidatesEveryActiveState(state: RecordingState) async {
        let session = ShortcutSession()
        session.state = state
        await session.handler.handleInterruption(action: .primaryRecording)
        #expect(session.cancellations == 1)
        #expect(session.state == .idle)
    }

    @Test(arguments: [false, true])
    func typingBeforeQueuedInvocationRunsPreventsRecording(releaseTrigger: Bool) async {
        let session = ShortcutSession()
        var policy = RecordingKeyboardCancellationPolicy()
        let handled = TestSignal()
        let monitor = ShortcutMonitor()
        let trigger = Shortcut.key(keyCode: UInt16(kVK_ANSI_R), modifierFlags: [.command])
        monitor.configure(
            shortcuts: [.primaryRecording: trigger],
            interruptibleActions: [.primaryRecording],
            onShortcutDown: { action, time in
                let generation = session.handler.registerPendingShortcutDown(action: action)
                Task { @MainActor in
                    await session.handler.handleShortcutDown(action: action, eventTime: time, inputGeneration: generation, mode: .toggle)
                    handled.finish()
                }
            },
            onShortcutUp: { _, _ in },
            onKeyboardInput: { input in
                if policy.shouldCancel(input: input, invocationShortcuts: [trigger], isActive: session.handler.hasPendingInvocation || !input.pressedShortcutActions.isEmpty) {
                    session.handler.invalidateForKeyboardCancellation()
                    return true
                }
                return false
            }
        )

        #expect(monitor.handleEvent(kind: .keyDown, inputCode: UInt16(kVK_ANSI_R), modifierFlags: [.command], eventTime: 1))
        if releaseTrigger {
            _ = monitor.handleEvent(kind: .keyUp, inputCode: UInt16(kVK_ANSI_R), modifierFlags: [.command], eventTime: 1.05)
        }
        #expect(!monitor.handleEvent(kind: .keyDown, inputCode: UInt16(kVK_ANSI_A), modifierFlags: [.command], eventTime: 1.1))
        await handled.wait()
        #expect(session.toggles == 0)
        #expect(!session.isVisible)
        let reopenedGeneration = session.handler.registerPendingShortcutDown(action: .primaryRecording)
        await session.handler.handleShortcutDown(action: .primaryRecording, eventTime: 3, inputGeneration: reopenedGeneration, mode: .toggle)
        #expect(session.toggles == 1)
        #expect(session.isVisible)
    }

    @Test
    func cancellationGateRunsBeforeEscapeAndReturnCanBeConsumed() {
        var policy = RecordingKeyboardCancellationPolicy()
        let monitor = ShortcutMonitor()
        var cancellations = 0
        let trigger = Shortcut.rightCommand
        monitor.configure(
            shortcuts: [
                .recorderPanelEscape: .key(keyCode: UInt16(kVK_Escape), modifierFlags: []),
                .recorderPanelReturn: .key(keyCode: UInt16(kVK_Return), modifierFlags: []),
            ],
            onShortcutDown: { _, _ in Issue.record("Canceling input must not dispatch a panel action") },
            onShortcutUp: { _, _ in },
            onKeyboardInput: { input in
                let cancels = policy.shouldCancel(input: input, invocationShortcuts: [trigger], isActive: true)
                if cancels { cancellations += 1 }
                return cancels
            }
        )
        #expect(!monitor.handleEvent(kind: .keyDown, inputCode: UInt16(kVK_Escape), modifierFlags: [], eventTime: 1))
        #expect(!monitor.handleEvent(kind: .keyDown, inputCode: UInt16(kVK_Return), modifierFlags: [], eventTime: 2))
        #expect(cancellations == 2)
    }

    @Test
    func inputObservationWorksWithoutConfiguredShortcuts() {
        let monitor = ShortcutMonitor()
        var observed = 0
        monitor.configure(
            shortcuts: [:],
            onShortcutDown: { _, _ in },
            onShortcutUp: { _, _ in },
            onKeyboardInput: { _ in observed += 1; return true }
        )
        #expect(!monitor.handleEvent(kind: .keyDown, inputCode: UInt16(kVK_ANSI_A), modifierFlags: [], eventTime: 1))
        #expect(observed == 1)
    }

    @Test
    func invocationChordRepeatsAndReleasesDoNotCancel() {
        var policy = RecordingKeyboardCancellationPolicy()
        let trigger = Shortcut.key(keyCode: UInt16(kVK_ANSI_R), modifierFlags: [.command, .shift])
        let events: [ShortcutMonitor.KeyboardInput] = [
            input(UInt16(kVK_Command), kind: .flagsChanged, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x8)),
            input(UInt16(kVK_Shift), kind: .flagsChanged, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue | 0xA)),
            input(UInt16(kVK_ANSI_R), flags: [.command, .shift]),
            input(UInt16(kVK_ANSI_R), flags: [.command, .shift], repeated: true),
            input(UInt16(kVK_Command), kind: .flagsChanged, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2)),
            input(UInt16(kVK_ANSI_R), flags: [.shift], repeated: true),
            input(UInt16(kVK_ANSI_R), kind: .keyUp),
            input(UInt16(kVK_Shift), kind: .flagsChanged),
        ]
        for event in events {
            let invocationCancels = policy.shouldCancel(input: event, invocationShortcuts: [trigger], isActive: true)
            #expect(!invocationCancels)
        }
        let typingCancels = policy.shouldCancel(input: input(UInt16(kVK_ANSI_A), repeated: true), invocationShortcuts: [trigger], isActive: true)
        #expect(typingCancels)
    }

    @Test
    func additionalModifierPressCancelsButOppositeSideReleaseDoesNot() {
        var policy = RecordingKeyboardCancellationPolicy()
        let trigger = Shortcut.rightCommand
        let leftCommandOnly = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x8)
        let releaseCancels = policy.shouldCancel(input: input(UInt16(kVK_RightCommand), kind: .flagsChanged, flags: leftCommandOnly), invocationShortcuts: [trigger], isActive: true)
        #expect(!releaseCancels)
        let oppositeSidePressCancels = policy.shouldCancel(input: input(UInt16(kVK_Command), kind: .flagsChanged, flags: leftCommandOnly), invocationShortcuts: [trigger], isActive: true)
        #expect(oppositeSidePressCancels)
        let rightCommandAndShift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue | 0x12)
        let additionalModifierCancels = policy.shouldCancel(input: input(UInt16(kVK_Shift), kind: .flagsChanged, flags: rightCommandAndShift), invocationShortcuts: [trigger], isActive: true)
        #expect(additionalModifierCancels)
    }

    @Test
    func idleKeysAndMouseEventsDoNotCancel() {
        var policy = RecordingKeyboardCancellationPolicy()
        let idleCancels = policy.shouldCancel(input: input(UInt16(kVK_ANSI_A)), invocationShortcuts: [], isActive: false)
        #expect(!idleCancels)
        let mouseCancels = policy.shouldCancel(input: input(2, kind: .mouseDown), invocationShortcuts: [], isActive: true)
        #expect(!mouseCancels)
        let keyReleaseCancels = policy.shouldCancel(input: input(UInt16(kVK_ANSI_A), kind: .keyUp), invocationShortcuts: [], isActive: true)
        #expect(!keyReleaseCancels)
    }

    @Test
    func releasedModeInvocationIsCanceledByInputAtAnotherTap() async {
        let session = ShortcutSession()
        var policy = RecordingKeyboardCancellationPolicy()
        let handled = TestSignal()
        let modeAction = ShortcutAction.mode(UUID())
        let trigger = Shortcut.modifierOnly(keyCode: UInt16(kVK_Function), modifierFlags: [.function])
        let gate: (ShortcutMonitor.KeyboardInput) -> Bool = { input in
            let cancels = policy.shouldCancel(input: input, invocationShortcuts: [trigger], isActive: session.handler.hasPendingInvocation)
            if cancels { session.handler.invalidateForKeyboardCancellation() }
            return cancels
        }
        let modeMonitor = ShortcutMonitor()
        modeMonitor.configure(
            shortcuts: [modeAction: trigger],
            interruptibleActions: [modeAction],
            onShortcutDown: { action, time in
                let generation = session.handler.registerPendingShortcutDown(action: action)
                Task { @MainActor in
                    await session.handler.handleShortcutDown(action: action, eventTime: time, inputGeneration: generation, mode: .pushToTalk)
                    handled.finish()
                }
            },
            onShortcutUp: { _, _ in },
            onKeyboardInput: gate
        )
        let frontMonitor = ShortcutMonitor()
        frontMonitor.configure(
            shortcuts: [.pasteLastTranscription: .key(keyCode: UInt16(kVK_ANSI_C), modifierFlags: [.command])],
            onShortcutDown: { _, _ in Issue.record("Typing must not dispatch the other tap's utility action") },
            onShortcutUp: { _, _ in },
            onKeyboardInput: gate
        )
        _ = modeMonitor.handleEvent(kind: .flagsChanged, inputCode: UInt16(kVK_Function), modifierFlags: [.function], eventTime: 1)
        _ = modeMonitor.handleEvent(kind: .flagsChanged, inputCode: UInt16(kVK_Function), modifierFlags: [], eventTime: 1.1)
        #expect(!frontMonitor.handleEvent(kind: .keyDown, inputCode: UInt16(kVK_ANSI_C), modifierFlags: [.command], eventTime: 1.2))
        await handled.wait()
        #expect(session.toggles == 0)
    }

    @Test
    func anotherInvocationChordIsNotCanceledByLegacyInterruption() {
        var policy = RecordingKeyboardCancellationPolicy()
        let triggers = [Shortcut.rightCommand, .key(keyCode: UInt16(kVK_ANSI_R), modifierFlags: [.command])]
        let monitor = ShortcutMonitor()
        var triggered: [ShortcutAction] = []
        monitor.configure(
            shortcuts: [.primaryRecording: triggers[0], .secondaryRecording: triggers[1]],
            interruptibleActions: [.primaryRecording, .secondaryRecording],
            onShortcutDown: { action, _ in triggered.append(action) },
            onShortcutUp: { _, _ in },
            onShortcutInterrupted: { _, _ in Issue.record("An exempt invocation must not cancel the session") },
            onKeyboardInput: { policy.shouldCancel(input: $0, invocationShortcuts: triggers, isActive: true) }
        )
        _ = monitor.handleEvent(kind: .flagsChanged, inputCode: UInt16(kVK_RightCommand), modifierFlags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10), eventTime: 1)
        #expect(monitor.handleEvent(kind: .keyDown, inputCode: UInt16(kVK_ANSI_R), modifierFlags: [.command], eventTime: 1.1))
        #expect(triggered == [.primaryRecording, .secondaryRecording])
    }

    @Test
    func voiceInkGeneratedPasteEventsCannotCancelOrInvokeShortcuts() throws {
        let monitor = ShortcutMonitor()
        var observed = 0
        monitor.configure(
            shortcuts: [.primaryRecording: .key(keyCode: UInt16(kVK_ANSI_V), modifierFlags: [.command])],
            onShortcutDown: { _, _ in Issue.record("Synthetic paste must not invoke recording") },
            onShortcutUp: { _, _ in },
            onKeyboardInput: { _ in observed += 1; return true }
        )
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_ANSI_V), keyDown: true))
        event.flags = .maskCommand
        event.setIntegerValueField(.eventSourceUserData, value: CursorPaster.syntheticEventMarker)
        #expect(!monitor.handleCGEvent(type: .keyDown, event: event))
        #expect(observed == 0)
    }

    @Test
    func lateStartupCannotPassTheCheckpointOrRunFallbackAfterCancel() async {
        let cancellation = RecordingCancellationState()
        let started = TestSignal()
        let finish = TestSignal()
        var attempts = 0
        let startup = Task {
            try await cancellation.runStartupAttempt {
                attempts += 1
                started.finish()
                await finish.wait()
            }
        }
        await started.wait()
        cancellation.cancel()
        finish.finish()
        do {
            try await startup.value
            Issue.record("A late startup must report cancellation")
        } catch is CancellationError {
        } catch { Issue.record("Unexpected startup error: \(error)") }
        do {
            try await cancellation.runStartupAttempt { attempts += 1 }
            Issue.record("Fallback must not start after cancellation")
        } catch is CancellationError {
        } catch { Issue.record("Unexpected fallback error: \(error)") }
        #expect(attempts == 1)

        let reopened = RecordingCancellationState()
        do { try await reopened.runStartupAttempt { attempts += 1 } }
        catch { Issue.record("A new invocation should start independently: \(error)") }
        #expect(attempts == 2)
    }

    private func input(
        _ code: UInt16, kind: ShortcutMonitor.EventKind = .keyDown,
        flags: NSEvent.ModifierFlags = [], repeated: Bool = false
    ) -> ShortcutMonitor.KeyboardInput {
        .init(inputCode: code, isRepeat: repeated, kind: kind, modifierFlags: flags, pressedShortcutActions: [])
    }
}

@MainActor
private final class ShortcutSession {
    var cancellations = 0
    var isVisible = false
    var state: RecordingState = .idle
    var toggles = 0

    lazy var handler = RecordingShortcutModeHandler(
        canHandleShortcutAction: { [unowned self] in state == .idle || state == .recording },
        isRecorderVisible: { [unowned self] in isVisible },
        recordingState: { [unowned self] in state },
        toggleRecorderPanel: { [unowned self] _ in
            toggles += 1
            isVisible.toggle()
            state = isVisible ? .recording : .transcribing
        },
        cancelRecording: { [unowned self] in
            cancellations += 1
            isVisible = false
            state = .idle
        }
    )
}

@MainActor
final class TestSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isFinished = false

    func finish() {
        isFinished = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if isFinished { return }
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !isFinished else { return }
            Issue.record("Timed out waiting for the controlled async boundary")
            finish()
        }
        defer { timeout.cancel() }
        await withCheckedContinuation { continuation = $0 }
    }
}
