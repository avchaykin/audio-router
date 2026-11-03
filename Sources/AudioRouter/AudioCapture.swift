import AudioToolbox
import CoreAudio
import Foundation

enum CaptureSource: Hashable {
    /// Everything other apps play (process tap). The originals are muted while tapped.
    case systemAudio
    /// An input device, e.g. the Audio Router virtual device, BlackHole, or a microphone.
    case device(uid: String)

    var storageKey: String {
        switch self {
        case .systemAudio: "system"
        case .device(let uid): "device:" + uid
        }
    }

    init(storageKey: String) {
        if storageKey.hasPrefix("device:") { self = .device(uid: String(storageKey.dropFirst(7))) } else { self = .systemAudio }
    }
}

/// Captures a source into the ring buffer through a private aggregate device whose clock master is
/// the output device. Input devices are added with drift compensation, so capture and playback
/// can't drift apart.
final class AudioCapture {
    private let ring: StereoRingBuffer
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var sampleRate: Double = 0
    /// Capture-side latency in frames (aggregate input latency + I/O buffer), valid after start.
    private(set) var inputLatencyFrames = 0

    init(ring: StereoRingBuffer) { self.ring = ring }

    deinit { stop() }

    func start(source: CaptureSource, outputDevice: AudioDeviceID, bufferFrames: Int?) throws {
        do {
            try startThrowing(source: source, outputDevice: outputDevice, bufferFrames: bufferFrames)
        } catch {
            stop()
            throw error
        }
    }

    private func startThrowing(source: CaptureSource, outputDevice: AudioDeviceID, bufferFrames: Int?) throws {
        let outputUID = try deviceUID(outputDevice)
        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: outputUID]]
        var taps: [[String: Any]] = []
        // The aggregate's input buffers start with the output device's own input streams (if it has any);
        // our source comes after them — unless the source *is* the output device.
        var skipBuffers = AudioDevice.streamCount(outputDevice, scope: kAudioObjectPropertyScopeInput)

        switch source {
        case .systemAudio:
            // Exclude our own process, otherwise we'd tap (and mute) our own output -> feedback.
            let own = try processObject(for: getpid())
            guard own != kAudioObjectUnknown else {
                throw CoreAudioError(what: "Locate own audio process object", status: -1)
            }
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [own])
            description.uuid = UUID()
            description.name = "Audio Router Tap"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try caCheck(AudioHardwareCreateProcessTap(description, &tapID), "Create process tap")
            taps = [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]]

        case .device(let uid):
            guard let input = AudioDevice.lookup(uid: uid) else {
                throw CoreAudioError(what: "Find input device", status: -1)
            }
            if uid == outputUID {
                skipBuffers = 0
            } else {
                // Match rates so the aggregate doesn't have to deal with mismatched nominal rates.
                let rate = AudioDevice.nominalSampleRate(outputDevice)
                if rate > 0, AudioDevice.nominalSampleRate(input) != rate { AudioDevice.setNominalSampleRate(input, rate) }
                subDevices.append([kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: true])
            }
        }

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Audio Router Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]
        if !taps.isEmpty {
            aggregate[kAudioAggregateDeviceTapListKey] = taps
            aggregate[kAudioAggregateDeviceTapAutoStartKey] = true
        }
        try caCheck(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                    "Create aggregate device")
        sampleRate = AudioDevice.nominalSampleRate(aggregateID)
        if let bufferFrames {
            let range = AudioDevice.bufferFrameSizeRange(aggregateID)
            AudioDevice.setBufferFrameSize(aggregateID, min(max(bufferFrames, range.lowerBound), range.upperBound))
        }
        inputLatencyFrames = AudioDevice.fixedLatency(aggregateID, scope: kAudioObjectPropertyScopeInput)
            + AudioDevice.bufferFrameSize(aggregateID)

        let ring = self.ring
        let skip = skipBuffers
        try caCheck(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inInput, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            // Take the first two channels of the source, wherever they live (interleaved or not).
            var left: UnsafePointer<Float>?, right: UnsafePointer<Float>?
            var leftStride = 1, rightStride = 1, frames = 0, channel = 0
            var b = skip
            while b < buffers.count && channel < 2 {
                let buf = buffers[b]
                let n = Int(buf.mNumberChannels)
                if let data = buf.mData, n > 0 {
                    let base = UnsafePointer(data.assumingMemoryBound(to: Float.self))
                    if frames == 0 { frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * n) }
                    var c = 0
                    while c < n && channel < 2 {
                        if channel == 0 { left = base + c; leftStride = n } else { right = base + c; rightStride = n }
                        channel += 1; c += 1
                    }
                }
                b += 1
            }
            guard let left else { return }
            if right == nil { right = left; rightStride = leftStride }   // mono source
            ring.write(left: left, leftStride: leftStride, right: right!, rightStride: rightStride, frames: frames)
        }, "Create IOProc")

        try caCheck(AudioDeviceStart(aggregateID, ioProcID), "Start capture")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
