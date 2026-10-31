import SwiftUI

/// A grouped list in the System Settings style: rows separated by hairlines inside one rounded card, with an optional footnote.
struct V2SettingsGroup<Content: View>: View {
    var footer: String?
    @ViewBuilder var content: () -> Content
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(alignment: .leading, spacing: V2Design.Space.xs + 2) {
            VStack(alignment: .leading, spacing: 0, content: content).padding(.horizontal, V2Design.Space.m + 2)
                .frame(maxWidth: .infinity, alignment: .leading).v2SettingsCard(contrast: contrast)
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, V2Design.Space.m + 2) }
        }
    }
}

/// One settings row: title on the left, control on the right, at least 40pt tall.
struct V2SettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: () -> Control
    var body: some View { HStack(spacing: V2Design.Space.m) { Text(title); Spacer(minLength: V2Design.Space.m); control() }.frame(minHeight: 40) }
}

extension View {
    /// The card fill and hairline used by every settings group.
    func v2SettingsCard(contrast: ColorSchemeContrast) -> some View {
        let stroke = V2Design.stroke(increasedContrast: contrast == .increased)
        return background(Color(nsColor: .controlBackgroundColor).opacity(contrast == .increased ? 1 : 0.7), in: RoundedRectangle(cornerRadius: V2Design.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: V2Design.Radius.card).strokeBorder(Color(nsColor: .separatorColor).opacity(stroke.opacity), lineWidth: stroke.width))
    }
}
