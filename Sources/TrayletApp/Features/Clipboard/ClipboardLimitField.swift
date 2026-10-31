import SwiftUI

/// Keep incomplete edits local: lowering either limit can immediately prune history.
struct ClipboardLimitField: View {
    let title: String
    let unit: String
    let range: ClosedRange<Int>
    @Binding var value: Int
    @State private var draft: String
    @State private var invalid = false
    @FocusState private var focused: Bool

    init(_ title: String, unit: String, value: Binding<Int>, range: ClosedRange<Int>) {
        self.title = title; self.unit = unit; self.range = range; _value = value
        _draft = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                TextField(V2L(title), text: $draft)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .monospacedDigit().frame(width: 76).focused($focused)
                    .accessibilityLabel(V2L(title))
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, active in if !active { commit() } }
                    .onChange(of: value) { _, current in if !focused { draft = String(current) } }
                Text(V2L(unit)).foregroundStyle(.secondary)
                Stepper(V2L(title), value: $value, in: range).labelsHidden()
            }
            if invalid {
                Text(String(format: V2L("请输入 %d–%d 的整数"), range.lowerBound, range.upperBound))
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func commit() {
        guard let number = Self.parse(draft, in: range) else {
            invalid = true
            if !focused { draft = String(value) }
            return
        }
        invalid = false; draft = String(number)
        if value != number { value = number }
    }

    nonisolated static func parse(_ text: String, in range: ClosedRange<Int>) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), range.contains(value) else { return nil }
        return value
    }
}
