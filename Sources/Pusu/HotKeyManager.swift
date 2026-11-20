import Foundation
import Carbon
import PusuCore

final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let handler: () -> Void
    private var installedPreset: HotKeyPreset?

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @discardableResult
    func register(_ preset: HotKeyPreset) -> Bool {
        unregister()
        guard let keyCode = preset.keyCode else {
            installedPreset = .off
            return true
        }

        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: fourCharCode("AWKE"), id: 1)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            preset.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            NSLog("Pusu hotkey registration failed: \(status)")
            return false
        }

        hotKeyRef = reference
        installedPreset = preset
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
    }

    fileprivate func fire() {
        handler()
    }
}

private let hotKeyEventHandler: EventHandlerUPP = { _, _, userData in
    guard let userData else { return noErr }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    if Thread.isMainThread {
        manager.fire()
    } else {
        DispatchQueue.main.async {
            manager.fire()
        }
    }
    return noErr
}

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for byte in string.utf8.prefix(4) {
        result = (result << 8) + OSType(byte)
    }
    return result
}
