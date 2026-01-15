import SwiftUI

struct NotchRecorderView: View {
    @ObservedObject var whisperState: WhisperState
    @ObservedObject var recorder: Recorder
    @EnvironmentObject var windowManager: NotchWindowManager
    @State private var isHovering = false
    @State private var activePopover: ActivePopoverState = .none
    @ObservedObject private var powerModeManager = PowerModeManager.shared
    
    @EnvironmentObject private var enhancementService: AIEnhancementService
    
    private var menuBarHeight: CGFloat {
        if let screen = NSScreen.main {
            if screen.safeAreaInsets.top > 0 {
                return screen.safeAreaInsets.top
            }
            return NSApplication.shared.mainMenu?.menuBarHeight ?? NSStatusBar.system.thickness
        }
        return NSStatusBar.system.thickness
    }
    
    private var exactNotchWidth: CGFloat {
        if let screen = NSScreen.main {
            if screen.safeAreaInsets.left > 0 {
                return screen.safeAreaInsets.left * 2
            }
            return 200
        }
        return 200
    }
    
    private var centerSection: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: exactNotchWidth)
            .contentShape(Rectangle())
    }

    private var rightSection: some View {
        RecorderStatusDisplay(
            currentState: whisperState.recordingState,
            audioMeter: recorder.audioMeter,
            menuBarHeight: menuBarHeight
        )
        .frame(width: 50)
        .padding(.leading, 0)
        .padding(.trailing, 8)
    }

    var body: some View {
        HStack(spacing: 0) {
            centerSection
            rightSection
        }
        .frame(height: menuBarHeight)
        .background(Color.black)
        .mask {
            NotchShape(cornerRadius: 10)
        }
        .clipped()
        .onHover { hovering in
            isHovering = hovering
        }
        .opacity(windowManager.isVisible ? 1 : 0)
        .animation(.interactiveSpring, value: windowManager.isVisible)
    }
}
