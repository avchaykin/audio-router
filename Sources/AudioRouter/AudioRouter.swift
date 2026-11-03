import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import Combine
import Synchronization

/// One effect in the chain.
@MainActor
final class EffectSlot: ObservableObject, Identifiable {
    let id = UUID()
    let unit: AVAudioUnit
    let name: String
    let manufacturer: String

    @Published var isEnabled: Bool {
        didSet { unit.auAudioUnit.shouldBypassEffect = !isEnabled }
    }

    init(unit: AVAudioUnit, name: String, manufacturer: String, enabled: Bool) {
        self.unit = unit
        self.name = name
        self.manufacturer = manufacturer
        self.isEnabled = enabled
        unit.auAudioUnit.shouldBypassEffect = !enabled
    }
}

private struct SavedSlot: Codable {
    var type: UInt32
    var subType: UInt32
    var manufacturer: UInt32
    var name: String
    var maker: String
    var enabled: Bool
    var state: Data?
}

/// Owns the audio graph: capture (system tap or input device) -> ring buffer -> source nodes
/// -> [effects...] / dry -> main mixer -> selected output device.
@MainActor
final class AudioRouter: ObservableObject {
    @Published private(set) var slots: [EffectSlot] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Stopped"
    @Published private(set) var availableEffects: [AVAudioUnitComponent] = []
    @Published var outputVolume: Float = 1 {
        didSet { engine.mainMixerNode.outputVolume = outputVolume; savePrefs() }
    }
    /// 0 = dry only, 1 = processed only.
    @Published var mix: Float = 1 {
        didSet { applyMix(); savePrefs() }
    }
    @Published private(set) var inputLevel: Float = 0    // peak, linear
    @Published private(set) var outputLevel: Float = 0   // peak, linear
    @Published private(set) var latencyMs: Double = 0
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var driverInstalled = false
    @Published var inputSource: CaptureSource = .systemAudio {
        didSet { guard inputSource != oldValue else { return }; savePrefs(); restart() }
    }
    /// nil = follow the system default output.
    @Published var outputUID: String? = nil {
        didSet { guard outputUID != oldValue else { return }; savePrefs(); refreshDeviceInfo(); restart() }
    }

    // Latency-related settings (nil = automatic / device default). Changes restart processing.
    @Published var sampleRateSetting: Double? = nil {
        didSet { guard sampleRateSetting != oldValue else { return }; savePrefs(); restart() }
    }
    @Published var bufferSetting: Int? = nil {
        didSet { guard bufferSetting != oldValue else { return }; savePrefs(); restart() }
    }
    @Published var safetySetting: Int? = nil {
        didSet { guard safetySetting != oldValue else { return }; savePrefs(); restart() }
    }
    /// What the current output device offers.
    @Published private(set) var availableSampleRates: [Double] = []
    @Published private(set) var bufferRange: ClosedRange<Int> = 15...4096
    @Published private(set) var deviceSampleRate: Double = 0
    @Published private(set) var deviceBufferFrames = 0
    /// Values in effect while running.
    @Published private(set) var activeBufferFrames = 0
    @Published private(set) var activeSafetyFrames = 0
    @Published private(set) var latencyBreakdown: (input: Double, safety: Double, output: Double) = (0, 0, 0)
    @Published private(set) var dropouts = 0

    /// Input + safety buffer + output + plug-ins, in ms (0 when stopped).
    var estimatedLatencyMs: Double {
        guard isRunning else { return 0 }
        return latencyBreakdown.input + latencyBreakdown.safety + latencyBreakdown.output + latencyMs
    }

    static let bufferChoices = [32, 64, 128, 256, 512, 1024, 2048]
    static let safetyChoices = [64, 128, 256, 512, 1024, 2048, 4096]

    /// Automatic safety buffer: enough to absorb the scheduling jitter between capture and playback.
    static func autoSafety(buffer: Int) -> Int { max(256, buffer * 2) }

    var inputDevices: [AudioDevice] { devices.filter { $0.inputChannels > 0 } }
    /// The virtual device is never offered as an output: it would feed straight back into itself.
    var outputDevices: [AudioDevice] { devices.filter { $0.outputChannels > 0 && !$0.isVirtualRouter } }
    var virtualDevice: AudioDevice? { devices.first(where: \.isVirtualRouter) }

    private let engine = AVAudioEngine()
    private let ring = StereoRingBuffer()
    private var source: AVAudioSourceNode!
    private var drySource: AVAudioSourceNode!
    private let wetMixer = AVAudioMixerNode()
    private let dryMixer = AVAudioMixerNode()
    private let outputPeak = PeakHold()
    private var meterTimer: Timer?
    private var debugLog: FileHandle?
    private var format: AVAudioFormat!
    private var capture: AudioCapture?
    private var observers: [NSObjectProtocol] = []
    private var lastStart = Date.distantPast
    private var restoring = false
    private var loadingPrefs = false
    private static let chainKey = "effectChain"

    init() {
        let defaults = UserDefaults.standard
        loadingPrefs = true   // assignments below run didSet; don't save half-loaded prefs
        if defaults.object(forKey: "mix") != nil { mix = defaults.float(forKey: "mix") }
        if defaults.object(forKey: "outputVolume") != nil { outputVolume = defaults.float(forKey: "outputVolume") }
        if let key = defaults.string(forKey: "inputSource") { inputSource = CaptureSource(storageKey: key) }
        outputUID = defaults.string(forKey: "outputUID")
        if defaults.object(forKey: "sampleRate") != nil { sampleRateSetting = defaults.double(forKey: "sampleRate") }
        if defaults.object(forKey: "bufferFrames") != nil { bufferSetting = defaults.integer(forKey: "bufferFrames") }
        if defaults.object(forKey: "safetyFrames") != nil { safetySetting = defaults.integer(forKey: "safetyFrames") }
        loadingPrefs = false
        refreshDevices()

        engine.attach(wetMixer)
        engine.attach(dryMixer)
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        makeSource(sampleRate: rate > 0 ? rate : 48_000)
        rewire()
        installOutputMeter()
        refreshAvailableEffects()
        observeSystem()
        restoreChain()
        startMeterTimer()

        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--log"), i + 1 < args.count {
            FileManager.default.createFile(atPath: args[i + 1], contents: nil)
            debugLog = FileHandle(forWritingAtPath: args[i + 1])
        }
        if args.contains("--autostart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }
        }
    }

    // MARK: - Transport

    func setRunning(_ run: Bool) { run ? start() : stop() }

    func start() {
        guard !isRunning else { return }

        // Reading an input device (including the virtual one) needs microphone permission.
        if case .device = inputSource {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined:
                status = "Waiting for microphone permission…"
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        if granted { self.start() } else { self.status = "Microphone access denied" }
                    }
                }
                return
            default:
                status = "Microphone access denied — allow it in System Settings ▸ Privacy & Security ▸ Microphone"
                return
            }
        }

        lastStart = Date()
        do {
            let device = try resolveOutputDevice()

            // Sample rate: set on the output device (it clocks everything); wait for it to settle.
            if let rate = sampleRateSetting, AudioDevice.availableSampleRates(device).contains(rate),
               AudioDevice.nominalSampleRate(device) != rate {
                AudioDevice.setNominalSampleRate(device, rate)
                let deadline = Date().addingTimeInterval(1)
                while AudioDevice.nominalSampleRate(device) != rate && Date() < deadline { usleep(20_000) }
            }

            try setEngineOutput(device)
            let range = AudioDevice.bufferFrameSizeRange(device)
            if let frames = bufferSetting, let unit = engine.outputNode.audioUnit {
                var size = UInt32(min(max(frames, range.lowerBound), range.upperBound))
                AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                     &size, UInt32(MemoryLayout<UInt32>.size))
            }
            let buffer = bufferSetting.map { min(max($0, range.lowerBound), range.upperBound) }
                ?? AudioDevice.bufferFrameSize(device)
            let safety = safetySetting ?? Self.autoSafety(buffer: buffer)
            ring.configure(targetFill: safety, maxFill: safety + 2 * buffer + 512)

            let deviceRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            if deviceRate > 0, deviceRate != format.sampleRate { makeSource(sampleRate: deviceRate); rewire() }

            ring.reset()
            engine.prepare()
            try engine.start()   // must run first so our process has an audio object to exclude from the tap

            var capture = AudioCapture(ring: ring)
            try capture.start(source: inputSource, outputDevice: device, bufferFrames: bufferSetting)
            if capture.sampleRate > 0, capture.sampleRate != format.sampleRate {
                // Capture rate disagrees with what we assumed: rebuild the source nodes at its rate.
                capture.stop(); engine.stop()
                makeSource(sampleRate: capture.sampleRate); rewire()
                ring.reset()
                try engine.start()
                capture = AudioCapture(ring: ring)
                try capture.start(source: inputSource, outputDevice: device, bufferFrames: bufferSetting)
            }
            self.capture = capture
            isRunning = true
            let msPerFrame = 1000 / format.sampleRate
            activeBufferFrames = AudioDevice.bufferFrameSize(device)
            activeSafetyFrames = ring.targetFill
            latencyBreakdown = (
                input: Double(capture.inputLatencyFrames) * msPerFrame,
                safety: Double(ring.targetFill) * msPerFrame,
                output: Double(AudioDevice.fixedLatency(device, scope: kAudioObjectPropertyScopeOutput) + activeBufferFrames) * msPerFrame
            )
            dropouts = 0
            dropoutBase = 0
            refreshDeviceInfo()
            status = "\(inputName) → \(deviceName(device)) @ \(Int(format.sampleRate)) Hz"
        } catch {
            capture?.stop(); capture = nil
            engine.stop()
            isRunning = false
            status = "Error: \(error.localizedDescription)"
        }
    }

    func stop() {
        capture?.stop()
        capture = nil
        engine.stop()
        isRunning = false
        status = "Stopped"
    }

    private func restart() {
        guard isRunning else { return }
        stop()
        start()
    }

    var inputSummary: String { inputName }

    var outputSummary: String {
        guard let outputUID else { return "System Default" }
        return devices.first(where: { $0.uid == outputUID })?.name ?? "Unavailable"
    }

    private var inputName: String {
        switch inputSource {
        case .systemAudio: "System audio"
        case .device(let uid): devices.first(where: { $0.uid == uid })?.name ?? "Input"
        }
    }

    private func resolveOutputDevice() throws -> AudioDeviceID {
        if let outputUID {
            guard let device = AudioDevice.lookup(uid: outputUID) else {
                throw RouterError("The selected output device is not connected")
            }
            return device
        }
        let device = try defaultOutputDevice()
        if (try? deviceUID(device)) == AudioDevice.virtualUID {
            throw RouterError("The system output is set to the Audio Router virtual device — choose a real output device in Audio Router")
        }
        return device
    }

    // MARK: - Devices & virtual driver

    func refreshDevices() {
        devices = AudioDevice.all()
        refreshDeviceInfo()
        driverInstalled = FileManager.default.fileExists(atPath: Self.installedDriverPath)
    }

    /// Rates / buffer range / current values of the output device (for the settings window).
    func refreshDeviceInfo() {
        guard let device = try? resolveOutputDevice() else {
            availableSampleRates = []; deviceSampleRate = 0; deviceBufferFrames = 0
            return
        }
        availableSampleRates = AudioDevice.availableSampleRates(device)
        bufferRange = AudioDevice.bufferFrameSizeRange(device)
        deviceSampleRate = AudioDevice.nominalSampleRate(device)
        deviceBufferFrames = AudioDevice.bufferFrameSize(device)
    }

    func resetDropouts() {
        dropoutBase = ring.underruns + ring.skips
        dropouts = 0
    }
    private var dropoutBase = 0

    private static let installedDriverPath = "/Library/Audio/Plug-Ins/HAL/AudioRouterDriver.driver"

    func installDriver() { runDriverInstaller(uninstall: false) }
    func uninstallDriver() { runDriverInstaller(uninstall: true) }

    private func runDriverInstaller(uninstall: Bool) {
        guard let bundled = Bundle.main.url(forResource: "AudioRouterDriver", withExtension: "driver") else {
            status = "Driver not found in the app bundle — build with ./build.sh"
            return
        }
        func q(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let dest = q(Self.installedDriverPath)
        var command = "rm -rf \(dest)"
        if !uninstall {
            command += " && cp -R \(q(bundled.path)) \(dest) && chown -R root:wheel \(dest)"
        }
        command += " && killall coreaudiod"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")

        let wasRunning = isRunning
        stop()
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            status = "Driver \(uninstall ? "removal" : "installation") failed: \(error[NSAppleScript.errorMessage] ?? "cancelled")"
        } else {
            status = uninstall ? "Virtual device removed" : "Virtual device installed — select “Audio Router” as output in other apps"
        }
        // coreaudiod restarts asynchronously; give it a moment before touching devices again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.refreshDevices()
            if wasRunning { self.start() }
        }
    }

    // MARK: - Effect chain

    func refreshAvailableEffects() {
        let manager = AVAudioUnitComponentManager.shared()
        let types = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        availableEffects = types.flatMap { type in
            manager.components(matching: AudioComponentDescription(
                componentType: type, componentSubType: 0, componentManufacturer: 0,
                componentFlags: 0, componentFlagsMask: 0))
        }
        .sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
    }

    func addEffect(_ component: AVAudioUnitComponent) {
        Task {
            await add(description: component.audioComponentDescription, name: component.name,
                      maker: component.manufacturerName, enabled: true, state: nil)
            saveChain()
        }
    }

    private func add(description: AudioComponentDescription, name: String, maker: String,
                     enabled: Bool, state: [String: Any]?) async {
        do {
            let unit = try await AVAudioUnit.instantiate(with: description, options: [])
            if let state { unit.auAudioUnit.fullState = state }
            engine.attach(unit)
            slots.append(EffectSlot(unit: unit, name: name, manufacturer: maker, enabled: enabled))
            rewire()
        } catch {
            status = "Could not load \(name): \(error.localizedDescription)"
        }
    }

    func remove(_ slot: EffectSlot) {
        PluginWindowManager.shared.close(slot)
        slots.removeAll { $0.id == slot.id }
        rewire()
        engine.detach(slot.unit)
        saveChain()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        slots.move(fromOffsets: fromOffsets, toOffset: toOffset)
        rewire()
        saveChain()
    }

    func move(_ slot: EffectSlot, by delta: Int) {
        guard let i = slots.firstIndex(where: { $0.id == slot.id }) else { return }
        let j = i + delta
        guard slots.indices.contains(j) else { return }
        slots.swapAt(i, j)
        rewire()
        saveChain()
    }

    func setEnabled(_ slot: EffectSlot, _ enabled: Bool) {
        slot.isEnabled = enabled
        updateLatency()
        saveChain()
    }

    func openEditor(_ slot: EffectSlot) {
        PluginWindowManager.shared.open(slot)
    }

    // MARK: - Graph

    private func makeSource(sampleRate: Double) {
        for node in [source, drySource].compactMap({ $0 }) {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        source = makeSourceNode(format: format, dry: false)
        drySource = makeSourceNode(format: format, dry: true)
        engine.attach(source)
        engine.attach(drySource)
        self.format = format
    }

    private func makeSourceNode(format: AVAudioFormat, dry: Bool) -> AVAudioSourceNode {
        let ring = self.ring
        return AVAudioSourceNode(format: format) { isSilence, timestamp, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard let l = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let r = buffers.count > 1 ? buffers[1].mData!.assumingMemoryBound(to: Float.self) : l
            let t = Int(timestamp.pointee.mSampleTime)
            let n = Int(frameCount)
            let gotAudio = dry ? ring.readDry(sampleTime: t, left: l, right: r, frames: n)
                               : ring.read(sampleTime: t, left: l, right: r, frames: n)
            if !gotAudio { isSilence.pointee = true }
            return noErr
        }
    }

    /// Reconnects
    ///   source -> slots (in order) -> wetMixer -> main mixer (bus 0)
    ///   drySource (latency-aligned) -> dryMixer -> main mixer (bus 1)
    private func rewire() {
        let wasRunning = engine.isRunning
        if wasRunning { engine.pause() }

        for node in [source!, drySource!, wetMixer, dryMixer] as [AVAudioNode] { engine.disconnectNodeOutput(node) }
        for slot in slots { engine.disconnectNodeOutput(slot.unit) }

        var previous: AVAudioNode = source
        for slot in slots {
            engine.connect(previous, to: slot.unit, format: format)
            previous = slot.unit
        }
        engine.connect(previous, to: wetMixer, format: format)
        engine.connect(drySource, to: dryMixer, format: format)
        engine.connect(wetMixer, to: engine.mainMixerNode, fromBus: 0, toBus: 0, format: format)
        engine.connect(dryMixer, to: engine.mainMixerNode, fromBus: 0, toBus: 1, format: format)
        engine.mainMixerNode.outputVolume = outputVolume
        applyMix()
        updateLatency()

        if wasRunning {
            do { try engine.start() } catch { status = "Error restarting engine: \(error.localizedDescription)" }
        }
    }

    private func applyMix() {
        wetMixer.outputVolume = mix
        dryMixer.outputVolume = 1 - mix
    }

    /// Total reported plug-in latency; the dry path is delayed by the same amount.
    private func updateLatency() {
        let seconds = slots.reduce(0) { $0 + max(0, $1.unit.auAudioUnit.latency) }
        latencyMs = seconds * 1000
        ring.setDryDelay(Int((seconds * format.sampleRate).rounded()))
    }

    private func installOutputMeter() {
        let mixer = engine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [outputPeak] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            var peak: Float = 0
            for ch in 0..<Int(buffer.format.channelCount) {
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[ch][i])) }
            }
            outputPeak.note(peak)
        }
    }

    private func startMeterTimer() {
        var tick = 0
        var inHistory = [Float](repeating: 0, count: 4), outHistory = inHistory  // ~200 ms peak hold
        var inWindow: Float = 0, outWindow: Float = 0
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let input = self.ring.takeInputPeak()
                let output = self.outputPeak.take()
                inHistory[tick % 4] = input
                outHistory[tick % 4] = output
                inWindow = max(inWindow, input)
                outWindow = max(outWindow, output)
                // Peak hold, then ~20 dB/s fall-off.
                self.inputLevel = max(inHistory.max()!, self.inputLevel * 0.89)
                self.outputLevel = max(outHistory.max()!, self.outputLevel * 0.89)
                if self.isRunning {
                    let total = self.ring.underruns + self.ring.skips - self.dropoutBase
                    if total != self.dropouts { self.dropouts = total }
                }
                tick += 1
                if tick % 10 == 0 {
                    self.updateLatency()   // plug-ins may change latency with their settings
                    if let log = self.debugLog {
                        let line = String(format: "in=%.4f out=%.4f mix=%.2f vol=%.2f lat=%.2fms est=%.1fms buf=%d safety=%d drop=%d  %@\n",
                                          inWindow, outWindow, self.mix, self.outputVolume, self.latencyMs,
                                          self.estimatedLatencyMs, self.activeBufferFrames, self.activeSafetyFrames,
                                          self.dropouts, self.status)
                        log.write(line.data(using: .utf8)!)
                    }
                    inWindow = 0; outWindow = 0
                }
            }
        }
    }

    private func savePrefs() {
        guard !loadingPrefs else { return }
        UserDefaults.standard.set(mix, forKey: "mix")
        UserDefaults.standard.set(outputVolume, forKey: "outputVolume")
        UserDefaults.standard.set(inputSource.storageKey, forKey: "inputSource")
        UserDefaults.standard.set(outputUID, forKey: "outputUID")
        UserDefaults.standard.set(sampleRateSetting, forKey: "sampleRate")
        UserDefaults.standard.set(bufferSetting, forKey: "bufferFrames")
        UserDefaults.standard.set(safetySetting, forKey: "safetyFrames")
    }

    private func setEngineOutput(_ device: AudioDeviceID) throws {
        guard let unit = engine.outputNode.audioUnit else { return }
        var device = device
        try caCheck(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                         &device, UInt32(MemoryLayout<AudioDeviceID>.size)),
                    "Set output device")
    }

    // MARK: - System events

    private func observeSystem() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.lastStart) > 1 else { return }
                self.restart()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveChain()
                self?.stop()
                PluginWindowManager.shared.closeAll()
                // Some plug-ins crash in their own C++ static destructors when the process exits
                // (e.g. Arturia Rev INTENSITY calls std::terminate), which macOS then reports as an
                // unexpected quit. Everything worth keeping is saved and audio is stopped, so end the
                // process here without running library destructors.
                UserDefaults.standard.synchronize()
                _exit(0)
            }
        })

        let system = AudioObjectID(kAudioObjectSystemObject)
        var defaultOutput = caAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(system, &defaultOutput, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.outputUID == nil else { return }   // only matters when following the default
                self.restart()
            }
        }
        var deviceList = caAddress(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(system, &deviceList, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = Set(self.devices.map(\.uid))
                self.refreshDevices()
                let after = Set(self.devices.map(\.uid))
                // Restart if a device we depend on appeared or disappeared.
                var used: Set<String> = []
                if let uid = self.outputUID { used.insert(uid) }
                if case .device(let uid) = self.inputSource { used.insert(uid) }
                if !used.isDisjoint(with: before.symmetricDifference(after)) { self.restart() }
            }
        }
    }

    // MARK: - Persistence

    func saveChain() {
        guard !restoring else { return }
        let saved = slots.map { slot -> SavedSlot in
            let d = slot.unit.audioComponentDescription
            let state = slot.unit.auAudioUnit.fullState.flatMap {
                try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
            }
            return SavedSlot(type: d.componentType, subType: d.componentSubType, manufacturer: d.componentManufacturer,
                             name: slot.name, maker: slot.manufacturer, enabled: slot.isEnabled, state: state)
        }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.chainKey)
        }
    }

    private func restoreChain() {
        guard let data = UserDefaults.standard.data(forKey: Self.chainKey),
              let saved = try? JSONDecoder().decode([SavedSlot].self, from: data), !saved.isEmpty else { return }
        restoring = true
        Task {
            for s in saved {
                let desc = AudioComponentDescription(componentType: s.type, componentSubType: s.subType,
                                                     componentManufacturer: s.manufacturer,
                                                     componentFlags: 0, componentFlagsMask: 0)
                let state = s.state.flatMap {
                    try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
                }
                await add(description: desc, name: s.name, maker: s.maker, enabled: s.enabled, state: state)
            }
            restoring = false
        }
    }
}

struct RouterError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
