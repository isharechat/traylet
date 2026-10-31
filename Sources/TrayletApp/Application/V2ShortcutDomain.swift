import Foundation
import Combine
import TrayletCore

enum V2Action: String, Codable, CaseIterable, Identifiable, Sendable {
    case regionCapture, screenCapture, inputTranslation, captureTranslation, clipboard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .regionCapture: "区域截图"
        case .screenCapture: "屏幕截图"
        case .inputTranslation: "输入翻译"
        case .captureTranslation: "截图翻译"
        case .clipboard: "剪贴板"
        }
    }
}

struct V2KeyModifiers: OptionSet, Hashable, Codable, Sendable {
    let rawValue: UInt8
    static let control = Self(rawValue: 1)
    static let option = Self(rawValue: 2)
    static let shift = Self(rawValue: 4)
    static let command = Self(rawValue: 8)
    static let all: Self = [.control, .option, .shift, .command]
}

struct V2KeyChord: Hashable, Codable, Sendable {
    let keyCode: UInt16
    let modifiers: V2KeyModifiers
    var isRecordable: Bool {
        keyCode <= 127 && keyCode != 53 && ![54,55,56,57,58,59,60,61,62,63].contains(keyCode) &&
            !modifiers.isEmpty && modifiers.subtracting(.all).isEmpty
    }
    var display: String {
        let symbols = (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") +
            (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
        let names: [UInt16:String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"⇥",49:"␣",50:"`",51:"⌫",76:"⌤",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",109:"F10",111:"F12",115:"↖",116:"⇞",117:"⌦",118:"F4",119:"↘",120:"F2",121:"⇟",122:"F1",123:"←",124:"→",125:"↓",126:"↑"]
        return symbols + (names[keyCode] ?? "Key \(keyCode)")
    }
}

struct V2ShortcutAssignment: Codable, Equatable, Sendable {
    let action: V2Action
    var chord: V2KeyChord?
    static var defaults: [Self] {
        let modifiers: V2KeyModifiers = [.control, .option]
        return [.init(action: .regionCapture, chord: .init(keyCode: 18, modifiers: modifiers)),
            .init(action: .screenCapture), .init(action: .inputTranslation, chord: .init(keyCode: 17, modifiers: modifiers)),
            .init(action: .captureTranslation, chord: .init(keyCode: 21, modifiers: modifiers)),
            .init(action: .clipboard, chord: .init(keyCode: 9, modifiers: modifiers))]
    }
    static func valid(_ values: [Self]) -> Bool {
        let chords = values.compactMap(\.chord)
        return values.count == V2Action.allCases.count && Set(values.map(\.action)) == Set(V2Action.allCases) &&
            chords.allSatisfy(\.isRecordable) && Set(chords).count == chords.count
    }
}

@MainActor protocol V2ShortcutUpdate: AnyObject { func commit(); func cancel() }
@MainActor protocol V2ShortcutRegistering: AnyObject {
    var onInvoke: ((V2Action) -> Void)? { get set }
    /// Reserve new physical combinations while keeping previous callbacks/bindings effective.
    func prepare(_ bindings: [V2ShortcutAssignment]) throws -> any V2ShortcutUpdate
    func stop()
}

struct V2ShortcutConflict: Equatable {
    let action: V2Action
    let occupiedBy: V2Action
    let proposed: V2KeyChord
}

@MainActor final class V2ShortcutManager: ObservableObject {
    @Published private(set) var recordingAction: V2Action?
    @Published private(set) var conflict: V2ShortcutConflict?
    @Published private(set) var message: String?
    var onInvoke: ((V2Action) -> Void)?
    private let preferences: V2PreferencesStore
    private let driver: any V2ShortcutRegistering
    private let unavailable: (V2KeyChord) -> String?
    private var started = false

    init(preferences: V2PreferencesStore, driver: any V2ShortcutRegistering,
         unavailable: @escaping (V2KeyChord) -> String? = { _ in nil }) {
        self.preferences = preferences; self.driver = driver; self.unavailable = unavailable
        driver.onInvoke = { [weak self] action in
            guard let self, self.started, self.conflict == nil else { return }
            if self.recordingAction != nil {
                if let chord = self.preferences.value.shortcuts.first(where: { $0.action == action })?.chord {
                    self.record(chord)
                }
                return
            }
            self.onInvoke?(action)
        }
    }

    func start() throws {
        guard preferences.failure == nil else { throw FeatureIssue.storage("请先恢复新版本偏好。") }
        try validate(preferences.value.shortcuts)
        let update = try driver.prepare(preferences.value.shortcuts)
        update.commit(); started = true
    }
    func stop() { cancel(); started = false; driver.stop() }
    func begin(_ action: V2Action) { recordingAction = action; conflict = nil; message = "请按组合键…" }
    func cancel() { recordingAction = nil; conflict = nil; message = nil }
    func keepExisting() { cancel() }
    func retry() { if let conflict { begin(conflict.action) } }

    func record(_ chord: V2KeyChord) {
        guard let action = recordingAction else { return }
        guard chord.isRecordable else { message = "组合键须含修饰键，Esc用于取消。"; return }
        if let reason = unavailable(chord) { message = reason; return }
        if let occupied = preferences.value.shortcuts.first(where: { $0.action != action && $0.chord == chord }) {
            conflict = .init(action: action, occupiedBy: occupied.action, proposed: chord); message = nil; return
        }
        commit(preferences.value.shortcuts.map { $0.action == action ? .init(action: action, chord: chord) : $0 })
    }

    func replaceExisting() {
        guard let conflict else { return }
        let values = preferences.value.shortcuts.map { binding -> V2ShortcutAssignment in
            if binding.action == conflict.occupiedBy { return .init(action: binding.action) }
            if binding.action == conflict.action { return .init(action: binding.action, chord: conflict.proposed) }
            return binding
        }
        commit(values)
    }
    func clear(_ action: V2Action) { commit(preferences.value.shortcuts.map { $0.action == action ? .init(action: action) : $0 }) }
    func restoreDefaults() { commit(V2ShortcutAssignment.defaults) }

    private func validate(_ bindings: [V2ShortcutAssignment]) throws {
        guard V2ShortcutAssignment.valid(bindings) else { throw FeatureIssue.invalidInput("快捷键数据无效或存在重复。") }
        for chord in bindings.compactMap(\.chord) {
            if let reason = unavailable(chord) { throw FeatureIssue.unavailable(reason) }
        }
    }

    private func commit(_ bindings: [V2ShortcutAssignment]) {
        do {
            try validate(bindings)
            let update = try driver.prepare(bindings)
            do {
                var value = preferences.value; value.shortcuts = bindings
                try preferences.save(value)
                update.commit(); started = true; cancel()
            } catch { update.cancel(); throw error }
        } catch {
            message = (error as? FeatureIssue)?.errorDescription ?? "快捷键未保存，原绑定保留。请选择其他组合或重试。"
        }
    }
}
