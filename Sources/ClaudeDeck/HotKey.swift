import Carbon.HIToolbox

/// System-wide shortcuts via Carbon's RegisterEventHotKey (needs no Accessibility permission).
enum GlobalHotKey {
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var refs: [EventHotKeyRef?] = []
    nonisolated(unsafe) private static var installed = false

    static func register(keyCode: Int, modifiers: Int, _ action: @escaping () -> Void) {
        installHandlerOnce()
        let id = UInt32(handlers.count + 1)
        handlers[id] = action
        var ref: EventHotKeyRef?
        let hotKeyId = EventHotKeyID(signature: OSType(0x434C_4450), id: id) // "CLDP"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyId, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyId = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyId)
            let id = hotKeyId.id
            DispatchQueue.main.async { GlobalHotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
