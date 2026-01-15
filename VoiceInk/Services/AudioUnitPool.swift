import Foundation
import CoreAudio
import AudioToolbox
import os

/// Manages a pool of pre-warmed AudioUnits for near-instant recording startup.
///
/// The main latency when starting microphone recording comes from:
/// 1. Creating the AudioUnit component
/// 2. Configuring properties
/// 3. AudioUnitInitialize() - which wakes up hardware
///
/// By doing this work ahead of time at app launch, we can reduce recording
/// startup latency from ~1-2 seconds to ~10-50ms.
final class AudioUnitPool {

    static let shared = AudioUnitPool()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioUnitPool")
    private let lock = NSLock()

    /// A pre-warmed AudioUnit ready for immediate use
    private var warmUnit: AudioUnit?

    /// The device ID the warm unit is configured for
    private var warmDeviceID: AudioDeviceID = 0

    /// Device format cached from the warm unit
    private(set) var cachedDeviceFormat: AudioStreamBasicDescription?

    /// Whether warm-up is in progress
    private var isWarmingUp = false

    private init() {}

    // MARK: - Public Interface

    /// Warms up an AudioUnit for the specified device.
    /// Call this at app launch to pre-warm the audio hardware.
    func warmUp(forDevice deviceID: AudioDeviceID) {
        lock.lock()
        defer { lock.unlock() }

        guard !isWarmingUp else {
            logger.debug("Warm-up already in progress, skipping")
            return
        }

        isWarmingUp = true

        // Clean up existing warm unit if any
        if let existing = warmUnit {
            AudioComponentInstanceDispose(existing)
            warmUnit = nil
            warmDeviceID = 0
            cachedDeviceFormat = nil
        }

        guard deviceID != 0 else {
            logger.warning("No audio device available for warm-up")
            isWarmingUp = false
            return
        }

        logger.notice("🔥 Warming up AudioUnit for device \(deviceID)")

        do {
            let unit = try createAndConfigureUnit(forDevice: deviceID)

            // Initialize the unit - this is the slow part that wakes up hardware
            let status = AudioUnitInitialize(unit)
            if status != noErr {
                logger.error("Failed to initialize warm AudioUnit: \(status)")
                AudioComponentInstanceDispose(unit)
                isWarmingUp = false
                return
            }

            warmUnit = unit
            warmDeviceID = deviceID

            logger.notice("🔥 AudioUnit warmed up successfully for device \(deviceID)")

        } catch {
            logger.error("Failed to warm up AudioUnit: \(error.localizedDescription)")
        }

        isWarmingUp = false
    }

    /// Claims a pre-warmed AudioUnit for use. Returns nil if none available or device mismatch.
    /// After claiming, the pool will begin warming up a replacement in the background.
    func claimWarmUnit(forDevice deviceID: AudioDeviceID) -> (unit: AudioUnit, format: AudioStreamBasicDescription)? {
        lock.lock()
        defer { lock.unlock() }

        guard let unit = warmUnit, warmDeviceID == deviceID, let format = cachedDeviceFormat else {
            logger.debug("No warm unit available for device \(deviceID) (have: \(self.warmDeviceID))")
            return nil
        }

        // Transfer ownership
        warmUnit = nil
        let claimedDevice = warmDeviceID
        let claimedFormat = format
        warmDeviceID = 0
        cachedDeviceFormat = nil

        logger.notice("🔥 Claimed warm AudioUnit for device \(claimedDevice)")

        return (unit, claimedFormat)
    }

    /// Returns a warm unit that wasn't used (e.g., if recording was cancelled before start).
    func returnUnusedUnit(_ unit: AudioUnit, deviceID: AudioDeviceID, format: AudioStreamBasicDescription) {
        lock.lock()
        defer { lock.unlock() }

        // If we don't have a warm unit, keep this one
        if warmUnit == nil {
            warmUnit = unit
            warmDeviceID = deviceID
            cachedDeviceFormat = format
            logger.debug("Returned unused unit to pool")
        } else {
            // Already have one, dispose this
            AudioComponentInstanceDispose(unit)
            logger.debug("Disposed returned unit (pool already has one)")
        }
    }

    /// Schedules warming up a replacement unit after a recording completes.
    /// Call this after stopRecording() to prepare for the next recording.
    func scheduleRewarm(forDevice deviceID: AudioDeviceID) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.warmUp(forDevice: deviceID)
        }
    }

    /// Invalidates the warm unit if the device changes.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }

        if let unit = warmUnit {
            AudioComponentInstanceDispose(unit)
            warmUnit = nil
            warmDeviceID = 0
            cachedDeviceFormat = nil
            logger.debug("Invalidated warm unit due to device change")
        }
    }

    /// Check if we have a warm unit ready for the given device
    func hasWarmUnit(forDevice deviceID: AudioDeviceID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return warmUnit != nil && warmDeviceID == deviceID
    }

    // MARK: - Private

    private func createAndConfigureUnit(forDevice deviceID: AudioDeviceID) throws -> AudioUnit {
        // Find HAL Output component
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioUnitPoolError.componentNotFound
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            throw AudioUnitPoolError.failedToCreate(status: status)
        }

        // Enable input on element 1
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        if status != noErr {
            AudioComponentInstanceDispose(audioUnit)
            throw AudioUnitPoolError.failedToEnableInput(status: status)
        }

        // Disable output on element 0
        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        if status != noErr {
            AudioComponentInstanceDispose(audioUnit)
            throw AudioUnitPoolError.failedToDisableOutput(status: status)
        }

        // Set input device
        var device = deviceID
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            AudioComponentInstanceDispose(audioUnit)
            throw AudioUnitPoolError.failedToSetDevice(status: status)
        }

        // Get device format
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var deviceFormat = AudioStreamBasicDescription()
        status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &deviceFormat,
            &formatSize
        )
        if status != noErr {
            AudioComponentInstanceDispose(audioUnit)
            throw AudioUnitPoolError.failedToGetFormat(status: status)
        }

        // Set callback format (Float32 for processing)
        var callbackFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size) * deviceFormat.mChannelsPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size) * deviceFormat.mChannelsPerFrame,
            mChannelsPerFrame: deviceFormat.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &callbackFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        if status != noErr {
            AudioComponentInstanceDispose(audioUnit)
            throw AudioUnitPoolError.failedToSetFormat(status: status)
        }

        // Cache the format
        cachedDeviceFormat = deviceFormat

        logger.debug("Created warm unit: \(deviceFormat.mSampleRate)Hz, \(deviceFormat.mChannelsPerFrame)ch")

        return audioUnit
    }
}

// MARK: - Errors

enum AudioUnitPoolError: LocalizedError {
    case componentNotFound
    case failedToCreate(status: OSStatus)
    case failedToDisableOutput(status: OSStatus)
    case failedToEnableInput(status: OSStatus)
    case failedToGetFormat(status: OSStatus)
    case failedToSetDevice(status: OSStatus)
    case failedToSetFormat(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .componentNotFound:
            return "HAL Output component not found"
        case .failedToCreate(let status):
            return "Failed to create AudioUnit: \(status)"
        case .failedToDisableOutput(let status):
            return "Failed to disable output: \(status)"
        case .failedToEnableInput(let status):
            return "Failed to enable input: \(status)"
        case .failedToGetFormat(let status):
            return "Failed to get device format: \(status)"
        case .failedToSetDevice(let status):
            return "Failed to set device: \(status)"
        case .failedToSetFormat(let status):
            return "Failed to set format: \(status)"
        }
    }
}
