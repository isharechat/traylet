import SwiftUI

/// A grouped list in the System Settings style: rows separated by hairlines inside one rounded card, with an optional footnote.
struct SettingsGroup<Content: View>: View {
    var footer: String?
    @ViewBuilder var content: () -> Content
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs + 2) {
            VStack(alignment: .leading, spacing: 0, content: content).padding(.horizontal, Design.Space.m + 2)
                .frame(maxWidth: .infinity, alignment: .leading).v2SettingsCard(contrast: contrast)
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, Design.Space.m + 2) }
        }
    }
}

/// One settings row: title on the left, control on the right, at least 40pt tall.
struct SettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: () -> Control
    var body: some View { HStack(spacing: Design.Space.m) { Text(title); Spacer(minLength: Design.Space.m); control() }.frame(minHeight: 40) }
}

extension View {
    /// The card fill and hairline used by every settings group.
    func v2SettingsCard(contrast: ColorSchemeContrast) -> some View {
        v2GlassBackground(in: RoundedRectangle(cornerRadius: Design.Radius.card))
    }
}
