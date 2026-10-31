import AppKit
import Carbon
import TrayletCore

@MainActor protocol V2PhysicalHotKeys: AnyObject {
    var onPress: ((UInt32) -> Void)? { get set }
    func reserve(_ chord: V2KeyChord, id: UInt32) throws
    func release(_ id: UInt32)
    func shutdown()
}

/// Stages only newly needed physical keys. Existing keys keep working until commit.
@MainActor final class V2TransactionalShortcutDriver: V2ShortcutRegistering {
    var onInvoke: ((V2Action) -> Void)?
    private let physical: any V2PhysicalHotKeys
    private var active: [V2KeyChord: UInt32] = [:]
    private var actions: [UInt32: V2Action] = [:]
    private var nextID: UInt32 = 1
    private var pending: UUID?
    private var reserved: [V2KeyChord: UInt32] = [:]

    init(physical: any V2PhysicalHotKeys = V2CarbonHotKeys()) {
        self.physical = physical
        physical.onPress = { [weak self] id in
            guard let self, let action = self.actions[id] else { return }
            self.onInvoke?(action)
        }
    }
    func prepare(_ bindings: [V2ShortcutAssignment]) throws -> any V2ShortcutUpdate {
        guard pending == nil, V2ShortcutAssignment.valid(bindings) else { throw FeatureIssue.unavailable("快捷键更新正在进行，请重试。") }
        var added: [V2KeyChord: UInt32] = [:]
        do {
            for chord in bindings.compactMap(\.chord) where active[chord] == nil {
                guard nextID < UInt32.max else { throw FeatureIssue.unavailable("请重启应用以重新注册快捷键。") }
                let id = nextID; nextID += 1
                try physical.reserve(chord, id: id); added[chord] = id
            }
        } catch { added.values.forEach { physical.release($0) }; throw error }
        let token = UUID(); pending = token; reserved = added
        return V2PreparedHotKeys(commit: { [weak self] in self?.finish(token, bindings: bindings) },
                                 cancel: { [weak self] in self?.abandon(token) })
    }
    private func finish(_ token: UUID, bindings: [V2ShortcutAssignment]) {
        guard pending == token else { return }
        let all = active.merging(reserved) { old, _ in old }
        let needed = Set(bindings.compactMap(\.chord))
        active = all.filter { needed.contains($0.key) }
        actions = Dictionary(uniqueKeysWithValues: bindings.compactMap { binding in
            binding.chord.flatMap { chord in active[chord].map { ($0, binding.action) } }
        })
        all.filter { !needed.contains($0.key) }.values.forEach { physical.release($0) }
        reserved = [:]; pending = nil
    }
    private func abandon(_ token: UUID) {
        guard pending == token else { return }
        reserved.values.forEach { physical.release($0) }; reserved = [:]; pending = nil
    }
    func stop() {
        actions = [:]; active = [:]; reserved = [:]; pending = nil; physical.shutdown()
    }
}

@MainActor private final class V2PreparedHotKeys: V2ShortcutUpdate {
    private var commitAction: (() -> Void)?
    private var cancelAction: (() -> Void)?
    init(commit: @escaping () -> Void, cancel: @escaping () -> Void) { commitAction = commit; cancelAction = cancel }
    func commit() { let action = commitAction; commitAction = nil; cancelAction = nil; action?() }
    func cancel() { let action = cancelAction; commitAction = nil; cancelAction = nil; action?() }
}

@MainActor final class V2CarbonHotKeys: V2PhysicalHotKeys {
    var onPress: ((UInt32) -> Void)?
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    init() { installHandler() }
    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard status == noErr else { return status }
            MainActor.assumeIsolated {
                Unmanaged<V2CarbonHotKeys>.fromOpaque(pointer).takeUnretainedValue().onPress?(key.id)
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func reserve(_ chord: V2KeyChord, id: UInt32) throws {
        installHandler()
        guard handler != nil else { throw FeatureIssue.unavailable("系统快捷键监听未就绪，可继续使用菜单。") }
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(UInt32(chord.keyCode), chord.carbonModifiers,
            EventHotKeyID(signature: 0x54525632, id: id), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard result == noErr, let reference else {
            throw FeatureIssue.unavailable(result == eventHotKeyExistsErr
                ? "此组合已被独占注册，无法可靠识别占用者。请选择其他组合；原绑定保留。"
                : String(format: V2L("系统注册失败（%d）。请选择其他组合；原绑定保留。"), result))
        }
        references[id] = reference
    }
    func release(_ id: UInt32) { if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) } }
    func shutdown() {
        references.values.forEach { UnregisterEventHotKey($0) }; references = [:]
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}

extension V2KeyChord {
    var carbonModifiers: UInt32 {
        (modifiers.contains(.control) ? UInt32(controlKey) : 0) |
        (modifiers.contains(.option) ? UInt32(optionKey) : 0) |
        (modifiers.contains(.shift) ? UInt32(shiftKey) : 0) |
        (modifiers.contains(.command) ? UInt32(cmdKey) : 0)
    }
    /// Public symbolic hotkeys and common app commands only; other applications are not enumerable.
    static func unavailableReason(_ chord: V2KeyChord) -> String? {
        if chord.modifiers == .command && [12, 13, 43, 48, 49].contains(chord.keyCode) {
            return "此组合用于系统切换或应用标准命令，请选择其他组合。"
        }
        var result: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&result) == noErr,
              let values = result?.takeRetainedValue() as? [[String: Any]] else { return nil }
        for value in values {
            if (value[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true,
               (value[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint16Value == chord.keyCode,
               (value[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == chord.carbonModifiers {
                return "此组合与已启用的系统快捷键冲突，请重新录入。"
            }
        }
        return nil
    }
}
