import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let what: String
    let status: OSStatus
    var errorDescription: String? { "\(what) failed (OSStatus \(status))" }
}

@inline(__always)
func caCheck(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CoreAudioError(what: what, status: status) }
}

func caAddress(_ selector: AudioObjectPropertySelector,
               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func caGet<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
    var address = caAddress(selector)
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    try caCheck(status, "Get property \(selector)")
    return value
}

func defaultOutputDevice() throws -> AudioDeviceID {
    try caGet(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
              initial: AudioDeviceID(kAudioObjectUnknown))
}

func deviceUID(_ device: AudioDeviceID) throws -> String {
    var address = caAddress(kAudioDevicePropertyDeviceUID)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var uid: Unmanaged<CFString>?
    try caCheck(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid), "Get device UID")
    guard let uid else { throw CoreAudioError(what: "Get device UID", status: -1) }
    return uid.takeRetainedValue() as String
}

func deviceName(_ device: AudioDeviceID) -> String {
    var address = caAddress(kAudioObjectPropertyName)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var name: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return "?" }
    return name.takeRetainedValue() as String
}

func processObject(for pid: pid_t) throws -> AudioObjectID {
    var address = caAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pid = pid
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try caCheck(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                           UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                "Translate PID to process object")
    return object
}

struct AudioDevice: Identifiable, Hashable {
    static let virtualUID = "AudioRouterVirtualDevice_UID"

    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int

    var isVirtualRouter: Bool { uid == Self.virtualUID }

    static func all() -> [AudioDevice] {
        var address = caAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = try? deviceUID(id) else { return nil }
            return AudioDevice(id: id, uid: uid, name: deviceName(id),
                               inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
                               outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = caAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func streamCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = caAddress(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    static func lookup(uid: String) -> AudioDeviceID? {
        var address = caAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        (try? caGet(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0
    }

    static func setNominalSampleRate(_ id: AudioDeviceID, _ rate: Double) {
        var address = caAddress(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(rate)
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
    }
}
