import SwiftUI
import AVFoundation

@main
struct AudioRouterApp: App {
    @StateObject private var router = AudioRouter()

    var body: some Scene {
        Window("Audio Router", id: "main") {
            ContentView()
                .environmentObject(router)
                .frame(minWidth: 520, minHeight: 400)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var router: AudioRouter

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if router.slots.isEmpty {
                ContentUnavailableView("No Effects", systemImage: "slider.horizontal.3",
                                       description: Text("Add an Audio Unit effect to start processing."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(router.slots.enumerated()), id: \.element.id) { index, slot in
                        SlotRow(slot: slot, index: index, count: router.slots.count)
                    }
                    .onMove { router.move(fromOffsets: $0, toOffset: $1) }
                }
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Toggle(isOn: Binding(get: { router.isRunning }, set: { router.setRunning($0) })) {
                    Text("Process System Audio").font(.headline)
                }
                .toggleStyle(.switch)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    LevelMeter(label: "In", level: router.inputLevel)
                    LevelMeter(label: "Out", level: router.outputLevel)
                }
            }
            RoutingControls()
            HStack(spacing: 8) {
                Text("Dry").font(.caption).foregroundStyle(.secondary)
                Slider(value: $router.mix, in: 0...1)
                    .help("Blend between the unprocessed (dry) and processed (wet) signal")
                Text("Wet").font(.caption).foregroundStyle(.secondary)
                Text("\(Int((router.mix * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
                Divider().frame(height: 16)
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: $router.outputVolume, in: 0...2)
                    .frame(width: 100)
                    .help("Output gain (up to +6 dB)")
                Text(String(format: "%+.1f dB", 20 * log10(max(router.outputVolume, 0.0001))))
                    .font(.caption.monospacedDigit())
                    .frame(width: 58, alignment: .trailing)
            }
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            if router.latencyMs > 0 {
                Text(String(format: "Plug-in latency %.1f ms (dry aligned)", router.latencyMs))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(router.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            VirtualDeviceMenu()
            AddEffectMenu()
        }
        .padding(12)
    }
}

struct AddEffectMenu: View {
    @EnvironmentObject var router: AudioRouter

    private var byManufacturer: [(String, [AVAudioUnitComponent])] {
        Dictionary(grouping: router.availableEffects, by: \.manufacturerName)
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        Menu {
            ForEach(byManufacturer, id: \.0) { maker, components in
                Menu(maker) {
                    ForEach(components, id: \.self) { component in
                        Button(component.name) { router.addEffect(component) }
                    }
                }
            }
            Divider()
            Button("Rescan Audio Units") { router.refreshAvailableEffects() }
        } label: {
            Label("Add Effect", systemImage: "plus")
        }
        .fixedSize()
    }
}

struct SlotRow: View {
    @EnvironmentObject var router: AudioRouter
    @ObservedObject var slot: EffectSlot
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            Toggle("", isOn: Binding(get: { slot.isEnabled }, set: { router.setEnabled(slot, $0) }))
                .labelsHidden()
                .help(slot.isEnabled ? "Bypass" : "Enable")
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.name).fontWeight(.medium)
                Text(slot.manufacturer).font(.caption).foregroundStyle(.secondary)
            }
            .opacity(slot.isEnabled ? 1 : 0.45)
            Spacer()
            Button { router.move(slot, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0).help("Move up")
            Button { router.move(slot, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == count - 1).help("Move down")
            Button("Edit…") { router.openEditor(slot) }
            Button { router.remove(slot) } label: { Image(systemName: "trash") }
                .help("Remove")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { router.openEditor(slot) }
        .contextMenu {
            Button("Open Editor") { router.openEditor(slot) }
            Button(slot.isEnabled ? "Bypass" : "Enable") { router.setEnabled(slot, !slot.isEnabled) }
            Divider()
            Button("Remove", role: .destructive) { router.remove(slot) }
        }
    }
}

struct LevelMeter: View {
    let label: String
    let level: Float  // linear peak

    private var db: Float { 20 * log10(max(level, 0.00001)) }
    private var fraction: CGFloat { CGFloat(max(0, min(1, (db + 60) / 60))) }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(db > -1 ? Color.red : db > -12 ? Color.yellow : Color.green)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(width: 120, height: 6)
            Text(level > 0.00001 ? String(format: "%.0f", db) : "-∞")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

struct RoutingControls: View {
    @EnvironmentObject var router: AudioRouter

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Input").font(.caption).foregroundStyle(.secondary)
                Picker("Input", selection: $router.inputSource) {
                    Text("System Audio (all apps)").tag(CaptureSource.systemAudio)
                    if let virtual = router.virtualDevice {
                        Text("\(virtual.name) (virtual device)").tag(CaptureSource.device(uid: virtual.uid))
                    }
                    Divider()
                    ForEach(router.inputDevices.filter { !$0.isVirtualRouter }) { device in
                        Text(device.name).tag(CaptureSource.device(uid: device.uid))
                    }
                    if case .device(let uid) = router.inputSource, !router.inputDevices.contains(where: { $0.uid == uid }) {
                        Text("Unavailable device").tag(router.inputSource)
                    }
                }
                .labelsHidden()
            }
            GridRow {
                Text("Output").font(.caption).foregroundStyle(.secondary)
                Picker("Output", selection: $router.outputUID) {
                    Text("System Default").tag(String?.none)
                    Divider()
                    ForEach(router.outputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                    if let uid = router.outputUID, !router.outputDevices.contains(where: { $0.uid == uid }) {
                        Text("Unavailable device").tag(String?.some(uid))
                    }
                }
                .labelsHidden()
            }
        }
    }
}

struct VirtualDeviceMenu: View {
    @EnvironmentObject var router: AudioRouter

    var body: some View {
        Menu {
            if router.driverInstalled {
                Text(router.virtualDevice != nil ? "“Audio Router” device is active" : "Installed, but not loaded")
                Button("Use as Input") {
                    if let v = router.virtualDevice { router.inputSource = .device(uid: v.uid) }
                }
                .disabled(router.virtualDevice == nil)
                Divider()
                Button("Reinstall Virtual Device…") { router.installDriver() }
                Button("Remove Virtual Device…") { router.uninstallDriver() }
            } else {
                Button("Install Virtual Device…") { router.installDriver() }
            }
        } label: {
            Label("Virtual Device", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .fixedSize()
        .help("A virtual “Audio Router” output that other apps can play into")
    }
}
