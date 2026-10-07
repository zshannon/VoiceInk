import Foundation
import os

@MainActor
final class TranscriptionDelivery {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionDelivery")
    private let pasteAtCursor: @MainActor (String, @escaping @MainActor () -> Bool) async -> CursorPaster.PasteOutcome
    private let selectedSendKey: @MainActor () -> FinishAndSendKey
    private let sendKey: @MainActor (FinishAndSendKey) -> Void

    init(
        pasteAtCursor: @escaping @MainActor (String, @escaping @MainActor () -> Bool) async -> CursorPaster.PasteOutcome = {
            text, shouldCancel in
            await CursorPaster.startPasteAtCursor(text, shouldCancel: shouldCancel).value
        },
        selectedSendKey: @escaping @MainActor () -> FinishAndSendKey = { FinishAndSendSettings.selectedKey },
        sendKey: @escaping @MainActor (FinishAndSendKey) -> Void = { CursorPaster.performSendKey($0) }
    ) {
        self.pasteAtCursor = pasteAtCursor
        self.selectedSendKey = selectedSendKey
        self.sendKey = sendKey
    }

    struct Request {
        let transcription: Transcription
        let text: String?
        let output: OutputRuntimeConfiguration
        let responseConfig: EnhancementRuntimeConfiguration?
        let responseError: String?
        let isAssistantFollowUp: Bool
        let sendAfterPaste: Bool
    }

    struct Actions {
        let setState: (RecordingState) -> Void
        let dismiss: () async -> Void
        let sendFollowUp: (String, Transcription) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void
        let shouldCancel: @MainActor () -> Bool
    }

    func deliver(_ request: Request, actions: Actions) async {
        guard !actions.shouldCancel() else { return }
        guard request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            await actions.dismiss()
            return
        }

        if request.isAssistantFollowUp {
            await deliverFollowUp(request, actions: actions)
            return
        }

        if request.output.outputMode == .respond,
            request.responseConfig != nil || request.responseError != nil
        {
            await deliverResponse(request, actions: actions)
            return
        }

        if request.output.outputMode == .customCommand {
            await deliverCustomCommand(request, actions: actions)
            return
        }

        if let text = request.text {
            await paste(text, sendAfterPaste: request.sendAfterPaste, actions: actions)
        } else {
            await actions.dismiss()
        }
    }

    private func deliverFollowUp(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return
        }

        actions.setState(.enhancing)
        await actions.sendFollowUp(text, item.transcription)
    }

    private func deliverResponse(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        if let responseError = item.responseError {
            await actions.failResponse("Enhancement failed: \(responseError)")
        } else if let text = item.text,
            item.responseConfig != nil
        {
            await actions.showResponse(text, item.transcription.aiRequestSystemMessage)
        } else {
            await actions.failResponse("No response was generated.")
        }
    }

    private func deliverCustomCommand(_ item: Request, actions: Actions) async {
        guard let text = item.text else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.noTextToDeliver)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        guard let customCommand = item.output.customCommand,
            let command = customCommand.trimmedCommand
        else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.commandNotConfigured)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        let commandText = deliverableText(from: text)
        let finishAndSendKey: FinishAndSendKey = item.sendAfterPaste ? selectedSendKey() : .none
        SoundManager.shared.playStopSound()
        await actions.dismiss()
        guard !actions.shouldCancel() else { return }
        await runCustomCommand(
            command: command,
            commandText: commandText,
            finishAndSendKey: finishAndSendKey,
            shouldCancel: actions.shouldCancel
        )
    }

    private func runCustomCommand(
        command: String, commandText: String, finishAndSendKey: FinishAndSendKey,
        shouldCancel: @MainActor () -> Bool
    ) async {
        guard !shouldCancel(), !Task.isCancelled else { return }
        let startTime = Date()
        logger.notice("Custom command started")

        do {
            let result = try await CustomCommandDeliveryRunner.run(
                command: command,
                timeout: 10,
                context: CustomCommandDeliveryContext(transcript: commandText)
            )

            let duration = Date().timeIntervalSince(startTime)
            let stdoutBytes = result.stdout.utf8.count
            let stderrBytes = result.stderr.utf8.count

            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command stdout bytes=\(stdoutBytes, privacy: .public): \(result.stdout, privacy: .public)")
            }

            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command succeeded with stderr duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public): \(result.stderr, privacy: .public)"
                )
            } else {
                logger.notice(
                    "Custom command succeeded duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public)"
                )
            }

            if finishAndSendKey.isEnabled {
                // Let the target app finish pasting before sending.
                try await Task.sleep(nanoseconds: 150_000_000)
                guard !shouldCancel(), !Task.isCancelled else { return }
                sendKey(finishAndSendKey)
            }
        } catch is CancellationError {
            logger.notice("Custom command canceled")
        } catch {
            guard !shouldCancel() else { return }
            notifyCustomCommandFailure(error, duration: Date().timeIntervalSince(startTime))
        }
    }

    private func notifyCustomCommandFailure(_ error: Error, duration: TimeInterval? = nil) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let duration {
            logger.error(
                "Custom command failed duration=\(Self.formattedDuration(duration), privacy: .public)s: \(message, privacy: .public)"
            )
        } else {
            logger.error("Custom command failed: \(message, privacy: .public)")
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration)
    }

    private func paste(_ text: String, sendAfterPaste: Bool, actions: Actions) async {
        let textToPaste = deliverableText(from: text)
        let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
        let pastedText = textToPaste + (appendSpace ? " " : "")
        SoundManager.shared.playStopSound()
        await actions.dismiss()
        guard !actions.shouldCancel() else { return }

        let pasteOutcome = await pasteAtCursor(pastedText, actions.shouldCancel)
        let selectedKey = selectedSendKey()
        let finishAndSendKey: FinishAndSendKey = sendAfterPaste ? selectedKey : .none
        if finishAndSendKey.isEnabled && pasteOutcome.result.didPostPasteCommand {
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch { return }
            guard !actions.shouldCancel() else { return }
            if let generation = pasteOutcome.autoLearnGeneration {
                await AutoLearnService.shared.cancelForAutoSend(generation: generation)
            }
            guard !actions.shouldCancel() else { return }
            sendKey(finishAndSendKey)
        }
    }

    private func deliverableText(from text: String) -> String {
        var textToDeliver = text
        if let restrictionMessage = LicenseViewModel.shared.usageRestrictionMessage {
            textToDeliver = """
                \(restrictionMessage)
                \n\(textToDeliver)
                """
        }

        return textToDeliver
    }
}
