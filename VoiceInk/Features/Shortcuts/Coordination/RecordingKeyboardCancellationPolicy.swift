import AppKit
import Carbon.HIToolbox

struct RecordingKeyboardCancellationPolicy {
    private var heldInvocationKeys = Set<UInt16>()

    mutating func shouldCancel(
        input: ShortcutMonitor.KeyboardInput,
        invocationShortcuts: [Shortcut],
        isActive: Bool
    ) -> Bool {
        if input.kind == .keyUp {
            heldInvocationKeys.remove(input.inputCode)
            return false
        }

        guard input.isKeyPress else { return false }

        if input.kind == .keyDown {
            if invocationShortcuts.contains(where: {
                $0.matchesKeyEvent(keyCode: input.inputCode, modifierFlags: input.modifierFlags)
            }) {
                heldInvocationKeys.insert(input.inputCode)
                return false
            }
            if input.isRepeat && heldInvocationKeys.contains(input.inputCode) { return false }
        } else if isInvocationModifier(input, shortcuts: invocationShortcuts) {
            return false
        }

        return isActive
    }

    private func isInvocationModifier(_ input: ShortcutMonitor.KeyboardInput, shortcuts: [Shortcut]) -> Bool {
        guard Shortcut.isModifierKeyCode(input.inputCode) else { return false }
        let flags = Shortcut.normalizedModifierFlags(input.modifierFlags, forKeyCode: nil)
        return shortcuts.contains { shortcut in
            guard shortcut.modifierFlags.isSuperset(of: flags) else { return false }
            if shortcut.isModifierOnly && shortcut.keyCode != UInt16.max,
                shortcut.keyCode != input.inputCode
            {
                return false
            }
            return true
        }
    }
}
