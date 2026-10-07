import AppKit
import Foundation
import SwiftData
import Testing
@testable import VoiceInk

@Suite(.serialized) @MainActor
struct RecordingDeliveryCancellationTests {
    @Test
    func lateProviderResultAfterCancelCannotInsertOrDismissANewSession() async throws {
        let fixture = try PipelineFixture()
        let canceled = RecordingCancellationState()
        let oldRecord = fixture.record()
        let oldSession = ControlledTranscriptionSession()
        let oldRun = Task { await fixture.run(oldRecord, cancellation: canceled, session: oldSession) }
        await oldSession.started.wait()
        canceled.cancel()

        let newCancellation = RecordingCancellationState()
        let newRecord = fixture.record()
        let newSession = ControlledTranscriptionSession()
        let newRun = Task { await fixture.run(newRecord, cancellation: newCancellation, session: newSession) }
        await newSession.started.wait()
        newSession.finish("new transcript")
        await newRun.value
        oldSession.finish("stale transcript")
        await oldRun.value

        #expect(oldRecord.transcriptionStatus == TranscriptionStatus.canceled.rawValue)
        #expect(newRecord.transcriptionStatus == TranscriptionStatus.completed.rawValue)
        #expect(fixture.deliveredTexts == ["new transcript"])
        #expect(fixture.dismissals == 1)
    }

    @Test
    func cancellationDuringDismissPreventsPendingPaste() async throws {
        let fixture = try PipelineFixture()
        let cancellation = RecordingCancellationState()
        let record = fixture.record()
        fixture.onDismiss = { cancellation.cancel() }
        let session = ControlledTranscriptionSession()
        let run = Task { await fixture.run(record, cancellation: cancellation, session: session) }
        await session.started.wait()
        session.finish("discard this")
        await run.value

        #expect(fixture.deliveredTexts.isEmpty)
        #expect(record.transcriptionStatus == TranscriptionStatus.canceled.rawValue)
    }

    @Test
    func normalCompletionInsertsExactlyOnce() async throws {
        let fixture = try PipelineFixture()
        let record = fixture.record()
        let session = ControlledTranscriptionSession()
        let run = Task { await fixture.run(record, cancellation: RecordingCancellationState(), session: session) }
        await session.started.wait()
        session.finish("ordinary transcript")
        await run.value

        #expect(record.transcriptionStatus == TranscriptionStatus.completed.rawValue)
        #expect(fixture.deliveredTexts == ["ordinary transcript"])
        #expect(fixture.dismissals == 1)
    }

    @Test
    func typingDuringPrePasteDelayRestoresClipboardAndDoesNotPostPaste() async {
        let cancellation = RecordingCancellationState()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("previous clipboard", forType: .string)
        var posted = 0
        let task = Task {
            await CursorPaster.performPasteSession(
                "pending transcript",
                pasteboard: pasteboard,
                postPasteCommand: { posted += 1; return .commandPosted },
                shouldCancel: { cancellation.isCancelled }
            )
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while pasteboard.string(forType: .string) == "previous clipboard", ContinuousClock.now < deadline { await Task.yield() }
        cancellation.cancel()
        let outcome = await task.value

        #expect(outcome.result == .commandNotPosted)
        #expect(posted == 0)
        #expect(pasteboard.string(forType: .string) == "previous clipboard")
    }

    @Test
    func canceledPasteDoesNotOverwriteANewerClipboardOwner() async {
        let cancellation = RecordingCancellationState()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("previous", forType: .string)
        let task = Task {
            await CursorPaster.performPasteSession(
                "pending", pasteboard: pasteboard,
                postPasteCommand: { Issue.record("Canceled paste must not post a command"); return .commandPosted },
                shouldCancel: { cancellation.isCancelled }
            )
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while pasteboard.string(forType: .string) == "previous", ContinuousClock.now < deadline { await Task.yield() }
        pasteboard.clearContents()
        pasteboard.setString("copied by another app", forType: .string)
        cancellation.cancel()
        _ = await task.value
        #expect(pasteboard.string(forType: .string) == "copied by another app")
    }

    @Test
    func cancellationAfterPasteSuppressesAutomaticSend() async {
        let cancellation = RecordingCancellationState()
        var sends: [FinishAndSendKey] = []
        let delivery = TranscriptionDelivery(
            pasteAtCursor: { _, _ in
                cancellation.cancel()
                return .init(result: .commandPosted, autoLearnGeneration: nil)
            },
            selectedSendKey: { .enter },
            sendKey: { sends.append($0) }
        )
        let record = Transcription(text: "message", duration: 1, transcriptionStatus: .completed)
        await delivery.deliver(
            .init(transcription: record, text: "message", output: .init(mode: nil, outputMode: .paste, customCommand: nil), responseConfig: nil, responseError: nil, isAssistantFollowUp: false, sendAfterPaste: true),
            actions: .init(setState: { _ in }, dismiss: {}, sendFollowUp: { _, _ in }, showResponse: { _, _ in }, failResponse: { _ in }, shouldCancel: { cancellation.isCancelled })
        )
        #expect(sends.isEmpty)
    }

    @Test
    func alreadyCanceledCustomCommandCannotLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("unexpected-output")
        let ready = TestSignal()
        let start = TestSignal()
        let task = Task {
            ready.finish()
            await start.wait()
            return try await CustomCommandDeliveryRunner.run(
                command: "touch '\(output.path)'",
                timeout: 5,
                context: .init(transcript: "discard")
            )
        }
        await ready.wait()
        task.cancel()
        start.finish()
        do {
            _ = try await task.value
            Issue.record("An already canceled command must not launch")
        } catch is CancellationError {
        } catch { Issue.record("Unexpected cancellation error: \(error)") }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test
    func cancellationStopsAnOwnedCustomCommandBeforeDelayedOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        let output = directory.appendingPathComponent("late-output")
        let task = Task {
            try await CustomCommandDeliveryRunner.run(
                command: "touch '\(ready.path)'; sleep 2; touch '\(output.path)'",
                timeout: 5,
                context: .init(transcript: "discard")
            )
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline { await Task.yield() }
        try #require(FileManager.default.fileExists(atPath: ready.path))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Canceled custom command must report cancellation")
        } catch is CancellationError {
        } catch { Issue.record("Unexpected cancellation error: \(error)") }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}

@MainActor
private final class PipelineFixture {
    private let container: ModelContainer
    let context: ModelContext
    var deliveredTexts: [String] = []
    var dismissals = 0
    private let mode = ModeConfig(name: "Cancellation test", isAIEnhancementEnabled: false)
    private let model = NativeAppleModel(name: "test", displayName: "Test", description: "Test", isMultilingualModel: false, supportedLanguages: ["en": "English"])
    var onDismiss: () -> Void = {}
    private let provider = EmptyWhisperModelProvider()

    init() throws {
        container = try ModelContainer(
            for: Transcription.self, WordReplacement.self, SessionMetric.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    func record() -> Transcription {
        let record = Transcription(text: "", duration: 1, transcriptionStatus: .pending)
        context.insert(record)
        return record
    }

    func run(_ record: Transcription, cancellation: RecordingCancellationState, session: TranscriptionSession) async {
        let registry = TranscriptionServiceRegistry(modelProvider: provider, modelsDirectory: FileManager.default.temporaryDirectory, modelContext: context)
        let delivery = TranscriptionDelivery(pasteAtCursor: { [self] text, shouldCancel in
            if !shouldCancel() { deliveredTexts.append(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return .init(result: .commandPosted, autoLearnGeneration: nil)
        })
        let pipeline = TranscriptionPipeline(modelContext: context, serviceRegistry: registry, enhancementService: nil, delivery: delivery)
        await pipeline.run(
            transcription: record,
            audioURL: FileManager.default.temporaryDirectory.appendingPathComponent("missing-test-audio.wav"),
            transcriptionConfiguration: .init(mode: mode, model: model, language: "en", isRealtimeEnabled: false),
            formattingConfiguration: { .init(mode: nil, isTextFormattingEnabled: false) },
            session: session,
            enhancementConfiguration: { nil },
            outputConfiguration: { .init(mode: nil, outputMode: .paste, customCommand: nil) },
            onStateChange: { _ in },
            shouldCancel: { cancellation.isCancelled },
            onCancel: { session.cancel() },
            onDismiss: { [self] in dismissals += 1; onDismiss() }
        )
    }
}

@MainActor
private final class ControlledTranscriptionSession: TranscriptionSession {
    private var continuation: CheckedContinuation<String, Error>?
    let started = TestSignal()

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? { nil }
    func transcribe(audioURL: URL) async throws -> String {
        try await withCheckedThrowingContinuation {
            continuation = $0
            started.finish()
        }
    }
    func cancel() {}
    func finish(_ text: String) {
        continuation?.resume(returning: text)
        continuation = nil
    }
}

@MainActor
private final class EmptyWhisperModelProvider: WhisperModelProvider {
    let availableModels: [WhisperModelFile] = []
    let isModelLoaded = false
    let loadedWhisperModel: WhisperModelFile? = nil
    let whisperContext: WhisperContext? = nil
}
