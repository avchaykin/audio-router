import AppKit
import AVFoundation
import CoreAudioKit

/// Opens each effect's own UI (or a generic parameter view) in a separate window.
@MainActor
final class PluginWindowManager: NSObject, NSWindowDelegate {
    static let shared = PluginWindowManager()
    private var windows: [UUID: NSWindow] = [:]

    func open(_ slot: EffectSlot) {
        if let window = windows[slot.id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        slot.unit.auAudioUnit.requestViewController { [weak self, weak slot] controller in
            DispatchQueue.main.async {
                guard let self, let slot else { return }
                self.present(controller ?? self.genericController(for: slot), for: slot)
            }
        }
    }

    func close(_ slot: EffectSlot) {
        windows[slot.id]?.close()
        windows[slot.id] = nil
    }

    private func genericController(for slot: EffectSlot) -> NSViewController {
        let controller = NSViewController()
        let view = AUGenericView(audioUnit: slot.unit.audioUnit)
        view.showsExpertParameters = true
        controller.view = view
        return controller
    }

    private func present(_ controller: NSViewController, for slot: EffectSlot) {
        guard windows[slot.id] == nil else { return }
        var size = controller.preferredContentSize
        if size.width < 10 || size.height < 10 { size = controller.view.frame.size }
        if size.width < 10 || size.height < 10 { size = NSSize(width: 480, height: 320) }

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "\(slot.name) — \(slot.manufacturer)"
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows[slot.id] = window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        windows[id] = nil
    }
}
