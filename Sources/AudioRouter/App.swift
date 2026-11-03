import AVFoundation
import SwiftUI

@main
struct AudioRouterApp: App {
    @StateObject private var router = AudioRouter()
    @StateObject private var look = Appearance.shared

    init() {
        Theme.registerFonts()
    }

    var body: some Scene {
        Window("Audio Router", id: "main") {
            ContentView()
                .environmentObject(router)
                .environmentObject(look)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)   // the window follows the content (no empty space)

        Settings {
            SettingsView()
                .environmentObject(router)
                .environmentObject(look)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var router: AudioRouter
    @EnvironmentObject private var look: Appearance
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 12) {
            HeaderBar()

            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    InputSection()
                    OutputSection()
                    VirtualDeviceSection()   // stretches when the right column is taller
                }
                .frame(width: 300)

                VStack(spacing: 12) {
                    ChainSection()           // stretches when the left column is taller
                    MixSection()
                }
                .frame(width: 560)
            }
            // Height = the taller column's natural height; the other column stretches to match.
            .fixedSize(horizontal: false, vertical: true)

            StatusBar()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 6)
        .ignoresSafeArea(edges: .top)
        .font(Theme.mono(11.5))
        .foregroundStyle(Theme.text)
        .id(look.themeVersion)   // redraw everything when the appearance changes
        .frostedWindow()
        .onAppear {
            // debug / automation: open Settings at launch
            if ProcessInfo.processInfo.arguments.contains("--settings") { openSettings() }
            // debug / automation: write PNGs of all windows (works with the screen locked)
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { snapshotWindows(to: args[i + 1]) }
            }
        }
    }
}

/// Renders each visible window's content view into `<dir>/<title>.png`.
@MainActor private func snapshotWindows(to dir: String) {
    for window in NSApp.windows where window.isVisible {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
        view.cacheDisplay(in: view.bounds, to: rep)
        let name = window.title.isEmpty ? "window-\(window.windowNumber)" : window.title
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
}

// MARK: - Header

struct HeaderBar: View {
    @EnvironmentObject private var router: AudioRouter

    var body: some View {
        HStack(spacing: 12) {
            // room for the traffic-light buttons
            Color.clear.frame(width: 62, height: 1)

            HStack(spacing: 2) {
                Text("AUDIO").font(Theme.mono(15, .bold)).foregroundStyle(Theme.text)
                Text("ROUTER").font(Theme.mono(15, .medium)).foregroundStyle(Theme.glowSoft)
            }
            .padding(.trailing, 6)

            Button {
                router.setRunning(!router.isRunning)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "power").font(.system(size: 12, weight: .bold))
                    Text(router.isRunning ? "PROCESSING" : "STANDBY")
                        .font(Theme.mono(12, .bold))
                        .tracking(1)
                        .frame(width: 92, alignment: .leading)
                }
            }
            .buttonStyle(RubberButtonStyle(isOn: router.isRunning, radius: 9,
                                           padding: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)))
            .help("Start / stop processing")

            chip(router.inputSummary + "  →  " + router.outputSummary)

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                meterRow("IN", router.inputLevel)
                meterRow("OUT", router.outputLevel)
            }

            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(RubberButtonStyle(padding: EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)))
            .help("Settings (⌘,) — sample rate, buffers, appearance")
        }
        .frame(height: 34)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(11, .medium))
            .foregroundStyle(Theme.textDim)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line(0.15)))
    }

    private func meterRow(_ label: String, _ level: Float) -> some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.mono(9, .bold)).foregroundStyle(Theme.glowSoft).frame(width: 24, alignment: .trailing)
            LEDMeter(level: level).frame(width: 170)
            Text(level > 0.000_01 ? String(format: "%.0f", 20 * log10(level)) : "-∞")
                .font(Theme.mono(9.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textDim)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

// MARK: - Routing

struct InputSection: View {
    @EnvironmentObject private var router: AudioRouter

    var body: some View {
        Panel(title: "Input", icon: "arrow.down.to.line") {
            IconKey(symbol: "arrow.clockwise", help: "Rescan audio devices") { router.refreshDevices() }
        } content: {
            VStack(alignment: .leading, spacing: 5) {
                RadioRow(title: "System Audio", tag: "all apps", isOn: router.inputSource == .systemAudio) {
                    router.inputSource = .systemAudio
                }
                if let v = router.virtualDevice {
                    RadioRow(title: v.name, tag: "virt", isOn: router.inputSource == .device(uid: v.uid)) {
                        router.inputSource = .device(uid: v.uid)
                    }
                }
                ForEach(router.inputDevices.filter { !$0.isVirtualRouter }) { d in
                    RadioRow(title: d.name, isOn: router.inputSource == .device(uid: d.uid)) {
                        router.inputSource = .device(uid: d.uid)
                    }
                }
                if case .device(let uid) = router.inputSource, !router.inputDevices.contains(where: { $0.uid == uid }) {
                    RadioRow(title: "Unavailable device", tag: "offline", isOn: true) {}
                }
            }
        }
    }
}

struct OutputSection: View {
    @EnvironmentObject private var router: AudioRouter

    var body: some View {
        Panel(title: "Output", icon: "speaker.wave.2") {
            VStack(alignment: .leading, spacing: 5) {
                RadioRow(title: "System Default", isOn: router.outputUID == nil) { router.outputUID = nil }
                ForEach(router.outputDevices) { d in
                    RadioRow(title: d.name, isOn: router.outputUID == d.uid) { router.outputUID = d.uid }
                }
                if let uid = router.outputUID, !router.outputDevices.contains(where: { $0.uid == uid }) {
                    RadioRow(title: "Unavailable device", tag: "offline", isOn: true) {}
                }
            }
        }
    }
}

struct VirtualDeviceSection: View {
    @EnvironmentObject private var router: AudioRouter

    var body: some View {
        Panel(title: "Virtual Device", icon: "point.3.connected.trianglepath.dotted") {
            if router.driverInstalled {
                MiniButton("Reinstall") { router.installDriver() }
                MiniButton("Remove") { router.uninstallDriver() }
            } else {
                MiniButton("Install…", isOn: true) { router.installDriver() }
            }
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(router.virtualDevice != nil ? Theme.pass : Theme.textFaint)
                        .frame(width: 6, height: 6)
                        .shadow(color: router.virtualDevice != nil ? Theme.pass : .clear, radius: 3)
                    Text(router.virtualDevice != nil ? "“Audio Router” is active"
                         : router.driverInstalled ? "installed, not loaded" : "not installed")
                        .foregroundStyle(router.virtualDevice != nil ? Theme.text : Theme.textDim)
                }
                Text("Set an app's output to “Audio Router”, then pick it as input here.")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Effect chain

struct ChainSection: View {
    @EnvironmentObject private var router: AudioRouter
    @StateObject private var showAdd = LocalState(false)
    @StateObject private var dragging = LocalState<UUID?>(nil)
    @StateObject private var listHeight = LocalState<CGFloat>(0)

    /// The list grows with its rows up to this height, then scrolls.
    private let maxListHeight: CGFloat = 6 * 50 + 16

    var body: some View {
        Panel(title: "Effect Chain · \(router.slots.count)", icon: "square.stack.3d.up") {
            if router.latencyMs > 0 {
                Text(String(format: "latency %.1f ms", router.latencyMs))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textDim)
                    .help("Total plug-in latency; the dry signal is delayed to match")
                    .padding(.trailing, 4)
            }
            Button {
                showAdd.value = true
            } label: {
                Label("Add Effect", systemImage: "plus").font(Theme.mono(10.5, .medium))
            }
            .buttonStyle(RubberButtonStyle(isOn: router.slots.isEmpty, radius: 6,
                                           padding: EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)))
            .popover(isPresented: $showAdd.value, arrowEdge: .bottom) {
                AddEffectPopover { showAdd.value = false }.environmentObject(router)
            }
            .onAppear {
                // debug / automation: open the Add Effect popover at launch
                if ProcessInfo.processInfo.arguments.contains("--add-effect") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showAdd.value = true }
                }
            }
        } content: {
            if router.slots.isEmpty {
                Text("add an Audio Unit effect to start processing")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, minHeight: 64, idealHeight: 64, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well(0.28)))
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(router.slots.enumerated()), id: \.element.id) { index, slot in
                            SlotRow(slot: slot, index: index, count: router.slots.count)
                                .opacity(dragging.value == slot.id ? 0.4 : 1)
                                .onDrag {
                                    dragging.value = slot.id
                                    return NSItemProvider(object: slot.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: SlotDropDelegate(target: slot, router: router, dragging: dragging))
                        }
                    }
                    .padding(8)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ListHeightKey.self, value: g.size.height)
                    })
                }
                .onPreferenceChange(ListHeightKey.self) { listHeight.value = $0 }
                .scrollIndicators(.automatic)
                .frame(minHeight: 64, idealHeight: min(max(listHeight.value, 64), maxListHeight), maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well(0.28)))
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Moves the dragged slot to the drop target's position (one rewire per drop).
struct SlotDropDelegate: DropDelegate {
    let target: EffectSlot
    let router: AudioRouter
    let dragging: LocalState<UUID?>

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging.value = nil }
        guard let id = dragging.value, id != target.id,
              let from = router.slots.firstIndex(where: { $0.id == id }),
              let to = router.slots.firstIndex(where: { $0.id == target.id }) else { return false }
        router.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        return true
    }
}

struct SlotRow: View {
    @EnvironmentObject private var router: AudioRouter
    @ObservedObject var slot: EffectSlot
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
                .help("Drag to reorder")
            Text("\(index + 1)")
                .font(Theme.mono(12, .bold))
                .glowText(slot.isEnabled)
                .frame(width: 18)
            Button {
                router.setEnabled(slot, !slot.isEnabled)
            } label: {
                GlowCheckbox(isOn: slot.isEnabled, size: 16)
            }
            .buttonStyle(.plain)
            .help(slot.isEnabled ? "Bypass" : "Enable")

            VStack(alignment: .leading, spacing: 1) {
                Text(slot.name).font(Theme.mono(12, .semibold)).glowText(slot.isEnabled).lineLimit(1)
                Text(slot.manufacturer).font(Theme.mono(9.5)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Spacer(minLength: 8)

            IconKey(symbol: "chevron.up", help: "Move up") { router.move(slot, by: -1) }
                .disabled(index == 0).opacity(index == 0 ? 0.35 : 1)
            IconKey(symbol: "chevron.down", help: "Move down") { router.move(slot, by: 1) }
                .disabled(index == count - 1).opacity(index == count - 1 ? 0.35 : 1)
            Button {
                router.openEditor(slot)
            } label: {
                Label("Edit", systemImage: "slider.horizontal.3").font(Theme.mono(10.5, .medium))
            }
            .buttonStyle(RubberButtonStyle(radius: 6, padding: EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)))
            .help("Open the plug-in's editor")
            IconKey(symbol: "xmark", tint: Theme.block, help: "Remove") { router.remove(slot) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.plate(slot.isEnabled ? 0.06 : 0.025))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(slot.isEnabled ? Theme.glow.opacity(0.35) : Theme.line(0.06), lineWidth: 1))
        }
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

struct AddEffectPopover: View {
    @EnvironmentObject private var router: AudioRouter
    @StateObject private var query = LocalState("")
    /// Vendor filter (nil = all); remembered between openings.
    @StateObject private var vendor = LocalState<String?>(UserDefaults.standard.string(forKey: "effectVendor"))
    @StateObject private var showVendors = LocalState(false)
    let dismiss: () -> Void

    /// All vendors with their effect counts, alphabetically.
    private var vendors: [(name: String, count: Int)] {
        Dictionary(grouping: router.availableEffects, by: \.manufacturerName)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The active vendor filter, ignored if that vendor has no effects installed any more.
    private var activeVendor: String? {
        guard let v = vendor.value, vendors.contains(where: { $0.name == v }) else { return nil }
        return v
    }

    private var groups: [(String, [AVAudioUnitComponent])] {
        let q = query.value.trimmingCharacters(in: .whitespaces).lowercased()
        let v = activeVendor
        let matches = router.availableEffects.filter {
            (v == nil || $0.manufacturerName == v)
                && (q.isEmpty || $0.name.lowercased().contains(q) || $0.manufacturerName.lowercased().contains(q))
        }
        return Dictionary(grouping: matches, by: \.manufacturerName)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    private func setVendor(_ v: String?) {
        vendor.value = v
        UserDefaults.standard.set(v, forKey: "effectVendor")
        showVendors.value = false
    }

    /// Dropdown key: "Vendor: All ▾" → list of vendors with counts.
    private var vendorPicker: some View {
        HStack(spacing: 6) {
            Text("VENDOR").font(Theme.mono(9.5, .semibold)).tracking(1.2).foregroundStyle(Theme.textDim)
            Button { showVendors.value.toggle() } label: {
                HStack(spacing: 6) {
                    Text(activeVendor ?? "All vendors").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(Theme.mono(11, .medium))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RubberButtonStyle(isOn: activeVendor != nil, radius: 6,
                                           padding: EdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)))
            .popover(isPresented: $showVendors.value, arrowEdge: .bottom) { vendorList }
            if activeVendor != nil {
                IconKey(symbol: "xmark", help: "Show all vendors") { setVendor(nil) }
            }
        }
    }

    private var vendorList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                vendorRow("All vendors", router.availableEffects.count, activeVendor == nil) { setVendor(nil) }
                Rectangle().fill(Theme.line(0.12)).frame(height: 1).padding(.vertical, 3)
                ForEach(vendors, id: \.name) { v in
                    vendorRow(v.name, v.count, activeVendor == v.name) { setVendor(v.name) }
                }
            }
            .padding(10)
        }
        .scrollIndicators(.automatic)
        .frame(width: 260)
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
        .font(Theme.mono(11.5))
        .preferredColorScheme(Theme.colorScheme)
    }

    private func vendorRow(_ name: String, _ count: Int, _ isOn: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                GlowCheckbox(isOn: isOn, size: 13)
                Text(name).lineLimit(1).truncationMode(.middle).glowText(isOn)
                Spacer(minLength: 6)
                Text("\(count)").font(Theme.mono(10)).monospacedDigit().foregroundStyle(Theme.textFaint)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
                TextField("Search Audio Units", text: $query.value)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                IconKey(symbol: "arrow.clockwise", help: "Rescan Audio Units") { router.refreshAvailableEffects() }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.glow.opacity(0.6)))

            vendorPicker

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(groups, id: \.0) { maker, components in
                        // click a vendor heading to show only that vendor
                        Button { setVendor(activeVendor == nil ? maker : nil) } label: {
                            Text(maker.uppercased())
                                .font(Theme.mono(9.5, .semibold)).tracking(1.2)
                                .foregroundStyle(Theme.textDim)
                        }
                        .buttonStyle(.plain)
                        .help(activeVendor == nil ? "Show only \(maker)" : "Show all vendors")
                        .padding(.top, 6)
                        ForEach(components, id: \.self) { c in
                            Button {
                                router.addEffect(c)
                                dismiss()
                            } label: {
                                Text(c.name).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.rubber())
                        }
                    }
                    if groups.isEmpty {
                        Text(activeVendor == nil ? "no matching effects" : "no matching effects from \(activeVendor!)")
                            .foregroundStyle(Theme.textFaint).padding(.top, 8)
                    }
                }
                .padding(.trailing, 4)
            }
            .scrollIndicators(.never)
        }
        .padding(12)
        .frame(width: 340, height: 460)
        .font(Theme.mono(11.5))
        .preferredColorScheme(Theme.colorScheme)
    }
}

// MARK: - Mix

struct MixSection: View {
    @EnvironmentObject private var router: AudioRouter

    var body: some View {
        Panel(title: "Mix", icon: "dial.medium") {
            MiniButton("Dry") { router.mix = 0 }
            MiniButton("50/50") { router.mix = 0.5 }
            MiniButton("Wet") { router.mix = 1 }
        } content: {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    label("DRY / WET")
                    RubberSlider(value: $router.mix, defaultValue: 1)
                        .help("Blend the unprocessed (dry) and processed (wet) signal · double-click resets")
                    value("\(Int((router.mix * 100).rounded()))% wet")
                }
                GridRow {
                    label("OUTPUT")
                    RubberSlider(value: $router.outputVolume, range: 0...2, defaultValue: 1, origin: 1)
                        .help("Output gain, up to +6 dB · double-click resets to 0 dB")
                    value(router.outputVolume > 0.0001
                          ? String(format: "%+.1f dB", 20 * log10(router.outputVolume)) : "-∞ dB")
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.mono(10, .semibold)).tracking(1.2).foregroundStyle(Theme.textDim)
            .frame(width: 80, alignment: .leading)
    }

    private func value(_ text: String) -> some View {
        Text(text).font(Theme.mono(11, .medium)).monospacedDigit()
            .frame(width: 72, alignment: .trailing)
    }
}

// MARK: - Status

struct StatusBar: View {
    @EnvironmentObject private var router: AudioRouter

    private var isError: Bool {
        router.status.hasPrefix("Error") || router.status.contains("failed") || router.status.contains("denied")
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isError ? Theme.block : router.isRunning ? Theme.pass : Theme.textFaint)
                .frame(width: 6, height: 6)
                .shadow(color: isError ? Theme.block : router.isRunning ? Theme.pass : .clear, radius: 3)
            Text(router.status)
                .font(Theme.mono(10.5))
                .foregroundStyle(isError ? Theme.block : Theme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if router.isRunning {
                Text(String(format: "≈ %.1f ms", router.estimatedLatencyMs))
                    .font(Theme.mono(10.5, .medium))
                    .foregroundStyle(Theme.textDim)
                    .help("Estimated latency through Audio Router (details in Settings)")
                Text("\(router.dropouts) dropouts")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(router.dropouts > 0 ? Theme.block : Theme.textFaint)
                    .help("Buffer underruns / catch-up skips since start — raise the safety buffer in Settings if this keeps growing")
            }
        }
        .padding(.horizontal, 4)
    }
}
